/**
 * The system's sound, captured by the native macOS shell, as an audio track.
 *
 * WebKit's `getDisplayMedia` gives a share no system audio. The native shell
 * captures everything the Mac plays except the app itself (so viewers do not
 * hear themselves) and hands the samples to the page over a local WebSocket.
 * A worker reads them (`systemAudio.worker.ts`) and passes them straight to an
 * audio worklet (`systemAudio.worklet.ts`), whose output is the track. The
 * rest of the app sees an ordinary `MediaStreamTrack`: it publishes it and
 * stops it as it would one from `getDisplayMedia`.
 *
 * The capture is apart from the picture's: the System Audio switch starts and
 * stops it while a share runs.
 *
 * In Electron and in browsers none of this is used: the bridge has no
 * `startNativeSystemAudio`.
 */
import { getElectronAPI } from '../platform';
import { SOUND_PROCESSOR } from './pcmBuffer';
import type { SoundReaderEvent, SoundReaderRequest } from './systemAudio.worker';
import type { SoundProcessorRequest, SoundProcessorStats } from './systemAudio.worklet';
// Built as a script of its own (it runs on the audio thread), and named by its address.
import soundWorkletUrl from './systemAudio.worklet.ts?worker&url';

/** As much of a `Worker` as this module uses; a test passes a fake. */
export interface SoundWorker {
  onmessage: ((event: MessageEvent<SoundReaderEvent>) => void) | null;
  postMessage(message: SoundReaderRequest, transfer?: Transferable[]): void;
  terminate(): void;
}

/** The audio graph that turns samples into a track. */
export interface SoundGraph {
  readonly track: MediaStreamTrack;
  /** Hands the audio thread the port its samples arrive on. */
  attach(port: MessagePort): void;
  /** How the audio thread is doing; null when it does not answer. */
  stats(): Promise<SoundProcessorStats | null>;
  close(): void;
}

export interface SystemAudioEnvironment {
  createWorker(): SoundWorker;
  createGraph(sampleRate: number, channels: number): Promise<SoundGraph>;
  /** A pair of connected ports: one for the worker, one for the audio thread. */
  createPorts(): { forWorker: MessagePort; forGraph: MessagePort };
}

/** How long the audio thread has to answer a question about itself. */
const STATS_TIMEOUT_MS = 1000;

async function createGraph(sampleRate: number, channels: number): Promise<SoundGraph> {
  // A context of its own at the capture's rate: nothing is resampled, and
  // the app's playback context is not touched.
  const context = new AudioContext({ sampleRate, latencyHint: 'interactive' });
  try {
    if (context.sampleRate !== sampleRate) {
      throw new Error(`The audio context runs at ${context.sampleRate} Hz, the capture at ${sampleRate} Hz`);
    }
    await context.audioWorklet.addModule(soundWorkletUrl);
    const node = new AudioWorkletNode(context, SOUND_PROCESSOR, {
      numberOfInputs: 0,
      numberOfOutputs: 1,
      outputChannelCount: [channels],
      processorOptions: { channels },
    });
    // Into a stream only: the sound is for the viewers, not for the speakers.
    const destination = context.createMediaStreamDestination();
    node.connect(destination);
    const track = destination.stream.getAudioTracks()[0];
    if (!track) throw new Error('The audio graph gave no track');
    // Not waited for: where a context needs a gesture to start, the track is
    // silent until it has one, which is no reason to refuse the capture.
    void context.resume().catch(() => undefined);

    const post = (request: SoundProcessorRequest, transfer: Transferable[] = []): void => {
      node.port.postMessage(request, transfer);
    };
    // One question at a time: an answer says nothing of which question it
    // is to, so whoever asks while one is out gets that one's answer.
    let asking: Promise<SoundProcessorStats | null> | null = null;
    return {
      track,
      attach: (port) => post({ type: 'source', port }, [port]),
      stats: () => {
        asking ??= new Promise<SoundProcessorStats | null>((resolve) => {
          const settle = (stats: SoundProcessorStats | null): void => {
            clearTimeout(timer);
            node.port.onmessage = null;
            asking = null;
            resolve(stats);
          };
          const timer = setTimeout(() => settle(null), STATS_TIMEOUT_MS);
          node.port.onmessage = (event: MessageEvent<SoundProcessorStats>) => settle(event.data);
          post({ type: 'stats' });
        });
        return asking;
      },
      close: () => {
        node.disconnect();
        void context.close().catch(() => undefined);
      },
    };
  } catch (err) {
    void context.close().catch(() => undefined);
    throw err;
  }
}

