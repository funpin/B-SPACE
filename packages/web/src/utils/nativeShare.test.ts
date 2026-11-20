import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ConnectionState, type Room } from 'livekit-client';
import { useVoiceStore, type ScreenShareConfig } from '../stores/voiceStore';
import { useUIStore } from '../stores/uiStore';
import type { ScreenShareBuildResult } from './screenShare';
import {
  applyNativeShareConfig, canShareNativelyInThisCall, endNativeShareWithRoom, isNativeShareLive, nativeShareChange,
  nativeShareFloor, nativeShareQuality, publishNativeShare, resetNativeShareForTests, resumeNativeShareAfterReconnect,
  stopNativeShare, useNativeShareStore, type NativeShareQuality,
} from './nativeShare';

/**
 * A share the native macOS shell publishes itself: the page asks the call's
 * server for a stream token, tells the shell what to share, keeps the call's
 * state and tells viewers what becomes of the share.
 */

const mocks = vi.hoisted(() => ({
  streamToken: vi.fn(),
  dmStreamToken: vi.fn(),
  broadcast: vi.fn(),
}));
vi.mock('../stores/spaceStore', () => ({
  getApiForOrigin: () => ({ livekit: { streamToken: mocks.streamToken, dmStreamToken: mocks.dmStreamToken } }),
}));
vi.mock('./voice', () => ({ broadcastVoiceStatus: mocks.broadcast }));
vi.mock('../audio/AudioManager', () => ({ AudioManager: { getInstance: () => ({ playSound: vi.fn() }) } }));

type Listener = (event: NativeScreenShareEvent) => void;

function shell() {
  let listener: Listener | null = null;
  const api = {
    platform: 'darwin',
    startNativeScreenShare: vi.fn<(options: NativeScreenShareOptions) => Promise<NativeScreenShareResult>>(
      async () => ({ ok: true, width: 2560, height: 1440, frameRate: 60 }),
    ),
    updateNativeScreenShare: vi.fn<(options: NativeScreenShareUpdate) => Promise<NativeScreenShareResult>>(
      async () => ({ ok: true, width: 2560, height: 1440, frameRate: 60 }),
    ),
    stopNativeScreenShare: vi.fn(),
    onNativeScreenShareEvent: vi.fn((cb: Listener) => { listener = cb; return () => { listener = null; }; }),
    startNativeSharePreview: vi.fn(async () => ({ ok: true as const, width: 1280, height: 800 })),
    setNativeSharePreviewFrame: vi.fn(),
    stopNativeSharePreview: vi.fn(),
  };
  (window as unknown as { backspace: unknown }).backspace = api;
  return { api, say: (event: NativeScreenShareEvent) => listener?.(event), listening: () => listener !== null };
}

function room(state: ConnectionState = ConnectionState.Connected) {
  const publishData = vi.fn(async () => undefined);
  return { room: { state, localParticipant: { publishData } } as unknown as Room, publishData };
}

function signals(publishData: ReturnType<typeof vi.fn>): string[] {
  return publishData.mock.calls.map(([data]) => (JSON.parse(new TextDecoder().decode(data as Uint8Array)) as { type: string }).type);
}

const config: ScreenShareConfig = {
  height: 1440, fps: 60, mode: 'gaming', customBitrateKbps: null, shareAudio: true, codec: 'auto',
};

function build(maxBitrate = 9_000_000, width = 2560, height = 1440, frameRate = 60): ScreenShareBuildResult {
  return {
    capture: { width, height, frameRate },
    publish: { videoEncoding: { maxBitrate, maxFramerate: frameRate } },
  } as unknown as ScreenShareBuildResult;
}

const staged = { kind: 'native-share', sourceId: 'screen:1:0', width: 1280, height: 800 } as const;
const inCall = { origin: '', channelId: 'c1', isDm: false, url: 'wss://calls.example/livekit' };

beforeEach(() => {
  vi.clearAllMocks();
  resetNativeShareForTests();
  mocks.streamToken.mockResolvedValue({ token: 'stream-token', url: 'wss://calls.example/livekit' });
  mocks.dmStreamToken.mockResolvedValue({ token: 'dm-stream-token', url: 'wss://calls.example/livekit' });
  useVoiceStore.setState({ ...useVoiceStore.getInitialState(), streamTokenSource: inCall });
  useUIStore.setState({ toasts: [] });
});
afterEach(() => {
  delete (window as unknown as { backspace?: unknown }).backspace;
});

