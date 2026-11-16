import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { VoiceChannel } from './VoiceChannel';
import { useAuthStore } from '../../stores/authStore';
import { useSpaceStore } from '../../stores/spaceStore';
import { useVoiceStore } from '../../stores/voiceStore';
import { useContextMenuStore } from '../../stores/contextMenuStore';
import type { MemberWithUser } from '@backspace/shared';

vi.mock('../../audio/AudioManager', () => ({
  AudioManager: { getInstance: () => ({}) },
}));

function participant(userId: string, username: string, isLocal: boolean) {
  return {
    identity: `${userId}:${username}`,
    userId,
    username,
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
  } as any;
}

beforeEach(() => {
  useAuthStore.setState({ user: { id: '1', username: 'ada' }, myRowIds: new Map() } as any);
  useSpaceStore.setState({
    members: [
      { userId: '1', user: { id: '1', username: 'ada', displayName: 'Ada', avatar: null }, roles: [] },
      { userId: '2', user: { id: '2', username: 'bob', displayName: 'Bob', avatar: null }, roles: [] },
    ],
    channelToSpaceMap: new Map([['voice-1', 'space-1']]),
    channelOriginMap: new Map(),
  } as any);
  useVoiceStore.setState({
    currentVoiceChannelId: 'voice-1',
    isLiveKitConnected: true,
    voiceConnectionStatus: 'connected',
    participants: [participant('1', 'ada', true), participant('2', 'bob', false)],
    voiceUsers: new Map([['voice-1', ['1', '2']]]),
    voiceChannelElapsedSeconds: new Map(),
    voiceUserStates: new Map(),
    connectionQuality: 'good',
    connectionQualities: new Map(),
    spaceMutedUserIds: new Set(),
    spaceDeafenedUserIds: new Set(),
    permissionMutedUserIds: new Set(),
    participantMutes: new Map(),
    unwatchedCameras: new Set(),
    speakingUserIds: new Set(),
  });
});

afterEach(() => {
  vi.useRealTimers();
});

function renderChannel(canManage = false, onSettingsClick = () => {}) {
  return render(
    <VoiceChannel
      channelId="voice-1"
      channelName="Voice"
      onClick={() => {}}
      canManage={canManage}
      onSettingsClick={onSettingsClick}
    />,
  );
}

describe('VoiceChannel connection diagnostics', () => {
  it('attributes a poor remote connection to that participant', () => {
    useVoiceStore.setState({
      connectionQualities: new Map([['2:bob', 'poor']]),
    });

    renderChannel();

    expect(screen.getByLabelText('Bob has an unstable connection')).toBeInTheDocument();
  });

  it('shows a voice-server reconnect warning on the local participant', () => {
    useVoiceStore.setState({ voiceConnectionStatus: 'reconnecting' });

    renderChannel();

    expect(screen.getByLabelText('Connection to the voice server was interrupted — reconnecting…')).toBeInTheDocument();
  });

  it('shows what the instance relays about another member, one mark per row', () => {
    useVoiceStore.setState({
      // Bob's network is also weak: the more serious trouble wins the row.
      connectionQualities: new Map([['2:bob', 'poor']]),
      voiceUserStates: new Map([['2', {
        isMuted: false, isDeafened: false, isCameraOn: false, isScreenSharing: false, isUnresponsive: true,
      }]]),
    });

    const { container } = renderChannel();

    expect(screen.getByLabelText('Bob is not responding. Their app may have closed, or their network dropped.'))
      .toHaveAttribute('data-connection-mark', 'unresponsive');
    expect(container.querySelectorAll('[data-connection-mark]')).toHaveLength(1);
  });

  it('marks a member without microphone access, and one who is reconnecting', () => {
    useVoiceStore.setState({
      voiceUserStates: new Map([['2', {
        isMuted: false, isDeafened: false, isCameraOn: false, isScreenSharing: false, isMicUnavailable: true,
      }]]),
    });
    const { unmount } = renderChannel();
    expect(screen.getByLabelText('Bob has no microphone access and cannot be heard'))
      .toHaveAttribute('data-connection-mark', 'mic-unavailable');
    unmount();

    useVoiceStore.setState({
      voiceUserStates: new Map([['2', {
        isMuted: false, isDeafened: false, isCameraOn: false, isScreenSharing: false, isReconnecting: true,
      }]]),
    });
    renderChannel();
    expect(screen.getByLabelText('Bob is reconnecting…')).toHaveAttribute('data-connection-mark', 'reconnecting');
  });

  it('reads the viewer\'s own microphone trouble from this client', () => {
    useVoiceStore.setState({ micPermissionDenied: true });

    renderChannel();

    expect(screen.getByLabelText('No microphone access — nobody can hear you')).toBeInTheDocument();
  });
});

