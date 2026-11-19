/**
 * A screen share the native macOS shell publishes itself, as the call sees
 * it from the page (plan section 12; docs/systems/voice.md, "The stream
 * participant").
 *
 * The page does not hold the share: the shell captures, encodes and sends it
 * as the user's stream participant. What the page does is everything around
 * it: asks the call's server for the stream token, tells the shell what to
 * share and at what quality, keeps the call's state (`isScreenSharing`, the
 * System Audio state, `voice_status`), tells viewers when the share stops or
 * comes back, and hears from the shell what became of it.
 *
 * utils/screenShare.ts calls in here wherever it would touch a published
 * track; the bridge itself is platform/nativeShare/nativeScreenShare.ts.
 */
import { ConnectionState, type Room } from 'livekit-client';
import { create } from 'zustand';
import { useVoiceStore } from '../stores/voiceStore';
import type { ScreenShareConfig } from '../stores/voiceStore';
import { useUIStore } from '../stores/uiStore';
import { getApiForOrigin } from '../stores/spaceStore';
import { describeError } from '../i18n/errors';
import i18n from '../i18n';
import { broadcastVoiceStatus } from './voice';
import { encodeShareSignal, type ShareSignal } from './streamWatchProtocol';
import type { ScreenShareBuildResult } from './screenShare';
import {
  dropNativeStage, onShellShareEvent, shellCanShare, startShellShare, stopShellShare, updateShellShare,
  type NativeStagedShare,
} from '../platform/nativeShare/nativeScreenShare';

/** Everything about a share that the shell is told. */
export interface NativeShareQuality {
  sourceId: string;
  /** Left out for the source's own size. */
  maxWidth?: number;
  maxHeight?: number;
  frameRate: number;
  codec: 'h264' | 'h265';
  maxBitrate: number;
  minBitrate: number;
  audio: boolean;
}

/** What the shell last said it sends, for the connection panel. */
export type NativeShareStats = Extract<NativeScreenShareEvent, { type: 'stats' }>;

interface NativeShareState {
  /** The codec the shell was asked to publish the live share in; null while there is none. */
  codec: 'h264' | 'h265' | null;
  stats: NativeShareStats | null;
  /** The share's own connection is being restored; the share is kept. */
  reconnecting: boolean;
}

export const useNativeShareStore = create<NativeShareState>(() => ({ codec: null, stats: null, reconnecting: false }));

interface LiveShare {
  room: Room;
  quality: NativeShareQuality;
  unsubscribe: () => void;
}

let _live: LiveShare | null = null;
/** Changes are applied one after another: the shell takes one at a time. */
let _applying: Promise<void> = Promise.resolve();

/**
 * The floor the encoder keeps while the bandwidth estimate is lower: a third
 * of the ceiling, and no more than 3 Mbit/s.
 *
 * A share's estimate sometimes starts at about 1 Mbit/s on a link that
 * carries many times that and climbs by a few percent a second; the encoder
 * drops to a few frames a second meanwhile (measured, plan 12.11). A floor
 * keeps the picture moving through that. It also sends more than a link that
 * really is that narrow can carry, so it is kept well under the ceiling.
 */
export function nativeShareFloor(maxBitrate: number): number {
  return Math.min(Math.round(maxBitrate / 3), 3_000_000);
}

/** What the shell is told for a share of `sourceId` under the user's settings. */
export function nativeShareQuality(
  sourceId: string,
  config: ScreenShareConfig,
  build: ScreenShareBuildResult,
): NativeShareQuality {
  const maxBitrate = build.publish.videoEncoding.maxBitrate;
  return {
    sourceId,
    // Zero is the page's "the source's own size".
    ...(build.capture.width > 0 && build.capture.height > 0
      ? { maxWidth: build.capture.width, maxHeight: build.capture.height }
      : {}),
    frameRate: build.capture.frameRate,
    // Both are hardware-encoded on every Mac the shell runs on. H.265 unless
    // the user asked for H.264: about a third less traffic for the same
    // picture, with H.264 kept for viewers that cannot decode it.
    codec: config.codec === 'h264' ? 'h264' : 'h265',
    maxBitrate,
    minBitrate: nativeShareFloor(maxBitrate),
    audio: config.shareAudio,
  };
}

/**
 * What has to be said to the shell to turn `running` into `next`: only what
 * differs, `null` when nothing does, and `'restart'` for another codec, which
 * is decided when a share is published.
 */
