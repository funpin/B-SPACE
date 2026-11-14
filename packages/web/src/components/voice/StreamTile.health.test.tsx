import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import { VoiceGrid } from './VoiceGrid';
import type { ParticipantInfo } from '../../hooks/useLiveKit';
import { useVoiceStore } from '../../stores/voiceStore';

vi.mock('../../audio/AudioManager', () => ({
  AudioManager: { getInstance: () => ({ playSound: vi.fn() }) },
}));

vi.mock('../../hooks/useLiveKit', async (importOriginal) => {
  const actual: object = await importOriginal();
  return {
    ...actual,
    getActiveRoom: () => null,
    setCameraSubscription: vi.fn(),
    setStreamSubscription: vi.fn(),
  };
});

function participant(identity: string, isLocal: boolean) {
  return {
    identity,
    userId: identity,
    username: identity,
    homeUserId: null,
    isMuted: false,
    isDeafened: false,
    isCameraOn: false,
    isScreenSharing: false,
    isLocal,
    audioTrack: null,
    videoTrack: null,
    screenTrack: null,
    screenAudioTrack: null,
    lkVideoTrack: null,
    lkScreenTrack: null,
    cachedUser: null,
  } as unknown as ParticipantInfo;
}

// The health warning is debounced from live stats; here it is simply on.
vi.mock('../../hooks/useStreamHealthWarning', async (importOriginal) => {
  const actual: object = await importOriginal();
  return { ...actual, useStreamHealthWarning: () => 'viewerNetwork' };
});

const liveTrack = { readyState: 'live', addEventListener: () => {}, removeEventListener: () => {}, getSettings: () => ({}) };

function sharing(identity: string, media: { screen?: boolean; camera?: boolean }, isLocal = false) {
  return {
    ...participant(identity, isLocal),
    isScreenSharing: media.screen ?? false,
    screenTrack: media.screen ? liveTrack : null,
    isCameraOn: media.camera ?? false,
    videoTrack: media.camera ? liveTrack : null,
  };
}

beforeEach(() => {
  useVoiceStore.setState({
    focusedParticipantId: null,
    currentVoiceChannelId: 'voice-1',
    watchingStreams: new Set(['bob']),
    hiddenTileUserIds: new Set(),
    swappedTileUserIds: new Set(),
    splitCameraUserIds: new Set(),
    tileOrder: [],
  });
});

describe('stream connection warning', () => {
  it('marks a grid tile with an icon named by the warning, never a cut-off sentence', () => {
    render(<VoiceGrid participants={[participant('ada', true), sharing('bob', { screen: true })]} />);
    const mark = screen.getByTestId('stream-health-mark');
    expect(mark).toHaveAccessibleName(/connection is unstable/i);
    expect(mark.textContent).toBe('');
  });

  it('spells the warning out on the focused tile', () => {
    useVoiceStore.setState({ focusedParticipantId: 'bob:stream' });
    render(<VoiceGrid participants={[participant('ada', true), sharing('bob', { screen: true })]} />);
    expect(screen.queryByTestId('stream-health-mark')).toBeNull();
    expect(screen.getByTestId('stream-status-row')).toHaveTextContent(/connection is unstable/i);
  });
});
