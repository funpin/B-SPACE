import { act, cleanup, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { DmChannel, User } from '@backspace/shared';
import { useAuthStore } from '../stores/authStore';
import { useChatStore } from '../stores/chatStore';
import { useHomeConnectionStore } from '../stores/homeConnectionStore';
import { useSpaceStore } from '../stores/spaceStore';
import { useVoiceStore } from '../stores/voiceStore';
import { celebrateInTray } from '../utils/trayMoments';
import { JOY_DURATION_MS, type TrayAction } from '../utils/trayState';
import { runTrayAction, someoneTypingToMe, useTrayBridge } from './useTrayBridge';

const voiceActions = vi.hoisted(() => ({
  toggleMuteFromControl: vi.fn(),
  toggleDeafenFromControl: vi.fn(),
  handleDisconnectAction: vi.fn(),
  handleCameraAction: vi.fn(),
  handleScreenShareAction: vi.fn(),
}));
vi.mock('../utils/voiceActions', () => voiceActions);
vi.mock('../audio/AudioManager', () => ({ AudioManager: { getInstance: () => ({}) } }));

function bridge() {
  let action: ((action: TrayAction) => void) | undefined;
  const off = vi.fn();
  const api = {
    setTrayState: vi.fn(),
    setTrayContext: vi.fn(),
    onTrayAction: vi.fn((callback: (action: TrayAction) => void) => { action = callback; return off; }),
  };
  window.backspace = api as unknown as NonNullable<Window['backspace']>;
  return { api, off, click: (next: TrayAction) => action?.(next) };
}

beforeEach(() => {
  vi.useFakeTimers();
  useAuthStore.setState({ user: { id: 'me', status: 'online' } as User, trueHomeStatus: null, myRowIds: new Map() });
  useHomeConnectionStore.setState({ status: 'open' });
  useSpaceStore.setState({ dmChannels: [{ id: 'dm' } as DmChannel], channels: [] });
  useChatStore.setState({ unreadChannels: new Set(), typingUsers: new Map(), currentChannelId: null });
  useVoiceStore.setState({
    currentVoiceChannelId: null,
    activeDmCall: null,
    isMuted: false,
    isDeafened: false,
    isScreenSharing: false,
    isCameraOn: false,
    showStreamPointers: true,
    participants: [],
    speakingParticipantIds: new Set(),
    voiceConnectionStatus: 'disconnected',
  });
});

afterEach(() => {
  cleanup();
  delete window.backspace;
  vi.useRealTimers();
  vi.clearAllMocks();
});

describe('someoneTypingToMe', () => {
  const typing = new Map([['dm', [{ userId: 'ada' }]], ['busy-channel', [{ userId: 'bob' }]], ['mine', [{ userId: 'me' }]]]);

  it('counts typing in watched channels by anyone but the user', () => {
    expect(someoneTypingToMe(typing, new Set(['dm']), new Set(['me']))).toBe(true);
    expect(someoneTypingToMe(typing, new Set(['mine']), new Set(['me']))).toBe(false);
    expect(someoneTypingToMe(typing, new Set(['elsewhere']), new Set(['me']))).toBe(false);
  });
});

describe('runTrayAction', () => {
  it('runs mute, deafen and disconnect through the voice controls', () => {
    runTrayAction({ type: 'toggleMute' });
    runTrayAction({ type: 'toggleDeafen' });
    runTrayAction({ type: 'disconnect' });
    expect(voiceActions.toggleMuteFromControl).toHaveBeenCalledOnce();
    expect(voiceActions.toggleDeafenFromControl).toHaveBeenCalledOnce();
    expect(voiceActions.handleDisconnectAction).toHaveBeenCalledOnce();
  });

  it('turns the viewers\' pointers on and off, like the stream tile\'s menu', () => {
    runTrayAction({ type: 'toggleShowPointers' });
    expect(useVoiceStore.getState().showStreamPointers).toBe(false);
    runTrayAction({ type: 'toggleShowPointers' });
    expect(useVoiceStore.getState().showStreamPointers).toBe(true);
  });

  it('turns the camera off and stops the screen share through the voice controls', () => {
    useVoiceStore.setState({ isCameraOn: true, isScreenSharing: true });
    runTrayAction({ type: 'stopCamera' });
    runTrayAction({ type: 'stopScreenShare' });
    expect(voiceActions.handleCameraAction).toHaveBeenCalledTimes(1);
    expect(voiceActions.handleScreenShareAction).toHaveBeenCalledTimes(1);
  });

  it('does nothing for a stop action when there is nothing to stop', () => {
    // The same controls would turn the camera on and open the share setup.
    runTrayAction({ type: 'stopCamera' });
    runTrayAction({ type: 'stopScreenShare' });
    expect(voiceActions.handleCameraAction).not.toHaveBeenCalled();
    expect(voiceActions.handleScreenShareAction).not.toHaveBeenCalled();
  });

  it('changes the status through the profile, like the status picker', () => {
    const updateProfile = vi.fn().mockResolvedValue(undefined);
    useAuthStore.setState({ updateProfile });
    runTrayAction({ type: 'setStatus', status: 'dnd' });
    expect(updateProfile).toHaveBeenCalledWith({ status: 'dnd' });
  });
});

describe('useTrayBridge', () => {
  it('does nothing outside the desktop app', () => {
    renderHook(() => useTrayBridge());
    expect(window.backspace).toBeUndefined();
  });

  it('reports the state and the menu context, and only when they change', () => {
    const { api } = bridge();
    renderHook(() => useTrayBridge());
    expect(api.setTrayState).toHaveBeenLastCalledWith('idle');
    expect(api.setTrayContext).toHaveBeenLastCalledWith({
      signedIn: true, voice: null, muted: false, deafened: false, status: 'online',
      cameraOn: false, screenSharing: false, showPointers: true,
    });

    act(() => useChatStore.setState({ typingUsers: new Map([['dm', [{ userId: 'ada', username: 'ada', timestamp: 0 }]]]) }));
    expect(api.setTrayState).toHaveBeenLastCalledWith('typing');
    expect(api.setTrayContext).toHaveBeenCalledTimes(1);

    act(() => useVoiceStore.setState({ currentVoiceChannelId: 'v1', isMuted: true }));
    useSpaceStore.setState({ channels: [{ id: 'v1', name: 'Lounge' }] as never });
    act(() => useVoiceStore.setState({ isDeafened: true }));
    expect(api.setTrayContext).toHaveBeenLastCalledWith({
      signedIn: true, voice: { channelName: 'Lounge' }, muted: true, deafened: true, status: 'online',
      cameraOn: false, screenSharing: false, showPointers: true,
    });
  });

  it('reports the camera, the screen share and the viewers\' pointers setting', () => {
    const { api } = bridge();
    renderHook(() => useTrayBridge());
    act(() => useVoiceStore.setState({ isCameraOn: true }));
    expect(api.setTrayContext).toHaveBeenLastCalledWith(expect.objectContaining({ cameraOn: true, screenSharing: false, showPointers: true }));
    act(() => useVoiceStore.setState({ isScreenSharing: true, showStreamPointers: false }));
    expect(api.setTrayContext).toHaveBeenLastCalledWith(expect.objectContaining({ cameraOn: true, screenSharing: true, showPointers: false }));
  });

  it('shows the user speaking, but not while muted', () => {
    const { api } = bridge();
    useVoiceStore.setState({ participants: [{ identity: 'me:1', isLocal: true }] as never, speakingParticipantIds: new Set(['me:1']) });
    renderHook(() => useTrayBridge());
    expect(api.setTrayState).toHaveBeenLastCalledWith('voice');
    act(() => useVoiceStore.setState({ isMuted: true }));
    expect(api.setTrayState).toHaveBeenLastCalledWith('idle');
  });

  it('celebrates for a moment, then goes back', () => {
    const { api } = bridge();
    renderHook(() => useTrayBridge());
    act(() => celebrateInTray());
    expect(api.setTrayState).toHaveBeenLastCalledWith('joy');
    act(() => { vi.advanceTimersByTime(JOY_DURATION_MS); });
    expect(api.setTrayState).toHaveBeenLastCalledWith('idle');
  });

  it('runs the clicked control and stops listening on unmount', () => {
    const { click, off } = bridge();
    const view = renderHook(() => useTrayBridge());
    click({ type: 'toggleMute' });
    expect(voiceActions.toggleMuteFromControl).toHaveBeenCalledOnce();
    view.unmount();
    expect(off).toHaveBeenCalledOnce();
  });

  it('gives a desktop build without the animated tray only the states it knows', () => {
    const api = { setTrayState: vi.fn() };
    window.backspace = api as unknown as NonNullable<Window['backspace']>;
    useChatStore.setState({ typingUsers: new Map([['dm', [{ userId: 'ada', username: 'ada', timestamp: 0 }]]]) });
    renderHook(() => useTrayBridge());
    expect(api.setTrayState).toHaveBeenLastCalledWith('idle');
    act(() => useChatStore.setState({ unreadChannels: new Set(['dm']) }));
    expect(api.setTrayState).toHaveBeenLastCalledWith('notify');
  });
});
