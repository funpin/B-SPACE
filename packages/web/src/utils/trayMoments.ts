/**
 * Moments the tray character answers with joy: a message the user sent went
 * through, the user signed in (brand README, state "Радуется"). The stores
 * where these happen call `celebrateInTray()`; the tray bridge
 * (useTrayBridge) listens. Outside the desktop app nobody listens and the
 * call costs nothing.
 */
const moments = new EventTarget();

export function celebrateInTray(): void {
  moments.dispatchEvent(new Event('joy'));
}

export function onTrayCelebrate(callback: () => void): () => void {
  moments.addEventListener('joy', callback);
  return () => moments.removeEventListener('joy', callback);
}