describe('VoiceChannel members who are not in yet', () => {
  it('lists a member who is connecting after the ones in the channel', () => {
    useVoiceStore.setState({
      participants: [participant('1', 'ada', true)],
      voiceUsers: new Map([['voice-1', ['1']]]),
      voiceConnecting: new Map([['voice-1', [{ userId: '2', state: 'connecting' as const }]]]),
    });

    renderChannel();

    expect(screen.getByLabelText('Bob is connecting…')).toHaveAttribute('data-connection-mark', 'connecting');
    expect(screen.getByText('Bob')).toHaveClass('text-txt-tertiary');
    expect(screen.getByText('Ada')).toHaveClass('text-txt-secondary');
  });

  it('says why a member could not connect', () => {
    useVoiceStore.setState({
      participants: [participant('1', 'ada', true)],
      voiceUsers: new Map([['voice-1', ['1']]]),
      voiceConnecting: new Map([['voice-1', [
        { userId: '2', state: 'failed' as const, reason: 'media_unreachable' as const },
      ]]]),
    });

    renderChannel();

    expect(screen.getByLabelText(
      'Bob could not connect. The voice connection could not be established. Your network or VPN may be blocking it.',
    )).toHaveAttribute('data-connection-mark', 'failed');
  });

  it('shows them in a channel nobody is in yet', () => {
    useVoiceStore.setState({
      currentVoiceChannelId: null,
      isLiveKitConnected: false,
      participants: [],
      voiceUsers: new Map(),
      voiceConnecting: new Map([['voice-1', [{ userId: '2', state: 'connecting' as const }]]]),
    });

    renderChannel();

    expect(screen.getByText('Bob')).toBeInTheDocument();
  });

  it('does not list a member twice when the join overtook the end of the attempt', () => {
    useVoiceStore.setState({
      voiceConnecting: new Map([['voice-1', [{ userId: '2', state: 'connecting' as const }]]]),
    });

    const { container } = renderChannel();

    expect(screen.getAllByText('Bob')).toHaveLength(1);
    expect(container.querySelector('[data-connection-mark="connecting"]')).toBeNull();
  });
});