export function nativeShareChange(
  running: NativeShareQuality,
  next: NativeShareQuality,
): NativeScreenShareUpdate | 'restart' | null {
  if (running.codec !== next.codec) return 'restart';
  const update: NativeScreenShareUpdate = {};
  if (running.sourceId !== next.sourceId) update.sourceId = next.sourceId;
  if (running.maxWidth !== next.maxWidth || running.maxHeight !== next.maxHeight) {
    // The source's own size is asked for as the largest the shell takes.
    update.maxWidth = next.maxWidth ?? 8192;
    update.maxHeight = next.maxHeight ?? 8192;
  }
  if (running.frameRate !== next.frameRate) update.frameRate = next.frameRate;
  if (running.maxBitrate !== next.maxBitrate) update.maxBitrate = next.maxBitrate;
  if (running.minBitrate !== next.minBitrate) update.minBitrate = next.minBitrate;
  if (running.audio !== next.audio) update.audio = next.audio;
  return Object.keys(update).length > 0 ? update : null;
}

/**
 * Whether a share in the call the user is in goes through the shell: the
 * shell publishes shares, and the server that issued the voice token said it
 * issues stream tokens. A call whose token came by federation relay has no
 * such server to ask, and a share there is the page's own.
 */
export function canShareNativelyInThisCall(): boolean {
  return shellCanShare() && useVoiceStore.getState().streamTokenSource !== null;
}

export function isNativeShareLive(): boolean {
  return _live !== null;
}

/** Fire and forget: a room that is gone has nobody to tell. */
function announce(room: Room, signal: ShareSignal): void {
  if (room.state === ConnectionState.Disconnected) return;
  const warn = (err: unknown) => console.warn('[NativeShare] Could not send %s to viewers:', signal, err);
  try {
    room.localParticipant.publishData(encodeShareSignal(signal), { reliable: true }).catch(warn);
  } catch (err) {
    warn(err);
  }
}

type ShareMessage =
  | 'voice:streamSettings.systemAudioEnded'
  | 'voice:streamSettings.systemAudioStartFailed'
  | 'voice:streamSettings.shareEndedSource'
  | 'voice:streamSettings.shareEndedConnection';

function toast(key: ShareMessage): void {
  useUIStore.getState().addToast(i18n.t(key), 'warning', 8000);
}

/** The share is over, however it ended: the call's state and everyone it is told to. */
function settle(live: LiveShare, announceStop: boolean): void {
  live.unsubscribe();
  if (_live === live) _live = null;
  if (announceStop) announce(live.room, 'stream_stop');
  useNativeShareStore.setState({ codec: null, stats: null, reconnecting: false });
  useVoiceStore.setState({ isScreenSharing: false, screenShareAudio: null });
  // `voice_status` carries isScreenSharing to people who are not in the room.
  broadcastVoiceStatus();
}

function heard(live: LiveShare, event: NativeScreenShareEvent): void {
  if (_live !== live) return;
  switch (event.type) {
    case 'stats':
      useNativeShareStore.setState({ stats: event });
      return;
    case 'reconnecting':
      useNativeShareStore.setState({ reconnecting: true });
      return;
    case 'reconnected':
      useNativeShareStore.setState({ reconnecting: false });
      // The stream participant may have been replaced for everyone else, and
      // viewers then saw the share end. Those who were watching watch again.
      announce(live.room, 'stream_resume');
      return;
    case 'audio-ended':
      live.quality = { ...live.quality, audio: false };
      useVoiceStore.setState({ screenShareAudio: 'acquirable' });
      toast('voice:streamSettings.systemAudioEnded');
      return;
    case 'ended':
      settle(live, true);
      toast(event.reason === 'source-ended'
        ? 'voice:streamSettings.shareEndedSource'
        : 'voice:streamSettings.shareEndedConnection');
      return;
    default:
      // `resized` needs nothing from the page: viewers get the new size with
      // the picture. `preview-ended` is the setup screen's.
      return;
  }
}

/**
 * Goes live with what the setup screen staged: the stream token from the
 * call's server, then the shell. False when either refuses; the reason has
 * been shown.
 */
