import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useUIStore } from '../stores/uiStore';
import { useVoiceStore } from '../stores/voiceStore';
import { canAddScreenShareAudioLater, stageScreenCapture } from './screenShare';

const native = vi.hoisted(() => ({
  canCaptureNatively: vi.fn(() => true),
  acquireNativeScreenCapture: vi.fn(),
  isNativeScreenCapture: vi.fn(() => true),
  reconfigureNativeScreenCapture: vi.fn(),
}));
const sound = vi.hoisted(() => ({
  canCaptureSystemAudioNatively: vi.fn(() => true),
  acquireNativeSystemAudio: vi.fn(),
}));
vi.mock('../platform/nativeCapture/nativeScreenCapture', () => native);
vi.mock('../platform/nativeCapture/nativeSystemAudio', () => sound);
vi.mock('./hwOverdrive', () => ({ activate: vi.fn(), deactivate: vi.fn() }));
vi.mock('../audio/AudioManager', () => ({
  AudioManager: { getInstance: () => ({ setInputVolume: vi.fn() }) },
}));
vi.mock('./livekitInternals', () => ({ getPublisherPC: vi.fn(), getMediaStreamTrack: vi.fn() }));

/**
 * In the native macOS shell the system's sound is a capture of its own,
 * apart from the picture's: it joins the staged stream when System Audio is
 * on, and can be added to a running share at any time.
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
  return { stream: stream as unknown as MediaStream, added };
}

function shareAudio(on: boolean): void {
  useVoiceStore.setState({ screenShareConfig: { ...useVoiceStore.getState().screenShareConfig, shareAudio: on } });
}

beforeEach(() => {
  native.canCaptureNatively.mockReturnValue(true);
  native.acquireNativeScreenCapture.mockReset();
  sound.canCaptureSystemAudioNatively.mockReturnValue(true);
  sound.acquireNativeSystemAudio.mockReset();
  shareAudio(true);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('stageScreenCapture in the native macOS shell', () => {
  it('adds the system\'s sound to the capture of the picked source', async () => {
    const { stream, added } = fakeStream();
    const track = { kind: 'audio', readyState: 'live', stop: vi.fn() } as unknown as MediaStreamTrack;
    native.acquireNativeScreenCapture.mockResolvedValue(stream);
    sound.acquireNativeSystemAudio.mockResolvedValue(track);

    expect(await stageScreenCapture('screen:1:0')).toBe(stream);
    expect(native.acquireNativeScreenCapture).toHaveBeenCalledWith('screen:1:0', expect.objectContaining({ frameRate: expect.any(Number) }));
    expect(added).toEqual([track]);
  });

  it('goes on with the picture alone, and says so, when the sound does not start', async () => {
    const { stream, added } = fakeStream();
    native.acquireNativeScreenCapture.mockResolvedValue(stream);
    sound.acquireNativeSystemAudio.mockRejectedValue(new Error('Native system audio did not start: no-permission'));
    const addToast = vi.spyOn(useUIStore.getState(), 'addToast').mockImplementation(() => undefined);
    vi.spyOn(console, 'warn').mockImplementation(() => undefined);

    expect(await stageScreenCapture('screen:1:0')).toBe(stream);
    expect(added).toEqual([]);
    expect(addToast).toHaveBeenCalledTimes(1);
    expect(addToast).toHaveBeenCalledWith(expect.any(String), 'warning', 8000);
  });

  it('takes no sound when System Audio is off', async () => {
    const { stream, added } = fakeStream();
    native.acquireNativeScreenCapture.mockResolvedValue(stream);
    shareAudio(false);

    await stageScreenCapture('screen:1:0');
    expect(sound.acquireNativeSystemAudio).not.toHaveBeenCalled();
    expect(added).toEqual([]);
  });

  it('takes no sound from a shell that captures the picture only', async () => {
    const { stream, added } = fakeStream();
    native.acquireNativeScreenCapture.mockResolvedValue(stream);
    sound.canCaptureSystemAudioNatively.mockReturnValue(false);

    await stageScreenCapture('screen:1:0');
    expect(sound.acquireNativeSystemAudio).not.toHaveBeenCalled();
    expect(added).toEqual([]);
  });
});

describe('canAddScreenShareAudioLater in the native macOS shell', () => {
  it('is true for a source the app listed, because the sound is a capture of its own', () => {
    expect(canAddScreenShareAudioLater('screen:1:0', 'app')).toBe(true);
  });

  it('is false in a shell that captures the picture only', () => {
    sound.canCaptureSystemAudioNatively.mockReturnValue(false);
    expect(canAddScreenShareAudioLater('screen:1:0', 'app')).toBe(false);
  });

  it('is false without a source the app listed', () => {
    expect(canAddScreenShareAudioLater(null, 'app')).toBe(false);
    expect(canAddScreenShareAudioLater('screen:1:0', 'system')).toBe(false);
    expect(canAddScreenShareAudioLater('screen:1:0', null)).toBe(false);
  });
});