describe('what the shell is told for a share', () => {
  it('is the user\'s settings: the size, the rate, the ceiling, a floor under it, the sound', () => {
    expect(nativeShareQuality('window:7:0', config, build())).toEqual({
      sourceId: 'window:7:0', maxWidth: 2560, maxHeight: 1440, frameRate: 60,
      codec: 'h265', maxBitrate: 9_000_000, minBitrate: 3_000_000, audio: true,
    });
  });

  it('leaves the size out for the source\'s own', () => {
    const quality = nativeShareQuality('screen:1:0', { ...config, height: 'native' }, build(9_000_000, 0, 0));
    expect(quality).not.toHaveProperty('maxWidth');
    expect(quality).not.toHaveProperty('maxHeight');
  });

  it('is H.264 only when the user asked for it', () => {
    expect(nativeShareQuality('screen:1:0', { ...config, codec: 'h264' }, build()).codec).toBe('h264');
    expect(nativeShareQuality('screen:1:0', { ...config, codec: 'auto' }, build()).codec).toBe('h265');
  });

  it('keeps the floor a third of the ceiling and never above 3 Mbit/s', () => {
    expect(nativeShareFloor(1_500_000)).toBe(500_000);
    expect(nativeShareFloor(6_000_000)).toBe(2_000_000);
    expect(nativeShareFloor(30_000_000)).toBe(3_000_000);
  });
});

describe('a change to a running share', () => {
  const running: NativeShareQuality = {
    sourceId: 'screen:1:0', maxWidth: 2560, maxHeight: 1440, frameRate: 60,
    codec: 'h265', maxBitrate: 9_000_000, minBitrate: 3_000_000, audio: true,
  };

  it('says only what differs', () => {
    expect(nativeShareChange(running, { ...running })).toBeNull();
    expect(nativeShareChange(running, { ...running, maxBitrate: 4_000_000, minBitrate: 1_333_333 }))
      .toEqual({ maxBitrate: 4_000_000, minBitrate: 1_333_333 });
    expect(nativeShareChange(running, { ...running, audio: false })).toEqual({ audio: false });
    expect(nativeShareChange(running, { ...running, frameRate: 30 })).toEqual({ frameRate: 30 });
    expect(nativeShareChange(running, { ...running, sourceId: 'window:9:0' })).toEqual({ sourceId: 'window:9:0' });
  });

  it('asks for the largest size when the source\'s own is wanted', () => {
    const native: NativeShareQuality = {
      sourceId: running.sourceId, frameRate: running.frameRate, codec: running.codec,
      maxBitrate: running.maxBitrate, minBitrate: running.minBitrate, audio: running.audio,
    };
    expect(nativeShareChange(running, native)).toEqual({ maxWidth: 8192, maxHeight: 8192 });
    expect(nativeShareChange(native, running)).toEqual({ maxWidth: 2560, maxHeight: 1440 });
  });

  it('is a restart for another codec', () => {
    expect(nativeShareChange(running, { ...running, codec: 'h264' })).toBe('restart');
  });
});

describe('whether a share goes through the shell', () => {
  it('does when the shell publishes shares and the call\'s server issues stream tokens', () => {
    shell();
    expect(canShareNativelyInThisCall()).toBe(true);
  });

  it('does not in a call whose server issues none, or outside the native shell', () => {
    shell();
    useVoiceStore.setState({ streamTokenSource: null });
    expect(canShareNativelyInThisCall()).toBe(false);
    useVoiceStore.setState({ streamTokenSource: inCall });
    delete (window as unknown as { backspace?: unknown }).backspace;
    expect(canShareNativelyInThisCall()).toBe(false);
  });
});