const pageEnvironment: SystemAudioEnvironment = {
  createWorker: () => new Worker(new URL('./systemAudio.worker.ts', import.meta.url), { type: 'module' }),
  createGraph,
  createPorts: () => {
    const channel = new MessageChannel();
    return { forWorker: channel.port1, forGraph: channel.port2 };
  },
};

interface Capture {
  readonly id: string;
  readonly worker: SoundWorker;
  readonly graph: SoundGraph;
  readonly track: MediaStreamTrack;
  /** The track's own `stop`, before this module put its own in its place. */
  readonly stopTrack: () => void;
  ended: boolean;
}

const capturesByTrack = new WeakMap<MediaStreamTrack, Capture>();
/** The captures that run, to find the one the shell says has ended. */
const running = new Set<Capture>();
let stopListening: (() => void) | null = null;

/** Whether this shell captures the system's sound itself. */
export function canCaptureSystemAudioNatively(): boolean {
  return typeof getElectronAPI()?.startNativeSystemAudio === 'function'
    && typeof Worker !== 'undefined'
    && typeof AudioWorkletNode !== 'undefined';
}

function refusal(reason: string): Error {
  if (reason === 'unsupported') return new DOMException('Native system audio is not available here', 'NotSupportedError');
  return new Error(`Native system audio did not start: ${reason}`);
}

/**
 * Starts a capture of the system's sound and returns it as an audio track.
 * Stopping the track ends the capture; when the capture ends by itself the
 * track fires `ended`.
 */
export async function acquireNativeSystemAudio(
  environment: SystemAudioEnvironment = pageEnvironment,
): Promise<MediaStreamTrack> {
  const api = getElectronAPI();
  if (!api?.startNativeSystemAudio) throw refusal('unsupported');
  const answer = await api.startNativeSystemAudio();
  if (!answer.ok) throw refusal(answer.reason);

  let graph: SoundGraph;
  try {
    graph = await environment.createGraph(answer.sampleRate, answer.channels);
  } catch (err) {
    api.stopNativeSystemAudio?.(answer.id);
    throw err;
  }
  const worker = environment.createWorker();
  const ports = environment.createPorts();
  graph.attach(ports.forGraph);
  worker.postMessage({ type: 'connect', url: answer.url, token: answer.token, port: ports.forWorker }, [ports.forWorker]);

  const track = graph.track;
  const capture: Capture = {
    id: answer.id,
    worker,
    graph,
    track,
    stopTrack: track.stop.bind(track),
    ended: false,
  };
  capturesByTrack.set(track, capture);
  running.add(capture);
  // Whoever stops the track stops the capture: the System Audio switch, the
  // share ending, LiveKit unpublishing.
  track.stop = () => end(capture, false);
  // The channel closing under a running capture is the capture ending.
  worker.onmessage = (event) => {
    if (event.data.type === 'closed') end(capture, true);
  };
  listenForEndedCaptures();
  return track;
}

/**
 * How the audio thread behind a native system-audio track is doing: frames
 * taken in, skipped, waiting, and how often it ran dry. Null for any other
 * track. A diagnostic, for the workbench page and the shell's check.
 */
export function nativeSystemAudioStats(track: MediaStreamTrack): Promise<SoundProcessorStats | null> {
  const capture = capturesByTrack.get(track);
  return capture && !capture.ended ? capture.graph.stats() : Promise.resolve(null);
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
  getElectronAPI()?.stopNativeSystemAudio?.(capture.id);
  capture.stopTrack();
  capture.graph.close();
  // `stop()` never fires `ended`; a capture that ended by itself has to.
  if (byItself) capture.track.dispatchEvent(new Event('ended'));
}

function listenForEndedCaptures(): void {
  if (stopListening) return;
  stopListening = getElectronAPI()?.onNativeSystemAudioEnded?.(({ id }) => {
    for (const capture of running) {
      if (capture.id === id) end(capture, true);
    }
  }) ?? null;
}
