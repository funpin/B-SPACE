import type { MenuItemConstructorOptions } from 'electron';
import { translateDesktop, type DesktopLanguage } from './l10n';

/**
 * What the tray menu needs from the renderer to offer the quick controls:
 * the voice connection, mute and deafen, and the user's own status. The
 * renderer reports it over `set-tray-context`; clicking one of the controls
 * sends a `tray-action` back, and the renderer carries it out exactly as the
 * voice bar or the status picker would.
 */

export const TRAY_STATUSES = ['online', 'idle', 'dnd'] as const;
export type TrayStatus = (typeof TRAY_STATUSES)[number];

export interface TrayContext {
  /** False before sign-in and on the instance picker: no controls then. */
  signedIn: boolean;
  /** The voice channel or call the user is in, or null. */
  voice: { channelName: string } | null;
  muted: boolean;
  deafened: boolean;
  status: TrayStatus | null;
}

export type TrayAction =
  | { type: 'toggleMute' }
  | { type: 'toggleDeafen' }
  | { type: 'disconnect' }
  | { type: 'setStatus'; status: TrayStatus };

export const EMPTY_TRAY_CONTEXT: TrayContext = {
  signedIn: false,
  voice: null,
  muted: false,
  deafened: false,
  status: null,
};

/** Longest channel name the menu shows before cutting it with an ellipsis. */
const MAX_CHANNEL_NAME = 40;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isTrayStatus(value: unknown): value is TrayStatus {
  return typeof value === 'string' && (TRAY_STATUSES as readonly string[]).includes(value);
}

/**
 * Validates what the renderer sent. Anything malformed yields null and the
 * caller keeps the context it had; the main process never builds a menu
 * from an unchecked shape.
 */
export function parseTrayContext(value: unknown): TrayContext | null {
  if (!isRecord(value)) return null;
  const { signedIn, voice, muted, deafened, status } = value;
  if (typeof signedIn !== 'boolean' || typeof muted !== 'boolean' || typeof deafened !== 'boolean') return null;
  if (status !== null && !isTrayStatus(status)) return null;
  let parsedVoice: TrayContext['voice'] = null;
  if (voice !== null) {
    if (!isRecord(voice) || typeof voice.channelName !== 'string') return null;
    const name = voice.channelName.trim();
    parsedVoice = {
      channelName: name.length > MAX_CHANNEL_NAME ? `${name.slice(0, MAX_CHANNEL_NAME - 1)}…` : name,
    };
  }
  return { signedIn, voice: parsedVoice, muted, deafened, status };
}

export function sameTrayContext(a: TrayContext, b: TrayContext): boolean {
  return a.signedIn === b.signedIn
    && a.muted === b.muted
    && a.deafened === b.deafened
    && a.status === b.status
    && (a.voice?.channelName ?? null) === (b.voice?.channelName ?? null);
}

const STATUS_KEYS = {
  online: 'tray.status.online',
  idle: 'tray.status.idle',
  dnd: 'tray.status.dnd',
} as const;

/**
 * The quick-control items at the top of the tray menu, followed by a
 * separator. Empty when nobody is signed in.
 *
 * Mute and deafen are offered outside a call too: there they set how the
 * user joins the next one, the same as the buttons in the voice bar.
 */
export function buildTrayControlItems(
  context: TrayContext,
  onAction: (action: TrayAction) => void,
  language: DesktopLanguage,
): MenuItemConstructorOptions[] {
  if (!context.signedIn) return [];
  const t = (key: Parameters<typeof translateDesktop>[1], vars?: Record<string, string>) => translateDesktop(language, key, vars);
  const items: MenuItemConstructorOptions[] = [];

  if (context.voice) {
    items.push({ label: t('tray.inVoice', { channel: context.voice.channelName }), enabled: false });
  }
  items.push(
    { label: t('tray.mute'), type: 'checkbox', checked: context.muted, click: () => onAction({ type: 'toggleMute' }) },
    { label: t('tray.deafen'), type: 'checkbox', checked: context.deafened, click: () => onAction({ type: 'toggleDeafen' }) },
  );
  if (context.voice) {
    items.push({ label: t('tray.disconnect'), click: () => onAction({ type: 'disconnect' }) });
  }

  if (context.status !== null) {
    items.push({
      label: t('tray.status'),
      submenu: TRAY_STATUSES.map((status) => ({
        label: t(STATUS_KEYS[status]),
        type: 'radio' as const,
        checked: context.status === status,
        click: () => {
          if (context.status !== status) onAction({ type: 'setStatus', status });
        },
      })),
    });
  }

  items.push({ type: 'separator' });
  return items;
}