describe('going live through the shell', () => {
  it('asks the call\'s server for a stream token and hands it to the shell with the quality', async () => {
    const { api } = shell();
    const { room: call } = room();

    expect(await publishNativeShare(call, staged, config, build())).toBe(true);

    expect(mocks.streamToken).toHaveBeenCalledWith('c1');
    expect(api.startNativeScreenShare).toHaveBeenCalledWith({
      url: 'wss://calls.example/livekit', token: 'stream-token', sourceId: 'screen:1:0',
      maxWidth: 2560, maxHeight: 1440, frameRate: 60, codec: 'h265',
      maxBitrate: 9_000_000, minBitrate: 3_000_000, audio: true,
    });
    // The preview's capture is let go before the share takes its own.
    expect(api.stopNativeSharePreview).toHaveBeenCalled();
    expect(isNativeShareLive()).toBe(true);
    expect(useVoiceStore.getState()).toMatchObject({ isScreenSharing: true, screenShareAudio: 'published' });
    // What the connection panel names as the codec that was asked for.
    expect(useNativeShareStore.getState().codec).toBe('h265');
  });

  it('asks for a direct call\'s token in a direct call', async () => {
    shell();
    useVoiceStore.setState({ streamTokenSource: { ...inCall, channelId: 'd1', isDm: true } });
    await publishNativeShare(room().room, staged, config, build());
    expect(mocks.dmStreamToken).toHaveBeenCalledWith('d1');
    expect(mocks.streamToken).not.toHaveBeenCalled();
  });

  it('does not start when the server refuses the token, and says why', async () => {
    const { api } = shell();
    mocks.streamToken.mockRejectedValue(new Error('Missing STREAM permission'));

    expect(await publishNativeShare(room().room, staged, config, build())).toBe(false);

    expect(api.startNativeScreenShare).not.toHaveBeenCalled();
    expect(isNativeShareLive()).toBe(false);
    expect(useVoiceStore.getState().isScreenSharing).toBe(false);
    expect(useUIStore.getState().toasts).toHaveLength(1);
  });

  it('does not start when the shell refuses', async () => {
    const { api } = shell();
    api.startNativeScreenShare.mockResolvedValue({ ok: false, reason: 'connect-failed' });
    expect(await publishNativeShare(room().room, staged, config, build())).toBe(false);
    expect(isNativeShareLive()).toBe(false);
    expect(useVoiceStore.getState().isScreenSharing).toBe(false);
  });

  it('says a share without the sound has none, and that it can be added', async () => {
    shell();
    await publishNativeShare(room().room, staged, { ...config, shareAudio: false }, build());
    expect(useVoiceStore.getState().screenShareAudio).toBe('acquirable');
  });
});