export async function publishNativeShare(
  room: Room,
  staged: NativeStagedShare,
  config: ScreenShareConfig,
  build: ScreenShareBuildResult,
): Promise<boolean> {
  const source = useVoiceStore.getState().streamTokenSource;
  if (!source || _live) return false;
  let pass: { token: string; url: string };
  try {
    const api = getApiForOrigin(source.origin).livekit;
    pass = source.isDm ? await api.dmStreamToken(source.channelId) : await api.streamToken(source.channelId);
  } catch (err) {
    console.warn('[NativeShare] The call\'s server issued no stream token:', err);
    useUIStore.getState().addToast(describeError(err), 'warning', 8000);
    return false;
  }
  const quality = nativeShareQuality(staged.sourceId, config, build);
  // The preview holds a capture of the same source; the share has its own.
  dropNativeStage();
  const answer = await startShellShare({ url: pass.url || source.url, token: pass.token, ...quality });
  if (!answer.ok) {
    console.warn('[NativeShare] The shell did not start the share:', answer.reason);
    return false;
  }
  const live: LiveShare = { room, quality, unsubscribe: () => { } };
  live.unsubscribe = onShellShareEvent((event) => heard(live, event));
  _live = live;
  useNativeShareStore.setState({ codec: quality.codec, stats: null, reconnecting: false });
  useVoiceStore.setState({
    isScreenSharing: true,
    screenShareAudio: quality.audio ? 'published' : 'acquirable',
  });
  return true;
}

/**
 * The user's settings changed while the share runs: the shell is told what
 * differs. Another codec is another publication, so the share is started
 * again with it, on the same source; viewers are told it is a republish.
 */
export function applyNativeShareConfig(config: ScreenShareConfig, build: ScreenShareBuildResult): Promise<void> {
  _applying = _applying.then(async () => {
    const live = _live;
    if (!live) return;
    const next = nativeShareQuality(live.quality.sourceId, config, build);
    const change = nativeShareChange(live.quality, next);
    if (change === null) return;
    if (change === 'restart') {
      await restart(live, next);
      return;
    }
    const answer = await updateShellShare(change);
    if (_live !== live) return;
    if (!answer.ok) {
      console.warn('[NativeShare] The shell did not change the share:', answer.reason);
      // The sound is the one change a user sees refused; the rest stays as it was.
      if (change.audio === true) {
        useVoiceStore.setState({ screenShareAudio: 'acquirable' });
        toast('voice:streamSettings.systemAudioStartFailed');
      }
      return;
    }
    live.quality = next;
    if (change.audio !== undefined) {
      useVoiceStore.setState({ screenShareAudio: next.audio ? 'published' : 'acquirable' });
    }
  }).catch((err: unknown) => {
    console.warn('[NativeShare] A change to the share failed:', err);
  });
  return _applying;
}

async function restart(live: LiveShare, next: NativeShareQuality): Promise<void> {
  const source = useVoiceStore.getState().streamTokenSource;
  if (!source) return;
  let pass: { token: string; url: string };
  try {
    const api = getApiForOrigin(source.origin).livekit;
    pass = source.isDm ? await api.dmStreamToken(source.channelId) : await api.streamToken(source.channelId);
  } catch (err) {
    console.warn('[NativeShare] No stream token for the share\'s new codec; it goes on as it was:', err);
    return;
  }
  if (_live !== live) return;
  // Viewers keep watching across the gap between the two publications.
  announce(live.room, 'stream_republish');
  stopShellShare();
  const answer = await startShellShare({ url: pass.url || source.url, token: pass.token, ...next });
  if (_live !== live) return;
  if (!answer.ok) {
    console.warn('[NativeShare] The share did not come back with its new codec:', answer.reason);
    settle(live, true);
    toast('voice:streamSettings.shareEndedConnection');
    return;
  }
  live.quality = next;
  useNativeShareStore.setState({ codec: next.codec });
  useVoiceStore.setState({ screenShareAudio: next.audio ? 'published' : 'acquirable' });
}

/** The user stopped the share. */
export function stopNativeShare(): void {
  const live = _live;
  if (!live) return;
  // Said first: viewers handle the message on either side of the removal.
  announce(live.room, 'stream_stop');
  stopShellShare();
  settle(live, false);
}

/**
 * The page left the call, or its room is gone: the share has no call to be
 * in. Nobody is left to tell.
 */
export function endNativeShareWithRoom(room: Room): void {
  const live = _live;
  if (!live || live.room !== room) return;
  stopShellShare();
  live.unsubscribe();
  _live = null;
  useNativeShareStore.setState({ codec: null, stats: null, reconnecting: false });
  useVoiceStore.setState({ isScreenSharing: false, screenShareAudio: null });
}

/**
 * The page's own room came back from a full reconnect. The share never
 * stopped, but the page's participant was replaced for everyone else, and a
 * viewer for whom the owner left saw the share end with it.
 */
export function resumeNativeShareAfterReconnect(room: Room): void {
  if (_live?.room === room) announce(room, 'stream_resume');
}

/** Test seam. */
export function resetNativeShareForTests(): void {
  _live?.unsubscribe();
  _live = null;
  _applying = Promise.resolve();
  useNativeShareStore.setState({ codec: null, stats: null, reconnecting: false });
}
