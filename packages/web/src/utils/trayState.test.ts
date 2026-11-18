import { describe, expect, it } from 'vitest';
import { pickTrayState, sameTrayContext, type TrayContext, type TrayInputs } from './trayState';

const base: TrayInputs = {
  homeConnection: 'open',
  voiceConnecting: false,
  isScreenSharing: false,
  isSpeaking: false,
  unreadCount: 0,
  someoneTyping: false,
  celebrating: false,
  chosenStatus: 'online',
};

describe('pickTrayState', () => {
  it('is idle when nothing needs attention', () => {
    expect(pickTrayState(base)).toBe('idle');
  });

  it('looks around while the server or a call is still connecting', () => {
    expect(pickTrayState({ ...base, homeConnection: 'unknown', chosenStatus: null })).toBe('look');
    expect(pickTrayState({ ...base, voiceConnecting: true })).toBe('look');
  });

  it('shows unread messages', () => {
    expect(pickTrayState({ ...base, unreadCount: 3 })).toBe('notify');
  });

  it('types along when someone is typing to the user', () => {
    expect(pickTrayState({ ...base, someoneTyping: true })).toBe('typing');
    expect(pickTrayState({ ...base, someoneTyping: true, voiceConnecting: true })).toBe('typing');
  });

  it('shows the user speaking above unread messages', () => {
    expect(pickTrayState({ ...base, isSpeaking: true, unreadCount: 2, someoneTyping: true })).toBe('voice');
  });

  it('celebrates above passing activity, below unread messages', () => {
    expect(pickTrayState({ ...base, celebrating: true, someoneTyping: true, chosenStatus: 'dnd' })).toBe('joy');
    expect(pickTrayState({ ...base, celebrating: true, unreadCount: 1 })).toBe('notify');
  });

  it('shows the user\'s own Do Not Disturb and Idle as closed eyes, over typing and connecting', () => {
    expect(pickTrayState({ ...base, chosenStatus: 'dnd' })).toBe('dnd');
    expect(pickTrayState({ ...base, chosenStatus: 'idle', someoneTyping: true, voiceConnecting: true })).toBe('dnd');
  });

  it('puts screen sharing above speaking, unread messages and status', () => {
    expect(pickTrayState({ ...base, isScreenSharing: true, isSpeaking: true, unreadCount: 5, chosenStatus: 'dnd' })).toBe('screen');
  });

  it('puts a lost connection above everything', () => {
    expect(pickTrayState({ ...base, homeConnection: 'closed', isScreenSharing: true, unreadCount: 5, celebrating: true })).toBe('offline');
  });
});

describe('sameTrayContext', () => {
  const context: TrayContext = {
    signedIn: true, voice: { channelName: 'General' }, muted: false, deafened: false, status: 'online',
    cameraOn: false, screenSharing: false, showPointers: true,
  };

  it('compares by value', () => {
    expect(sameTrayContext(context, { ...context, voice: { channelName: 'General' } })).toBe(true);
    expect(sameTrayContext(context, { ...context, muted: true })).toBe(false);
    expect(sameTrayContext(context, { ...context, voice: null })).toBe(false);
    expect(sameTrayContext(context, { ...context, status: 'dnd' })).toBe(false);
  });

  it('tells apart what only the native macOS menu shows', () => {
    expect(sameTrayContext(context, { ...context, cameraOn: true })).toBe(false);
    expect(sameTrayContext(context, { ...context, screenSharing: true })).toBe(false);
    expect(sameTrayContext(context, { ...context, showPointers: false })).toBe(false);
  });
});
