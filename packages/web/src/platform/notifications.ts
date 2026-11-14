import { isElectron } from './platform';
import type { TrayAction, TrayContext, TrayState } from '../utils/trayState';

export interface NotificationOptions {
  channelId?: string;
  spaceId?: string;
  userId?: string;
}

const clicks = new EventTarget();

/** One subscription per mounted controller, including older desktop bridges. */
export function onNotificationClick(callback: (options: NotificationOptions) => void): () => void {
  const handler = (event: Event) => callback((event as CustomEvent<NotificationOptions>).detail);
  clicks.addEventListener('click', handler);
  const unsubscribe = window.backspace?.onNotificationClick?.(callback);
  return () => {
    clicks.removeEventListener('click', handler);
    unsubscribe?.();
  };
}

export function sendNotification(title: string, body: string, options?: NotificationOptions): void {
  if (isElectron()) {
    window.backspace!.showNotification(title, body, options);
  } else if ('Notification' in window && Notification.permission === 'granted') {
    const notification = new Notification(title, { body, icon: '/icons/icon-192.png' });
    notification.onclick = () => {
      window.focus();
      notification.close();
      if (options) clicks.dispatchEvent(new CustomEvent('click', { detail: options }));
    };
  }
}

export function requestNotificationPermission(): Promise<boolean> {
  if (isElectron()) return Promise.resolve(true);
  if (!('Notification' in window)) return Promise.resolve(false);
  return Notification.requestPermission().then((p) => p === 'granted');
}

export function updateBadgeCount(count: number): void {
  if (isElectron()) {
    window.backspace!.setBadgeCount(count);
  }
}

/** The states a desktop build without the animated tray can show; it ignores any other. */
const STILL_TRAY_STATES: ReadonlySet<TrayState> = new Set(['idle', 'notify', 'screen', 'dnd', 'offline']);

/**
 * The character in the desktop tray. Desktop builds older than the tray
 * states lack the bridge method and keep the idle icon. Builds older than the
 * animated tray (no `setTrayContext`) know five states and would keep showing
 * the previous one on any other, so they get idle instead.
 */
export function updateTrayState(state: TrayState): void {
  if (!isElectron()) return;
  const bridge = window.backspace;
  if (!bridge?.setTrayState) return;
  bridge.setTrayState(bridge.setTrayContext || STILL_TRAY_STATES.has(state) ? state : 'idle');
}

/** The tray menu's quick controls. A no-op outside the desktop app and on older builds. */
export function updateTrayContext(context: TrayContext): void {
  if (isElectron()) window.backspace?.setTrayContext?.(context);
}

/** Subscribes to quick controls clicked in the tray menu. */
export function onTrayAction(callback: (action: TrayAction) => void): () => void {
  if (!isElectron()) return () => {};
  return window.backspace?.onTrayAction?.(callback) ?? (() => {});
}
