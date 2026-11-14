import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useVoiceStore } from '../stores/voiceStore';
import { stageScreenCapture } from './screenShare';

const source = vi.hoisted(() => ({ acquireAppExcludedSystemAudio: vi.fn() }));
vi.mock('./systemAudioSource', () => source);
vi.mock('./hwOverdrive', () => ({ activate: vi.fn(), deactivate: vi.fn() }));
vi.mock('../audio/AudioManager', () => ({
  AudioManager: { getInstance: () => ({ setInputVolume: vi.fn() }) },
}));
vi.mock('./livekitInternals', () => ({ getPublisherPC: vi.fn(), getMediaStreamTrack: vi.fn() }));

/**
 * #358: where the desktop app can build the system audio without Backspace's
 * own playback, that track replaces the loopback one in the staged capture.
 */

function fakeStream() {
  const video = { kind: 'video', readyState: 'live', contentHint: '', stop: vi.fn() };
  const added: unknown[] = [];
  const stream = {
    getVideoTracks: () => [video],
    getAudioTracks: () => added,
    getTracks: () => [video, ...added],
    addTrack: vi.fn((t: unknown) => added.push(t)),
  };
  return { stream: stream as unknown as MediaStream, video, added, addTrack: stream.addTrack };
}

function stubDisplayMedia(impl: () => Promise<MediaStream>) {
  const getDisplayMedia = vi.fn(impl);
  Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getDisplayMedia } });
  return getDisplayMedia;
}

beforeEach(() => {
  source.acquireAppExcludedSystemAudio.mockReset().mockResolvedValue(null);
  useVoiceStore.setState({ screenShareConfig: { ...useVoiceStore.getState().screenShareConfig, shareAudio: true } });
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('stageScreenCapture with an app-excluded system-audio source', () => {
  it('asks the screen capture for video only and adds the source track to the stream', async () => {
    const { stream, added, addTrack } = fakeStream();
    const track = { kind: 'audio', readyState: 'live', stop: vi.fn() } as unknown as MediaStreamTrack;
    source.acquireAppExcludedSystemAudio.mockResolvedValue(track);
    const getDisplayMedia = stubDisplayMedia(async () => stream);

    expect(await stageScreenCapture()).toBe(stream);
    expect(getDisplayMedia).toHaveBeenCalledWith(expect.objectContaining({ audio: false }));
    expect(addTrack).toHaveBeenCalledWith(track);
    expect(added).toEqual([track]);
  });

  it('stops the source track, and so unlinks it, when the screen capture is refused', async () => {
    const track = { kind: 'audio', readyState: 'live', stop: vi.fn() } as unknown as MediaStreamTrack;
    source.acquireAppExcludedSystemAudio.mockResolvedValue(track);
    stubDisplayMedia(async () => {
      throw new DOMException('Permission denied', 'NotAllowedError');
    });
    await expect(stageScreenCapture()).rejects.toThrow('Permission denied');
    expect(track.stop).toHaveBeenCalledTimes(1);
  });

  it('keeps the loopback capture, with its own-audio request, when there is no such source', async () => {
    const { stream, addTrack } = fakeStream();
    const getDisplayMedia = stubDisplayMedia(async () => stream);
    await stageScreenCapture();
    expect(getDisplayMedia).toHaveBeenCalledWith(
      expect.objectContaining({ audio: expect.objectContaining({ restrictOwnAudio: true }) }),
    );
    expect(addTrack).not.toHaveBeenCalled();
  });

  it('does not touch the source when System Audio is off', async () => {
    useVoiceStore.setState({ screenShareConfig: { ...useVoiceStore.getState().screenShareConfig, shareAudio: false } });
    const { stream } = fakeStream();
    const getDisplayMedia = stubDisplayMedia(async () => stream);
    await stageScreenCapture();
    expect(source.acquireAppExcludedSystemAudio).not.toHaveBeenCalled();
    expect(getDisplayMedia).toHaveBeenCalledWith(expect.objectContaining({ audio: false }));
  });
});

describe('stageScreenCapture when Windows refuses audio without B:SPACE', () => {
  afterEach(() => {
    delete (window as unknown as { backspace?: unknown }).backspace;
  });

  function withDesktop(report: () => Promise<boolean>) {
    const reportSystemAudioExclusionFailed = vi.fn(report);
    (window as unknown as { backspace: unknown }).backspace = { platform: 'win32', reportSystemAudioExclusionFailed };
    return reportSystemAudioExclusionFailed;
  }

  it('reports the failure and captures once more, with no second pick', async () => {
    const report = withDesktop(async () => true);
    const { stream } = fakeStream();
    const getDisplayMedia = stubDisplayMedia(async () => stream);
    getDisplayMedia.mockRejectedValueOnce(new DOMException('Could not start audio source', 'NotReadableError'));

    expect(await stageScreenCapture()).toBe(stream);
    expect(report).toHaveBeenCalledTimes(1);
    expect(getDisplayMedia).toHaveBeenCalledTimes(2);
  });

  it('retries when the audio track is dead on arrival, stopping the first capture', async () => {
    const report = withDesktop(async () => true);
    const first = fakeStream();
    const dead = { kind: 'audio', readyState: 'ended', stop: vi.fn() };
    first.added.push(dead);
    const second = fakeStream();
    const getDisplayMedia = stubDisplayMedia(async () => second.stream);
    getDisplayMedia.mockResolvedValueOnce(first.stream);

    expect(await stageScreenCapture()).toBe(second.stream);
    expect(report).toHaveBeenCalledTimes(1);
    expect(first.video.stop).toHaveBeenCalled();
  });

  it('does not retry a cancelled pick, nor when the app has nothing to fall back to', async () => {
    const report = withDesktop(async () => false);
    const getDisplayMedia = stubDisplayMedia(async () => {
      throw new DOMException('Could not start audio source', 'NotReadableError');
    });
    await expect(stageScreenCapture()).rejects.toThrow('Could not start audio source');
    expect(getDisplayMedia).toHaveBeenCalledTimes(1);

    report.mockClear();
    // A browser's DOMException is an Error; jsdom's is not, so the cancellation is built as one.
    const cancelled = Object.assign(new Error('Permission denied'), { name: 'NotAllowedError' });
    getDisplayMedia.mockRejectedValueOnce(cancelled);
    await expect(stageScreenCapture()).rejects.toThrow('Permission denied');
    expect(report).not.toHaveBeenCalled();
  });
});
