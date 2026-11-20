import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type { ReaderEvent, ReaderRequest } from './reader.worker';
import type { ReaderWorker } from './nativeScreenCapture';

/** A track that can be stopped and told that it ended, and nothing more. */
class FakeTrack extends EventTarget {
  kind = 'video';
  stopped = 0;
  stop() { this.stopped += 1; }
  /** As a track made in a worker answers: what it is, and nothing of its size. */
  getSettings(): MediaTrackSettings { return { deviceId: 'generated' }; }
}

class FakeStream {
  constructor(private readonly tracks: FakeTrack[]) {}
  getVideoTracks() { return this.tracks; }
}

/** The worker's side, played by the test. */
function fakeWorker() {
  const posted: ReaderRequest[] = [];
  const track = new FakeTrack();
  const worker: ReaderWorker & { terminated: boolean } = {
    onmessage: null,
    terminated: false,
    postMessage(message) {
      posted.push(message);
      // A real worker hands over its track on the first connect.
      if (message.type === 'connect' && posted.filter((m) => m.type === 'connect').length === 1 && handsOver) {
        queueMicrotask(() => say({ type: 'track', track: track as unknown as MediaStreamTrack }));
      }
    },
    terminate() { this.terminated = true; },
  };
  let handsOver = true;
  const say = (event: ReaderEvent) => worker.onmessage?.({ data: event } as MessageEvent<ReaderEvent>);
  return { worker, posted, track, say, withholdTrack: () => { handsOver = false; } };
}

/** The shell's side of the bridge. */
function fakeShell() {
  let next = 0;
  let ended: ((event: { id: string }) => void) | null = null;
  const api = {
    startNativeScreenCapture: vi.fn<(options: unknown) => Promise<unknown>>(async () => {
      next += 1;
      return { ok: true, id: `capture-${next}`, url: `wss://127.0.0.1:5000${next}/`, token: `token-${next}`, width: 1670, height: 1080, frameRate: 60 };
    }),
    stopNativeScreenCapture: vi.fn(),
    onNativeScreenCaptureEnded: vi.fn((callback: (event: { id: string }) => void) => {
      ended = callback;
      return () => { ended = null; };
    }),
  };
  return { api, sayEnded: (id: string) => ended?.({ id }) };
}

async function load() {
  vi.resetModules();
  return import('./nativeScreenCapture');
}

