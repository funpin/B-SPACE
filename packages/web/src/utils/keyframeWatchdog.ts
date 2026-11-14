/**
 * Keyframe watchdog for the local screen share.
 *
 * A viewer can only start drawing a stream from a keyframe. Whenever one
 * needs a picture — it starts watching, or adaptive stream resumes a share it
 * had paused while the tile was off screen — its browser sends a PLI (or FIR)
 * that the SFU forwards to the sharer, and the sharer's encoder is expected to
 * answer with a keyframe.
 *
 * Some hardware H.264 encoders (Media Foundation on Windows in particular) do
 * not honour that request. The viewer then shows black until the encoder's
 * own periodic keyframe, which for screen content can be tens of seconds
 * away. libvpx always honours it, which is why VP9 never showed the bug.
 *
 * The watchdog reads the screen sender's outbound stats once a second. When a
 * layer has received a keyframe request that its encoder has not answered
 * within `KEYFRAME_ANSWER_TIMEOUT_MS`, it forces one: it changes the encoded
 * size by a few pixels and changes it back. An encoder cannot carry on
 * predicting across a resolution change — the first frame at a new size is
 * an IDR whatever the encoder's keyframe policy — so the stalled viewers get
 * their picture straight away. A well-behaved encoder answers every request
 * itself and the watchdog never acts.
 */
import type { Room } from 'livekit-client';
import { getPublisherPC } from './livekitInternals';

/** How long an encoder gets to answer a keyframe request before one is forced. */
export const KEYFRAME_ANSWER_TIMEOUT_MS = 1500;
/** The least time between two forced keyframes: each one costs every viewer a resize. */
export const KEYFRAME_FORCE_COOLDOWN_MS = 4000;
/** How long the nudged size is held before the original one is restored. */
export const KEYFRAME_NUDGE_HOLD_MS = 400;
/** How many pixels of height the nudge takes off. Even, so encoders that align to 2 still see a change. */
export const KEYFRAME_NUDGE_PIXELS = 4;

const POLL_INTERVAL_MS = 1000;

/** One encoded layer's counters, as read from an `outbound-rtp` stats entry. */
export interface LayerSample {
  /** Stable per layer: the stats id. */
  id: string;
  /** PLI + FIR received for this layer so far. */
  keyRequests: number;
  /** Keyframes this layer's encoder has produced so far. */
  keyFramesEncoded: number;
}

interface LayerState {
  keyRequests: number;
  keyFramesEncoded: number;
  /** When an unanswered request was first seen, or null when none is waiting. */
  pendingSince: number | null;
}

/**
 * The decision half of the watchdog, free of WebRTC so it can be tested:
 * feed it each poll's samples and it says whether a keyframe must be forced.
 */
export class KeyframeRequestTracker {
  private readonly layers = new Map<string, LayerState>();
  private lastForcedAt = Number.NEGATIVE_INFINITY;

  constructor(
    private readonly answerTimeoutMs: number = KEYFRAME_ANSWER_TIMEOUT_MS,
    private readonly cooldownMs: number = KEYFRAME_FORCE_COOLDOWN_MS,
  ) {}

  /** Returns true when a keyframe must be forced now. */
  observe(samples: readonly LayerSample[], now: number): boolean {
    const seen = new Set<string>();
    let stalled = false;

    for (const sample of samples) {
      seen.add(sample.id);
      const previous = this.layers.get(sample.id);
      if (!previous) {
        // The first look at a layer is the baseline: requests that arrived
        // before the watchdog was watching are not this poll's to judge.
        this.layers.set(sample.id, {
          keyRequests: sample.keyRequests,
          keyFramesEncoded: sample.keyFramesEncoded,
          pendingSince: null,
        });
        continue;
      }

      let pendingSince = previous.pendingSince;
      if (sample.keyFramesEncoded > previous.keyFramesEncoded) {
        // A keyframe went out after the last poll: anything waiting is answered.
        pendingSince = null;
      } else if (sample.keyRequests > previous.keyRequests && pendingSince === null) {
        pendingSince = now;
      }

      if (pendingSince !== null && now - pendingSince >= this.answerTimeoutMs) {
        stalled = true;
      }

      this.layers.set(sample.id, {
        keyRequests: sample.keyRequests,
        keyFramesEncoded: sample.keyFramesEncoded,
        pendingSince,
      });
    }

    // A layer that left the stats (dynacast paused it, a republish replaced
    // it) is forgotten, so it is baselined afresh when it comes back.
    for (const id of [...this.layers.keys()]) {
      if (!seen.has(id)) this.layers.delete(id);
    }

    if (!stalled || now - this.lastForcedAt < this.cooldownMs) return false;

    this.lastForcedAt = now;
    // The forced keyframe answers every request waiting now.
    for (const state of this.layers.values()) state.pendingSince = null;
    return true;
  }
}

