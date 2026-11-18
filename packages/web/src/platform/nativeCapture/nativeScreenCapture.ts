/**
 * Screen capture by the native macOS shell, as a video track.
 *
 * WebKit's own `getDisplayMedia` cannot be told which source to take, gives
 * thirty frames a second at point resolution and no system audio. The native
 * shell captures the source itself and hands the frames to the page over a
 * local WebSocket; a worker decodes them into a track
 * (`reader.worker.ts`). The rest of the app sees an ordinary
 * `MediaStreamTrack`: it previews it, publishes it and stops it as it would
 * one from `getDisplayMedia`.
 *
 * In Electron and in browsers none of this is used: the bridge has no
 * `startNativeScreenCapture`.
 */
import { getElectronAPI } from '../platform';
import type { ReaderEvent, ReaderRequest } from './reader.worker';

/** The most a capture may measure, and its rate. A side left out is not limited. */
export interface NativeCaptureLimits {
  maxWidth?: number;
  maxHeight?: number;
  frameRate: number;
}

/** As much of a `Worker` as this module uses; a test passes a fake. */
export interface ReaderWorker {
  onmessage: ((event: MessageEvent<ReaderEvent>) => void) | null;
  postMessage(message: ReaderRequest): void;
  terminate(): void;
}

export interface NativeCaptureEnvironment {
  createWorker(): ReaderWorker;
}

const pageEnvironment: NativeCaptureEnvironment = {
  createWorker: () => new Worker(new URL('./reader.worker.ts', import.meta.url), { type: 'module' }),
};

/** How long the worker has to hand over its track. */
const TRACK_TIMEOUT_MS = 10_000;

interface Capture {
  /** The shell's id of the capture that feeds the track now. */
  id: string;
  readonly sourceId: string;
  limits: NativeCaptureLimits;
  readonly worker: ReaderWorker;
  readonly track: MediaStreamTrack;
  /** The track's own `stop`, before this module put its own in its place. */
  readonly stopTrack: () => void;
  ended: boolean;
  /** Changes of size and rate, one after another. */
  changing: Promise<void>;
}

const capturesByTrack = new WeakMap<MediaStreamTrack, Capture>();
/** The captures that run, to find the one the shell says has ended. */
const running = new Set<Capture>();
let stopListening: (() => void) | null = null;

/** Whether this shell captures the screen itself. */
export function canCaptureNatively(): boolean {
  return typeof getElectronAPI()?.startNativeScreenCapture === 'function' && typeof Worker !== 'undefined';
}

/** Whether a track is fed by a native capture. */
export function isNativeScreenCapture(track: MediaStreamTrack): boolean {
  return capturesByTrack.has(track);
}

function refusal(reason: string): Error {
  // "Not supported" is what the setup screen has words for; everything else
  // is a capture that failed.
  if (reason === 'unsupported') return new DOMException('Native screen capture is not available here', 'NotSupportedError');
  return new Error(`Native screen capture did not start: ${reason}`);
}

/**
 * Starts a native capture of a source the shell listed and returns it as a
 * stream with one video track. Stopping the track ends the capture; when the
 * capture ends by itself the track fires `ended`.
 */
export async function acquireNativeScreenCapture(
  sourceId: string,
  limits: NativeCaptureLimits,
  environment: NativeCaptureEnvironment = pageEnvironment,
): Promise<MediaStream> {
  const api = getElectronAPI();
  if (!api?.startNativeScreenCapture) throw refusal('unsupported');
  const answer = await api.startNativeScreenCapture({ sourceId, ...limits });
  if (!answer.ok) throw refusal(answer.reason);

  const worker = environment.createWorker();
  let track: MediaStreamTrack;
  try {
    track = await trackOf(worker, answer.url, answer.token);
  } catch (err) {
    worker.terminate();
    api.stopNativeScreenCapture?.(answer.id);
    throw err;
  }

  const capture: Capture = {
    id: answer.id,
    sourceId,
    limits,
    worker,
    track,
    stopTrack: track.stop.bind(track),
    ended: false,
    changing: Promise.resolve(),
  };
  capturesByTrack.set(track, capture);
  running.add(capture);
  // Whoever stops the track stops the capture: the setup screen dropping a
  // preview, the share ending, LiveKit unpublishing.
  track.stop = () => end(capture, false);
  // The channel closing under a running capture is the capture ending.
  worker.onmessage = (event) => {
    if (event.data.type === 'closed') end(capture, true);
  };
  listenForEndedCaptures();
  return new MediaStream([track]);
}

/**
 * Makes a running native capture follow another size or rate. The track stays:
 * a second capture of the same source is started with the new limits, the
 * worker moves to its channel, and the first one is stopped. Nothing happens
 * when the limits are the ones it already has.
 */
export function reconfigureNativeScreenCapture(track: MediaStreamTrack, limits: NativeCaptureLimits): Promise<void> {
  const capture = capturesByTrack.get(track);
  if (!capture) return Promise.resolve();
  const change = capture.changing.then(async () => {
    if (capture.ended || sameLimits(capture.limits, limits)) return;
    const api = getElectronAPI();
    if (!api?.startNativeScreenCapture) return;
    const answer = await api.startNativeScreenCapture({ sourceId: capture.sourceId, ...limits });
    // Refused: the capture that runs keeps running as it was.
    if (!answer.ok) throw refusal(answer.reason);
    if (capture.ended) {
      api.stopNativeScreenCapture?.(answer.id);
      return;
    }
    const previous = capture.id;
    capture.id = answer.id;
    capture.limits = limits;
    capture.worker.postMessage({ type: 'connect', url: answer.url, token: answer.token });
    api.stopNativeScreenCapture?.(previous);
  });
  // A change that failed must not stop the ones after it.
  capture.changing = change.catch(() => {});
  return change;
}

function sameLimits(a: NativeCaptureLimits, b: NativeCaptureLimits): boolean {
  return a.maxWidth === b.maxWidth && a.maxHeight === b.maxHeight && a.frameRate === b.frameRate;
}

function trackOf(worker: ReaderWorker, url: string, token: string): Promise<MediaStreamTrack> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error('The capture reader did not hand over a track'));
    }, TRACK_TIMEOUT_MS);
    worker.onmessage = (event) => {
      const message = event.data;
      if (message.type === 'track') {
        clearTimeout(timer);
        resolve(message.track);
      } else if (message.type === 'failed') {
        clearTimeout(timer);
        reject(refusal('unsupported'));
      } else if (message.type === 'closed') {
        clearTimeout(timer);
        reject(new Error('The capture channel closed before a track was made'));
      }
    };
    worker.postMessage({ type: 'connect', url, token });
  });
}

/**
 * @param byItself the capture ended without the app asking: listeners on the
 *   track are told, as they are when a browser's capture ends.
 */
function end(capture: Capture, byItself: boolean): void {
  if (capture.ended) return;
  capture.ended = true;
  running.delete(capture);
  capture.worker.onmessage = null;
  capture.worker.postMessage({ type: 'close' });
  capture.worker.terminate();
  getElectronAPI()?.stopNativeScreenCapture?.(capture.id);
  capture.stopTrack();
  // `stop()` never fires `ended`; a capture that ended by itself has to.
  if (byItself) capture.track.dispatchEvent(new Event('ended'));
}

function listenForEndedCaptures(): void {
  if (stopListening) return;
  stopListening = getElectronAPI()?.onNativeScreenCaptureEnded?.(({ id }) => {
    for (const capture of running) {
      if (capture.id === id) end(capture, true);
    }
  }) ?? null;
}