describe('native screen capture', () => {
  let shell: ReturnType<typeof fakeShell>;

  beforeEach(() => {
    shell = fakeShell();
    vi.stubGlobal('MediaStream', FakeStream);
    // The test environment has no workers; the module only asks whether
    // there are any, and every test passes its own.
    vi.stubGlobal('Worker', class {});
    (window as unknown as { backspace?: unknown }).backspace = shell.api;
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    delete (window as unknown as { backspace?: unknown }).backspace;
  });

  it('is there only where the shell has it', async () => {
    const capture = await load();
    expect(capture.canCaptureNatively()).toBe(true);
    (window as unknown as { backspace?: unknown }).backspace = { platform: 'darwin' };
    expect(capture.canCaptureNatively()).toBe(false);
    delete (window as unknown as { backspace?: unknown }).backspace;
    expect(capture.canCaptureNatively()).toBe(false);
    // Nor where there are no workers to decode in.
    (window as unknown as { backspace?: unknown }).backspace = shell.api;
    vi.stubGlobal('Worker', undefined);
    expect(capture.canCaptureNatively()).toBe(false);
  });

  it('makes the track say the size and rate of what the shell sends', async () => {
    const capture = await load();
    const { worker, track } = fakeWorker();
    await capture.acquireNativeScreenCapture('screen:1:0', { frameRate: 60 }, { createWorker: () => worker });
    expect(track.getSettings()).toEqual({ deviceId: 'generated', width: 1670, height: 1080, frameRate: 60 });

    // Another size behind the same track: the track follows.
    shell.api.startNativeScreenCapture.mockResolvedValueOnce({
      ok: true, id: 'capture-2', url: 'wss://127.0.0.1:50002/', token: 'token-2', width: 1114, height: 720, frameRate: 30,
    });
    await capture.reconfigureNativeScreenCapture(
      track as unknown as MediaStreamTrack, { maxWidth: 1280, maxHeight: 720, frameRate: 30 },
    );
    expect(track.getSettings()).toEqual({ deviceId: 'generated', width: 1114, height: 720, frameRate: 30 });
  });

  it('follows the size of a video that changes by itself', async () => {
    const capture = await load();
    const { worker, track, say } = fakeWorker();
    await capture.acquireNativeScreenCapture('window:7:0', { frameRate: 60 }, { createWorker: () => worker });
    say({ type: 'format', width: 1440, height: 960 });
    expect(track.getSettings()).toMatchObject({ width: 1440, height: 960, frameRate: 60 });
  });

  it('starts a capture of the source and returns the worker\'s track', async () => {
    const capture = await load();
    const { worker, posted, track } = fakeWorker();
    const stream = await capture.acquireNativeScreenCapture(
      'screen:1:0', { maxWidth: 1920, maxHeight: 1080, frameRate: 60 }, { createWorker: () => worker },
    );
    expect(shell.api.startNativeScreenCapture).toHaveBeenCalledWith({ sourceId: 'screen:1:0', maxWidth: 1920, maxHeight: 1080, frameRate: 60 });
    expect(posted).toEqual([{ type: 'connect', url: 'wss://127.0.0.1:50001/', token: 'token-1' }]);
    expect(stream.getVideoTracks()).toEqual([track]);
    expect(capture.isNativeScreenCapture(track as unknown as MediaStreamTrack)).toBe(true);
    expect(capture.isNativeScreenCapture(new FakeTrack() as unknown as MediaStreamTrack)).toBe(false);
  });

  it('ends the capture when the track is stopped, without saying it ended', async () => {
    const capture = await load();
    const { worker, posted, track } = fakeWorker();
    await capture.acquireNativeScreenCapture('screen:1:0', { frameRate: 30 }, { createWorker: () => worker });
    const ended = vi.fn();
    track.addEventListener('ended', ended);

    track.stop();
    expect(shell.api.stopNativeScreenCapture).toHaveBeenCalledWith('capture-1');
    expect(posted.at(-1)).toEqual({ type: 'close' });
    expect(worker.terminated).toBe(true);
    expect(track.stopped).toBe(1);
    expect(ended).not.toHaveBeenCalled();

    // Stopping twice is stopping once.
    track.stop();
    expect(shell.api.stopNativeScreenCapture).toHaveBeenCalledTimes(1);
  });

  it('tells the track when the shell says its capture ended', async () => {
    const capture = await load();
    const first = fakeWorker();
    const second = fakeWorker();
    const workers = [first.worker, second.worker];
    const environment = { createWorker: () => workers.shift()! };
    await capture.acquireNativeScreenCapture('screen:1:0', { frameRate: 30 }, environment);
    await capture.acquireNativeScreenCapture('window:7:0', { frameRate: 30 }, environment);
    const firstEnded = vi.fn();
    const secondEnded = vi.fn();
    first.track.addEventListener('ended', firstEnded);
    second.track.addEventListener('ended', secondEnded);
    // One subscription serves every capture.
    expect(shell.api.onNativeScreenCaptureEnded).toHaveBeenCalledTimes(1);

    shell.sayEnded('capture-2');
    expect(secondEnded).toHaveBeenCalledTimes(1);
    expect(second.track.stopped).toBe(1);
    expect(second.worker.terminated).toBe(true);
    expect(firstEnded).not.toHaveBeenCalled();
    expect(first.worker.terminated).toBe(false);

    // An id nobody has, and one already ended, change nothing.
    shell.sayEnded('capture-9');
    shell.sayEnded('capture-2');
    expect(secondEnded).toHaveBeenCalledTimes(1);
    expect(firstEnded).not.toHaveBeenCalled();
  });

  it('treats a channel that closes under a running capture as its end', async () => {
    const capture = await load();
    const { worker, track, say } = fakeWorker();
    await capture.acquireNativeScreenCapture('screen:1:0', { frameRate: 30 }, { createWorker: () => worker });
    const ended = vi.fn();
    track.addEventListener('ended', ended);
    say({ type: 'closed' });
    expect(ended).toHaveBeenCalledTimes(1);
    expect(shell.api.stopNativeScreenCapture).toHaveBeenCalledWith('capture-1');
  });

  it('fails with the shell\'s refusal and starts no worker', async () => {
    const capture = await load();
    const createWorker = vi.fn();
    shell.api.startNativeScreenCapture.mockResolvedValueOnce({ ok: false, reason: 'no-source' });
    await expect(capture.acquireNativeScreenCapture('window:7:0', { frameRate: 30 }, { createWorker }))
      .rejects.toThrow('no-source');
    shell.api.startNativeScreenCapture.mockResolvedValueOnce({ ok: false, reason: 'unsupported' });
    await expect(capture.acquireNativeScreenCapture('window:7:0', { frameRate: 30 }, { createWorker }))
      .rejects.toMatchObject({ name: 'NotSupportedError' });
    expect(createWorker).not.toHaveBeenCalled();
  });

  it('stops the capture it started when the worker cannot make a track', async () => {
    const capture = await load();
    const { worker, say, withholdTrack } = fakeWorker();
    withholdTrack();
    const acquiring = capture.acquireNativeScreenCapture('screen:1:0', { frameRate: 30 }, { createWorker: () => worker });
    await vi.waitFor(() => expect(worker.onmessage).not.toBeNull());
    say({ type: 'failed', reason: 'no VideoTrackGenerator' });
    await expect(acquiring).rejects.toMatchObject({ name: 'NotSupportedError' });
    expect(worker.terminated).toBe(true);
    expect(shell.api.stopNativeScreenCapture).toHaveBeenCalledWith('capture-1');
  });

  it('follows new limits behind the same track', async () => {
    const capture = await load();
    const { worker, posted, track } = fakeWorker();
    await capture.acquireNativeScreenCapture(
      'screen:1:0', { maxWidth: 1920, maxHeight: 1080, frameRate: 60 }, { createWorker: () => worker },
    );
    const mediaTrack = track as unknown as MediaStreamTrack;

    // The limits it already has: nothing to do.
    await capture.reconfigureNativeScreenCapture(mediaTrack, { maxWidth: 1920, maxHeight: 1080, frameRate: 60 });
    expect(shell.api.startNativeScreenCapture).toHaveBeenCalledTimes(1);

    await capture.reconfigureNativeScreenCapture(mediaTrack, { maxWidth: 2560, maxHeight: 1440, frameRate: 60 });
    expect(shell.api.startNativeScreenCapture).toHaveBeenLastCalledWith({ sourceId: 'screen:1:0', maxWidth: 2560, maxHeight: 1440, frameRate: 60 });
    // The worker moves to the new channel, then the old capture goes.
    expect(posted.at(-1)).toEqual({ type: 'connect', url: 'wss://127.0.0.1:50002/', token: 'token-2' });
    expect(shell.api.stopNativeScreenCapture.mock.calls).toEqual([['capture-1']]);
    expect(track.stopped).toBe(0);

    // The track now belongs to the second capture.
    track.stop();
    expect(shell.api.stopNativeScreenCapture).toHaveBeenLastCalledWith('capture-2');
  });

  it('keeps the capture it has when new limits are refused', async () => {
    const capture = await load();
    const { worker, posted, track } = fakeWorker();
    await capture.acquireNativeScreenCapture('screen:1:0', { frameRate: 60 }, { createWorker: () => worker });
    shell.api.startNativeScreenCapture.mockResolvedValueOnce({ ok: false, reason: 'too-many' });
    await expect(capture.reconfigureNativeScreenCapture(track as unknown as MediaStreamTrack, { frameRate: 30 }))
      .rejects.toThrow('too-many');
    expect(posted.filter((m) => m.type === 'connect')).toHaveLength(1);
    expect(shell.api.stopNativeScreenCapture).not.toHaveBeenCalled();

    // A later change still goes through.
    await capture.reconfigureNativeScreenCapture(track as unknown as MediaStreamTrack, { frameRate: 30 });
    expect(posted.filter((m) => m.type === 'connect')).toHaveLength(2);
  });

  it('applies changes one after another', async () => {
    const capture = await load();
    const { worker, posted, track } = fakeWorker();
    await capture.acquireNativeScreenCapture('screen:1:0', { frameRate: 60 }, { createWorker: () => worker });
    const mediaTrack = track as unknown as MediaStreamTrack;
    await Promise.all([
      capture.reconfigureNativeScreenCapture(mediaTrack, { frameRate: 30 }),
      capture.reconfigureNativeScreenCapture(mediaTrack, { frameRate: 15 }),
    ]);
    expect(posted.filter((m) => m.type === 'connect').map((m) => (m as { url: string }).url)).toEqual([
      'wss://127.0.0.1:50001/', 'wss://127.0.0.1:50002/', 'wss://127.0.0.1:50003/',
    ]);
    expect(shell.api.stopNativeScreenCapture.mock.calls).toEqual([['capture-1'], ['capture-2']]);
  });

  it('starts nothing for a track that was stopped while new limits were on their way', async () => {
    const capture = await load();
    const { worker, track } = fakeWorker();
    await capture.acquireNativeScreenCapture('screen:1:0', { frameRate: 60 }, { createWorker: () => worker });
    // The shell takes its time over the second capture.
    let answer: (value: unknown) => void = () => {};
    shell.api.startNativeScreenCapture.mockImplementationOnce(() => new Promise((resolve) => { answer = resolve; }));
    const changing = capture.reconfigureNativeScreenCapture(track as unknown as MediaStreamTrack, { frameRate: 30 });
    await vi.waitFor(() => expect(shell.api.startNativeScreenCapture).toHaveBeenCalledTimes(2));
    track.stop();
    answer({ ok: true, id: 'capture-2', url: 'wss://127.0.0.1:50002/', token: 'token-2', width: 2, height: 2, frameRate: 30 });
    await changing;
    // The capture started for the change is stopped again; the first one was
    // stopped with the track.
    expect(shell.api.stopNativeScreenCapture.mock.calls.map(([id]) => id).sort()).toEqual(['capture-1', 'capture-2']);
  });

  it('asks for nothing once the track is stopped', async () => {
    const capture = await load();
    const { worker, track } = fakeWorker();
    await capture.acquireNativeScreenCapture('screen:1:0', { frameRate: 60 }, { createWorker: () => worker });
    track.stop();
    await capture.reconfigureNativeScreenCapture(track as unknown as MediaStreamTrack, { frameRate: 30 });
    expect(shell.api.startNativeScreenCapture).toHaveBeenCalledTimes(1);
  });

  it('leaves a track that is not a native capture alone', async () => {
    const capture = await load();
    await capture.reconfigureNativeScreenCapture(new FakeTrack() as unknown as MediaStreamTrack, { frameRate: 30 });
    expect(shell.api.startNativeScreenCapture).not.toHaveBeenCalled();
  });
});
