import type { ChosenUserStatus } from '@backspace/shared';
import type { HomeConnection } from '../stores/homeConnectionStore';

/**
 * The B:SPACE character in the desktop tray (menu bar on macOS, the
 * notification area on Windows). Must match TRAY_STATES in
 * packages/desktop/src/trayState.ts, which plays each state's animation.
 */
export type TrayState = 'idle' | 'look' | 'notify' | 'typing' | 'voice' | 'screen' | 'joy' | 'dnd' | 'offline';

/** How long the character stays happy after a sent message or a sign-in. */
export const JOY_DURATION_MS = 1800;

export interface TrayInputs {
  homeConnection: HomeConnection;
  /** A voice connection is being set up or re-established. */
  voiceConnecting: boolean;
  isScreenSharing: boolean;
  /** The user's own microphone is picking up speech in a call. */
  isSpeaking: boolean;
  unreadCount: number;
  /** Someone is typing to the user: in a DM, or in the channel open on screen. */
  someoneTyping: boolean;
  /** A sent message or a sign-in is being celebrated (JOY_DURATION_MS). */
  celebrating: boolean;
  chosenStatus: ChosenUserStatus | null;
}

/**
 * One state wins, most urgent first:
 * - offline: nothing else is trustworthy without the server;
 * - screen: a privacy reminder that nothing may hide;
 * - voice: the user is speaking, the live thing happening right now;
 * - notify: unread messages;
 * - joy: the short answer to the user's own action;
 * - dnd: the user asked to be left alone, so the lesser signals below wait;
 * - typing, look (connecting, loading): passing activity;
 * - idle.
 */
export function pickTrayState(inputs: TrayInputs): TrayState {
  if (inputs.homeConnection === 'closed') return 'offline';
  if (inputs.isScreenSharing) return 'screen';
  if (inputs.isSpeaking) return 'voice';
  if (inputs.unreadCount > 0) return 'notify';
  if (inputs.celebrating) return 'joy';
  if (inputs.chosenStatus === 'dnd' || inputs.chosenStatus === 'idle') return 'dnd';
  if (inputs.someoneTyping) return 'typing';
  if (inputs.homeConnection === 'unknown' || inputs.voiceConnecting) return 'look';
  return 'idle';
}

/**
 * The tray menu's quick controls. Must match TrayContext in
 * packages/desktop/src/trayContext.ts, which validates it.
 */
export interface TrayContext {
  signedIn: boolean;
  voice: { channelName: string } | null;
  muted: boolean;
  deafened: boolean;
  status: ChosenUserStatus | null;
}

/** A quick control clicked in the tray menu. Must match TrayAction in trayContext.ts. */
export type TrayAction =
  | { type: 'toggleMute' }
  | { type: 'toggleDeafen' }
  | { type: 'disconnect' }
  | { type: 'setStatus'; status: ChosenUserStatus };

export function sameTrayContext(a: TrayContext, b: TrayContext): boolean {
  return a.signedIn === b.signedIn
    && a.muted === b.muted
    && a.deafened === b.deafened
    && a.status === b.status
    && (a.voice?.channelName ?? null) === (b.voice?.channelName ?? null);
}
