import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type { SoundReaderEvent, SoundReaderRequest } from './systemAudio.worker';
import type { SoundGraph, SoundWorker, SystemAudioEnvironment } from './nativeSystemAudio';

/** A track that can be stopped and told that it ended, and nothing more. */
class FakeTrack extends EventTarget {
  kind = 'audio';
  stopped = 0;
  stop() { this.stopped += 1; }
}

/** What stands in for a port: the test only follows where each one goes. */
const forWorker = { name: 'for the worker' } as unknown as MessagePort;
const forGraph = { name: 'for the audio thread' } as unknown as MessagePort;

/** The worker, the audio graph and the ports, played by the test. */
function fakeEnvironment() {
  const posted: Array<{ message: SoundReaderRequest; transfer: Transferable[] | undefined }> = [];
  const track = new FakeTrack();
  const worker: SoundWorker & { terminated: boolean } = {
    onmessage: null,
    terminated: false,
    postMessage(message, transfer) { posted.push({ message, transfer }); },
    terminate() { this.terminated = true; },
  };
  const graph = {
    track: track as unknown as MediaStreamTrack,
    attached: [] as MessagePort[],
    closed: 0,
    attach(port: MessagePort) { this.attached.push(port); },
    stats: vi.fn(async () => ({ type: 'stats' as const, received: 480, played: 240, skipped: 0, waiting: 240, ranDry: 0, clock: 1, wall: 1000 })),
    close() { this.closed += 1; },
  };
  const createGraph = vi.fn<(sampleRate: number, channels: number) => Promise<SoundGraph>>(async () => graph);
  const environment: SystemAudioEnvironment = {
    createWorker: () => worker,
    createGraph,
    createPorts: () => ({ forWorker, forGraph }),
  };
  const say = (event: SoundReaderEvent) => worker.onmessage?.({ data: event } as MessageEvent<SoundReaderEvent>);
  return { environment, worker, posted, track, graph, createGraph, say };
}

/** The shell's side of the bridge. */
function fakeShell() {
  let next = 0;
  let ended: ((event: { id: string }) => void) | null = null;
  const api = {
    startNativeSystemAudio: vi.fn<() => Promise<unknown>>(async () => {
      next += 1;
      return { ok: true, id: `sound-${next}`, url: `wss://127.0.0.1:5000${next}/`, token: `token-${next}`, sampleRate: 48_000, channels: 2 };
    }),
    stopNativeSystemAudio: vi.fn(),
    onNativeSystemAudioEnded: vi.fn((callback: (event: { id: string }) => void) => {
      ended = callback;
      return () => { ended = null; };
    }),
  };
  return { api, sayEnded: (id: string) => ended?.({ id }) };
}

async function load() {
  vi.resetModules();
  return import('./nativeSystemAudio');
}

function setBridge(value: unknown): void {
  (window as unknown as { backspace?: unknown }).backspace = value;
}