describe('VoiceChannel occupancy timer', () => {
  it('shows and updates the server-authoritative channel duration even when viewing another channel', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2038-01-19T03:14:07Z'));
    useVoiceStore.setState({
      currentVoiceChannelId: 'voice-2',
      voiceChannelElapsedSeconds: new Map([['voice-1', {
        elapsedSeconds: 65,
        observedAt: Date.now(),
      }]]),
    });

    renderChannel();

    expect(screen.getByTestId('voice-channel-timer')).toHaveTextContent('01:05');
    act(() => {
      vi.advanceTimersByTime(1_000);
    });
    expect(screen.getByTestId('voice-channel-timer')).toHaveTextContent('01:06');
  });

  it('clears the server duration only when the channel becomes empty', () => {
    const observation = { elapsedSeconds: 65, observedAt: Date.now() };
    useVoiceStore.setState({ voiceChannelElapsedSeconds: new Map([['voice-1', observation]]) });

    useVoiceStore.getState().removeVoiceUser('voice-1', '2');
    expect(useVoiceStore.getState().voiceChannelElapsedSeconds.get('voice-1')).toBe(observation);

    useVoiceStore.getState().removeVoiceUser('voice-1', '1');
    expect(useVoiceStore.getState().voiceChannelElapsedSeconds.has('voice-1')).toBe(false);
  });

  it('overlays channel settings without reserving space beside the timer', () => {
    useVoiceStore.setState({
      voiceChannelElapsedSeconds: new Map([['voice-1', {
        elapsedSeconds: 0,
        observedAt: Date.now(),
      }]]),
    });

    renderChannel(true);

    expect(screen.getByTestId('voice-channel-timer')).not.toHaveClass('group-hover:opacity-0');
    expect(screen.getByTestId('voice-channel-settings')).toHaveClass(
      'absolute',
      'right-full',
      'mr-1',
      'pointer-events-none',
      'group-hover:pointer-events-auto',
    );
  });

  it('opens channel settings without also activating the channel row', () => {
    const onSettingsClick = vi.fn();
    const onClick = vi.fn();
    render(
      <VoiceChannel
        channelId="voice-1"
        channelName="Voice"
        onClick={onClick}
        canManage
        onSettingsClick={onSettingsClick}
      />,
    );

    fireEvent.click(screen.getByTestId('voice-channel-settings'));

    expect(onSettingsClick).toHaveBeenCalledOnce();
    expect(onClick).not.toHaveBeenCalled();
  });

  it('keeps the ticking duration out of the accessible name of the channel row', () => {
    useVoiceStore.setState({
      voiceChannelElapsedSeconds: new Map([['voice-1', {
        elapsedSeconds: 65,
        observedAt: Date.now(),
      }]]),
    });

    renderChannel(true);

    expect(screen.getByTestId('voice-channel-timer')).toHaveAttribute('aria-hidden', 'true');
    expect(screen.getByRole('button', { name: 'Voice' })).toBeInTheDocument();
  });
});

describe('VoiceChannel own row', () => {
  const ORBIT = 'https://orbit.example';
  const dragHandlers = () => ({ draggable: true, isBeingDragged: false, onDragStart: () => {}, onDragEnd: () => {} });

  function renderWithDrag() {
    return render(
      <VoiceChannel channelId="voice-1" channelName="Voice" onClick={() => {}} voiceUserHandlers={dragHandlers} />,
    );
  }

  function rowOf(name: string): HTMLElement {
    return screen.getByText(name).closest('[draggable]') as HTMLElement;
  }

  it("is the user's row on a remote space's instance, not the row that has the session row's id", () => {
    // orbit knows the user as o-7; orbit's Cleo has the id the session row has.
    useAuthStore.setState({ myRowIds: new Map([[ORBIT, 'o-7']]) });
    useSpaceStore.setState({
      channelOriginMap: new Map([['voice-1', ORBIT]]),
      members: [
        { spaceId: 'space-1', userId: 'o-7', user: { id: 'o-7', username: 'ada@nova', displayName: 'Ada', avatar: null }, roles: [] },
        { spaceId: 'space-1', userId: '1', user: { id: '1', username: 'cleo', displayName: 'Cleo', avatar: null }, roles: [] },
      ] as unknown as MemberWithUser[],
    });
    useVoiceStore.setState({
      participants: [participant('o-7', 'ada', true), participant('1', 'cleo', false)],
      voiceUsers: new Map([['voice-1', ['o-7', '1']]]),
    });
    const open = vi.fn();
    useContextMenuStore.setState({ open });
    renderWithDrag();

    expect(rowOf('Ada')).toHaveAttribute('draggable', 'false');
    expect(rowOf('Cleo')).toHaveAttribute('draggable', 'true');
    fireEvent.contextMenu(rowOf('Ada'));
    expect(open).not.toHaveBeenCalled();
    fireEvent.contextMenu(rowOf('Cleo'));
    expect(open).toHaveBeenCalledTimes(1);
  });

  it("is the session row's on the page instance", () => {
    const open = vi.fn();
    useContextMenuStore.setState({ open });
    renderWithDrag();

    expect(rowOf('Ada')).toHaveAttribute('draggable', 'false');
    expect(rowOf('Bob')).toHaveAttribute('draggable', 'true');
    fireEvent.contextMenu(rowOf('Ada'));
    expect(open).not.toHaveBeenCalled();
  });
});