describe('a share the shell publishes', () => {
  async function live() {
    const bridge = shell();
    const call = room();
    await publishNativeShare(call.room, staged, config, build());
    return { ...bridge, ...call };
  }

  it('is told what the user changed, and nothing when nothing changed', async () => {
    const { api } = await live();

    await applyNativeShareConfig(config, build());
    expect(api.updateNativeScreenShare).not.toHaveBeenCalled();

    await applyNativeShareConfig(config, build(4_500_000));
    expect(api.updateNativeScreenShare).toHaveBeenCalledWith({ maxBitrate: 4_500_000, minBitrate: 1_500_000 });

    await applyNativeShareConfig({ ...config, shareAudio: false }, build(4_500_000));
    expect(api.updateNativeScreenShare).toHaveBeenLastCalledWith({ audio: false });
    expect(useVoiceStore.getState().screenShareAudio).toBe('acquirable');
  });

  it('keeps what it had when the shell refuses a change, and says so for the sound', async () => {
    const { api } = await live();
    await applyNativeShareConfig({ ...config, shareAudio: false }, build());
    api.updateNativeScreenShare.mockResolvedValue({ ok: false, reason: 'failed' });

    await applyNativeShareConfig(config, build());

    expect(useVoiceStore.getState().screenShareAudio).toBe('acquirable');
    expect(useUIStore.getState().toasts).toHaveLength(1);
    // Asked again the next time: the refused change was not taken as made.
    api.updateNativeScreenShare.mockResolvedValue({ ok: true, width: 2560, height: 1440, frameRate: 60 });
    await applyNativeShareConfig(config, build());
    expect(api.updateNativeScreenShare).toHaveBeenLastCalledWith({ audio: true });
    expect(useVoiceStore.getState().screenShareAudio).toBe('published');
  });

  it('is started again for another codec, with viewers told it is the same share', async () => {
    const { api, publishData } = await live();
    mocks.streamToken.mockResolvedValue({ token: 'second-token', url: 'wss://calls.example/livekit' });

    await applyNativeShareConfig({ ...config, codec: 'h264' }, build());

    expect(signals(publishData)).toEqual(['stream_republish']);
    expect(api.stopNativeScreenShare).toHaveBeenCalledTimes(1);
    expect(api.startNativeScreenShare).toHaveBeenLastCalledWith(expect.objectContaining({ token: 'second-token', codec: 'h264' }));
    expect(isNativeShareLive()).toBe(true);
    expect(useVoiceStore.getState().isScreenSharing).toBe(true);
    expect(useNativeShareStore.getState().codec).toBe('h264');
  });

  it('stops when the user stops it: viewers are told first, the call\'s state follows', async () => {
    const { api, publishData, listening } = await live();

    stopNativeShare();

    expect(signals(publishData)).toEqual(['stream_stop']);
    expect(api.stopNativeScreenShare).toHaveBeenCalledTimes(1);
    expect(isNativeShareLive()).toBe(false);
    expect(listening()).toBe(false);
    expect(useVoiceStore.getState()).toMatchObject({ isScreenSharing: false, screenShareAudio: null });
    expect(useNativeShareStore.getState().codec).toBeNull();
    expect(mocks.broadcast).toHaveBeenCalled();
  });

  it('ends when the shell says it ended, with the reason shown', async () => {
    const { say, publishData, api } = await live();

    say({ type: 'ended', reason: 'source-ended' });

    expect(isNativeShareLive()).toBe(false);
    expect(useVoiceStore.getState().isScreenSharing).toBe(false);
    expect(signals(publishData)).toEqual(['stream_stop']);
    expect(api.stopNativeScreenShare).not.toHaveBeenCalled();
    expect(useUIStore.getState().toasts).toHaveLength(1);
    expect(mocks.broadcast).toHaveBeenCalled();
  });

  it('goes on without its sound when the sound ends by itself', async () => {
    const { say, api } = await live();

    say({ type: 'audio-ended' });

    expect(isNativeShareLive()).toBe(true);
    expect(useVoiceStore.getState()).toMatchObject({ isScreenSharing: true, screenShareAudio: 'acquirable' });
    // The switch is still on: the next change asks for the sound again.
    await applyNativeShareConfig(config, build());
    expect(api.updateNativeScreenShare).toHaveBeenLastCalledWith({ audio: true });
  });

  it('says once that the system does not draw the shared window', async () => {
    const { say } = await live();
    const told = () => useUIStore.getState().toasts.length;

    say({ type: 'source-hidden', hidden: false });
    expect(told()).toBe(0);
    say({ type: 'source-hidden', hidden: true });
    expect(told()).toBe(1);
    // The user goes back and forth between that window and this app.
    say({ type: 'source-hidden', hidden: false });
    say({ type: 'source-hidden', hidden: true });
    expect(told()).toBe(1);
    expect(isNativeShareLive()).toBe(true);
  });

  it('says it at the start of a share of a window that is not drawn', async () => {
    const { api, say } = shell();
    api.startNativeScreenShare.mockResolvedValueOnce({ ok: true, width: 1152, height: 720, frameRate: 30, hidden: true });

    expect(await publishNativeShare(room().room, staged, config, build())).toBe(true);

    expect(useUIStore.getState().toasts).toHaveLength(1);
    say({ type: 'source-hidden', hidden: true });
    expect(useUIStore.getState().toasts).toHaveLength(1);
  });

  it('keeps what the shell says it sends, for the connection panel', async () => {
    const { say } = await live();
    const stats = {
      type: 'stats' as const, bitrate: 4_200_000, frameRate: 60, width: 2560, height: 1440,
      codec: 'video/H265', encoder: 'VideoToolbox', hardware: true,
    };
    say(stats);
    expect(useNativeShareStore.getState().stats).toEqual(stats);
    stopNativeShare();
    expect(useNativeShareStore.getState().stats).toBeNull();
  });

  it('tells viewers it is back when its own connection was restored', async () => {
    const { say, publishData } = await live();
    say({ type: 'reconnecting' });
    expect(useNativeShareStore.getState().reconnecting).toBe(true);
    say({ type: 'reconnected' });
    expect(useNativeShareStore.getState().reconnecting).toBe(false);
    expect(signals(publishData)).toEqual(['stream_resume']);
  });

  it('tells viewers it is back when the page\'s own room came back', async () => {
    const { room: call, publishData } = await live();
    resumeNativeShareAfterReconnect(call);
    expect(signals(publishData)).toEqual(['stream_resume']);
    resumeNativeShareAfterReconnect(room().room);
    expect(signals(publishData)).toEqual(['stream_resume']);
  });

  it('ends with the call it was in, and only with that one', async () => {
    const { room: call, api, publishData } = await live();

    endNativeShareWithRoom(room().room);
    expect(isNativeShareLive()).toBe(true);

    endNativeShareWithRoom(call);
    expect(isNativeShareLive()).toBe(false);
    expect(api.stopNativeScreenShare).toHaveBeenCalledTimes(1);
    expect(useVoiceStore.getState().isScreenSharing).toBe(false);
    // Nobody is left in that room to tell.
    expect(signals(publishData)).toEqual([]);
  });

  it('is deaf to a share that is over', async () => {
    const { say } = await live();
    stopNativeShare();
    say({ type: 'ended', reason: 'disconnected' });
    expect(useUIStore.getState().toasts).toHaveLength(0);
  });
});
