import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../audio/AudioManager', () => ({
  AudioManager: { getInstance: () => ({}) },
}));

import { useSpaceStore } from './spaceStore';
import { useVoiceStore } from './voiceStore';
import { applySpaceVoiceState } from '../utils/voiceStateSync';

beforeEach(() => {
  useVoiceStore.setState(useVoiceStore.getInitialState());
});

describe('members connecting to a voice channel', () => {
  it('records an attempt, its failure, and its end', () => {
    const { setVoiceConnecting } = useVoiceStore.getState();

    setVoiceConnecting('voice-1', 'ann', 'connecting');
    expect(useVoiceStore.getState().voiceConnecting.get('voice-1')).toEqual([{ userId: 'ann', state: 'connecting' }]);

    setVoiceConnecting('voice-1', 'ann', 'failed', 'server_unreachable');
    expect(useVoiceStore.getState().voiceConnecting.get('voice-1')).toEqual([
      { userId: 'ann', state: 'failed', reason: 'server_unreachable' },
    ]);

    setVoiceConnecting('voice-1', 'ann', 'idle');
    expect(useVoiceStore.getState().voiceConnecting.has('voice-1')).toBe(false);
  });

  it('gives a failure without a reason the general one', () => {
    useVoiceStore.getState().setVoiceConnecting('voice-1', 'ann', 'failed');

    expect(useVoiceStore.getState().voiceConnecting.get('voice-1')).toEqual([
      { userId: 'ann', state: 'failed', reason: 'connect_failed' },
    ]);
  });

  it('keeps one attempt per member and leaves the others alone', () => {
    const { setVoiceConnecting } = useVoiceStore.getState();
    setVoiceConnecting('voice-1', 'ann', 'connecting');
    setVoiceConnecting('voice-1', 'bob', 'connecting');

    setVoiceConnecting('voice-2', 'ann', 'connecting');

    expect(useVoiceStore.getState().voiceConnecting.get('voice-1')).toEqual([{ userId: 'bob', state: 'connecting' }]);
    expect(useVoiceStore.getState().voiceConnecting.get('voice-2')).toEqual([{ userId: 'ann', state: 'connecting' }]);
  });

  it('is replaced per channel by a snapshot, and emptied by an empty one', () => {
    const { setVoiceConnecting, setVoiceConnectingForChannel } = useVoiceStore.getState();
    setVoiceConnecting('voice-1', 'ann', 'connecting');

    setVoiceConnectingForChannel('voice-1', [{ userId: 'bob', state: 'failed', reason: 'not_allowed' }]);
    expect(useVoiceStore.getState().voiceConnecting.get('voice-1')).toEqual([
      { userId: 'bob', state: 'failed', reason: 'not_allowed' },
    ]);

    setVoiceConnectingForChannel('voice-1', []);
    expect(useVoiceStore.getState().voiceConnecting.has('voice-1')).toBe(false);
  });

  it('is cleared with the voice state of the instance it came from, and only that one', () => {
    useSpaceStore.setState({
      channelOriginMap: new Map([['voice-remote', 'https://remote.example']]),
    } as never);
    const { setVoiceConnecting, clearVoiceUsersForOrigin } = useVoiceStore.getState();
    setVoiceConnecting('voice-home', 'ann', 'connecting');
    setVoiceConnecting('voice-remote', 'bob', 'connecting');

    clearVoiceUsersForOrigin('https://remote.example');

    expect([...useVoiceStore.getState().voiceConnecting.keys()]).toEqual(['voice-home']);
  });
});

describe('connection flags of a member in voice', () => {
  const quiet = [false, false, false, false] as const;

  it('are kept only when set', () => {
    const { setVoiceUserStatus } = useVoiceStore.getState();

    setVoiceUserStatus('ann', ...quiet, { isUnresponsive: true, isReconnecting: false });
    expect(useVoiceStore.getState().voiceUserStates.get('ann')).toEqual({
      isMuted: false, isDeafened: false, isCameraOn: false, isScreenSharing: false, isUnresponsive: true,
    });

    setVoiceUserStatus('ann', ...quiet);
    expect(useVoiceStore.getState().voiceUserStates.get('ann')).toEqual({
      isMuted: false, isDeafened: false, isCameraOn: false, isScreenSharing: false,
    });
  });

  it('arrive with a snapshot of a space, together with the attempts', () => {
    applySpaceVoiceState({
      spaceId: 'space-1',
      voiceStates: { 'voice-1': ['ann'] },
      voiceChannelElapsedSeconds: {},
      voiceUserStates: {
        ann: { isMuted: true, isDeafened: false, isCameraOn: false, isScreenSharing: false, isMicUnavailable: true },
      },
      voiceConnecting: { 'voice-1': [{ userId: 'bob', state: 'connecting' }] },
      spaceVoiceStates: {},
    });

    const state = useVoiceStore.getState();
    expect(state.voiceUserStates.get('ann')).toMatchObject({ isMuted: true, isMicUnavailable: true });
    expect(state.voiceConnecting.get('voice-1')).toEqual([{ userId: 'bob', state: 'connecting' }]);
  });

  it('read as "no trouble" in a snapshot from an instance that does not send them', () => {
    applySpaceVoiceState({
      spaceId: 'space-1',
      voiceStates: { 'voice-1': ['ann'] },
      voiceChannelElapsedSeconds: {},
      voiceUserStates: { ann: { isMuted: false, isDeafened: false, isCameraOn: false, isScreenSharing: false } },
      spaceVoiceStates: {},
    });

    expect(useVoiceStore.getState().voiceUserStates.get('ann')).toEqual({
      isMuted: false, isDeafened: false, isCameraOn: false, isScreenSharing: false,
    });
    expect(useVoiceStore.getState().voiceConnecting.size).toBe(0);
  });
});