interface OutboundVideoStats extends RTCStats {
  kind?: string;
  mediaType?: string;
  active?: boolean;
  pliCount?: number;
  firCount?: number;
  keyFramesEncoded?: number;
  frameHeight?: number;
}

function isOutboundVideo(report: RTCStats): report is OutboundVideoStats {
  const entry = report as OutboundVideoStats;
  return entry.type === 'outbound-rtp' && (entry.kind === 'video' || entry.mediaType === 'video');
}

/** The active layers of `sender`, and the tallest frame any of them is encoding. */
export function readLayerSamples(stats: RTCStatsReport): { samples: LayerSample[]; frameHeight: number } {
  const samples: LayerSample[] = [];
  let frameHeight = 0;
  stats.forEach((report: RTCStats) => {
    if (!isOutboundVideo(report) || report.active === false) return;
    samples.push({
      id: report.id,
      keyRequests: (report.pliCount ?? 0) + (report.firCount ?? 0),
      keyFramesEncoded: report.keyFramesEncoded ?? 0,
    });
    frameHeight = Math.max(frameHeight, report.frameHeight ?? 0);
  });
  return { samples, frameHeight };
}

/**
 * The `scaleResolutionDownBy` that takes `KEYFRAME_NUDGE_PIXELS` off a frame
 * `frameHeight` tall that is now encoded at `scale`. Null when the frame is too
 * small for a nudge to stay a nudge.
 */
export function nudgedScale(scale: number, frameHeight: number): number | null {
  if (!Number.isFinite(frameHeight) || frameHeight <= KEYFRAME_NUDGE_PIXELS * 10) return null;
  return scale * (frameHeight / (frameHeight - KEYFRAME_NUDGE_PIXELS));
}

const delay = (ms: number) => new Promise<void>((resolve) => { setTimeout(resolve, ms); });

/** Resize the sender's layers a few pixels and back, so every encoder starts over with an IDR. */
async function forceKeyframe(sender: RTCRtpSender, frameHeight: number): Promise<void> {
  const original = sender.getParameters();
  if (!original.encodings?.length) return;
  const originalScales = original.encodings.map((encoding) => encoding.scaleResolutionDownBy);

  const nudged = sender.getParameters();
  let changed = false;
  nudged.encodings.forEach((encoding) => {
    const scale = encoding.scaleResolutionDownBy ?? 1;
    // Each layer's height is the top layer's divided by its own scale.
    const next = nudgedScale(scale, frameHeight / scale);
    if (next === null) return;
    encoding.scaleResolutionDownBy = next;
    changed = true;
  });
  if (!changed) return;

  await sender.setParameters(nudged);
  await delay(KEYFRAME_NUDGE_HOLD_MS);

  // Re-read before restoring: overdrive or a codec change may have written
  // other fields meanwhile, and only the scale is ours to put back.
  const restored = sender.getParameters();
  if (restored.encodings.length !== originalScales.length) return;
  restored.encodings.forEach((encoding, index) => {
    const scale = originalScales[index];
    if (scale === undefined) delete encoding.scaleResolutionDownBy;
    else encoding.scaleResolutionDownBy = scale;
  });
  await sender.setParameters(restored);
}

/**
 * Watch the screen sender carrying `trackId` until `isCurrent` says the share
 * is over or replaced. Returns a stop function.
 */
export function startKeyframeWatchdog(
  room: Room,
  trackId: string,
  isCurrent: () => boolean,
): () => void {
  const tracker = new KeyframeRequestTracker();
  let stopped = false;
  let forcing = false;
  let timer: ReturnType<typeof setTimeout> | null = null;

  const tick = async (): Promise<void> => {
    timer = null;
    if (stopped) return;
    if (!isCurrent()) {
      stopped = true;
      return;
    }
    try {
      const sender = getPublisherPC(room)?.getSenders().find((s) => s.track?.id === trackId);
      if (sender && !forcing) {
        const { samples, frameHeight } = readLayerSamples(await sender.getStats());
        if (!stopped && tracker.observe(samples, Date.now()) && frameHeight > 0) {
          forcing = true;
          console.info('[ScreenShare] Encoder ignored a keyframe request; forcing one');
          try {
            await forceKeyframe(sender, frameHeight);
          } finally {
            forcing = false;
          }
        }
      }
    } catch (err) {
      // A sender torn down mid-poll (stop, republish, reconnect) is expected.
      console.warn('[ScreenShare] Keyframe watchdog poll failed:', err);
    }
    if (!stopped) timer = setTimeout(() => { void tick(); }, POLL_INTERVAL_MS);
  };

  timer = setTimeout(() => { void tick(); }, POLL_INTERVAL_MS);
  return () => {
    stopped = true;
    if (timer !== null) clearTimeout(timer);
    timer = null;
  };
}