describe('native system audio', () => {
  let shell: ReturnType<typeof fakeShell>;

  beforeEach(() => {
    shell = fakeShell();
    // The test environment has neither workers nor audio worklets; the
    // module only asks whether there are any, and every test passes its own.
    vi.stubGlobal('Worker', class {});
    vi.stubGlobal('AudioWorkletNode', class {});
    setBridge(shell.api);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    setBridge(undefined);
  });

  it('is there only where the shell has it and the engine can play it into a track', async () => {
    const sound = await load();
    expect(sound.canCaptureSystemAudioNatively()).toBe(true);
    setBridge({ platform: 'darwin', startNativeScreenCapture: () => undefined });
    expect(sound.canCaptureSystemAudioNatively()).toBe(false);
    setBridge(undefined);
    expect(sound.canCaptureSystemAudioNatively()).toBe(false);
    setBridge(shell.api);
    vi.stubGlobal('AudioWorkletNode', undefined);
    expect(sound.canCaptureSystemAudioNatively()).toBe(false);
    vi.stubGlobal('AudioWorkletNode', class {});
    vi.stubGlobal('Worker', undefined);
    expect(sound.canCaptureSystemAudioNatively()).toBe(false);
  });

  it('starts a capture and returns the audio graph\'s track, fed by the worker', async () => {
    const sound = await load();
    const { environment, posted, track, graph, createGraph } = fakeEnvironment();
    const acquired = await sound.acquireNativeSystemAudio(environment);
    expect(acquired).toBe(track);
    expect(createGraph).toHaveBeenCalledWith(48_000, 2);
    // One end of the pair goes to the audio thread, the other to the worker.
    expect(graph.attached).toEqual([forGraph]);
    expect(posted).toEqual([{
      message: { type: 'connect', url: 'wss://127.0.0.1:50001/', token: 'token-1', port: forWorker },
      transfer: [forWorker],
    }]);
    expect(shell.api.stopNativeSystemAudio).not.toHaveBeenCalled();
  });

  it('says why when the shell refuses', async () => {
    const sound = await load();
    const { environment, createGraph } = fakeEnvironment();
    shell.api.startNativeSystemAudio.mockResolvedValueOnce({ ok: false, reason: 'no-permission' });
    await expect(sound.acquireNativeSystemAudio(environment)).rejects.toThrow(/no-permission/);
    shell.api.startNativeSystemAudio.mockResolvedValueOnce({ ok: false, reason: 'unsupported' });
    await expect(sound.acquireNativeSystemAudio(environment)).rejects.toMatchObject({ name: 'NotSupportedError' });
    expect(createGraph).not.toHaveBeenCalled();
  });

  it('is not supported where the bridge has no such capture', async () => {
    const sound = await load();
    setBridge({ platform: 'darwin' });
    await expect(sound.acquireNativeSystemAudio(fakeEnvironment().environment)).rejects.toMatchObject({ name: 'NotSupportedError' });
  });

  it('stops the shell\'s capture when the audio graph cannot be made', async () => {
    const sound = await load();
    const { environment, createGraph, posted } = fakeEnvironment();
    createGraph.mockRejectedValueOnce(new Error('no worklet'));
    await expect(sound.acquireNativeSystemAudio(environment)).rejects.toThrow('no worklet');
    expect(shell.api.stopNativeSystemAudio).toHaveBeenCalledWith('sound-1');
    expect(posted).toEqual([]);
  });

  it('ends the capture when the track is stopped, once', async () => {
    const sound = await load();
    const { environment, worker, posted, track, graph } = fakeEnvironment();
    const acquired = await sound.acquireNativeSystemAudio(environment);
    const ended = vi.fn();
    track.addEventListener('ended', ended);

    acquired.stop();
    acquired.stop();
    expect(shell.api.stopNativeSystemAudio).toHaveBeenCalledTimes(1);
    expect(shell.api.stopNativeSystemAudio).toHaveBeenCalledWith('sound-1');
    expect(posted.at(-1)?.message).toEqual({ type: 'close' });
    expect(worker.terminated).toBe(true);
    expect(track.stopped).toBe(1);
    expect(graph.closed).toBe(1);
    // `stop()` is the app's own doing: nobody is told.
    expect(ended).not.toHaveBeenCalled();
  });

  it('fires ended on the track when the shell says its capture ended', async () => {
    const sound = await load();
    const first = fakeEnvironment();
    const second = fakeEnvironment();
    await sound.acquireNativeSystemAudio(first.environment);
    await sound.acquireNativeSystemAudio(second.environment);
    const firstEnded = vi.fn();
    const secondEnded = vi.fn();
    first.track.addEventListener('ended', firstEnded);
    second.track.addEventListener('ended', secondEnded);

    shell.sayEnded('sound-2');
    expect(secondEnded).toHaveBeenCalledTimes(1);
    expect(firstEnded).not.toHaveBeenCalled();
    expect(second.graph.closed).toBe(1);
    expect(second.track.stopped).toBe(1);
    expect(first.graph.closed).toBe(0);
    // The shell is listened to once, however many captures there are.
    expect(shell.api.onNativeSystemAudioEnded).toHaveBeenCalledTimes(1);
  });

  it('fires ended on the track when its channel closes under it', async () => {
    const sound = await load();
    const { environment, track, say, graph } = fakeEnvironment();
    await sound.acquireNativeSystemAudio(environment);
    const ended = vi.fn();
    track.addEventListener('ended', ended);
    say({ type: 'closed' });
    expect(ended).toHaveBeenCalledTimes(1);
    expect(shell.api.stopNativeSystemAudio).toHaveBeenCalledWith('sound-1');
    expect(graph.closed).toBe(1);
  });

  it('reports how the audio thread is doing, for its own tracks while they run', async () => {
    const sound = await load();
    const { environment, graph } = fakeEnvironment();
    const acquired = await sound.acquireNativeSystemAudio(environment);
    expect(await sound.nativeSystemAudioStats(acquired)).toMatchObject({ received: 480, waiting: 240 });
    expect(await sound.nativeSystemAudioStats(new FakeTrack() as unknown as MediaStreamTrack)).toBeNull();
    acquired.stop();
    expect(await sound.nativeSystemAudioStats(acquired)).toBeNull();
    expect(graph.stats).toHaveBeenCalledTimes(1);
  });
});
