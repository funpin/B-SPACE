/**
 * Viewers' pointers on this client's own screen share, handed to the desktop
 * app, which draws them over the shared display (packages/desktop/src/
 * pointerOverlay.ts). Inside the app the sharer sees them on the stream tile;
 * the overlay is what lets them see where someone points while they are
 * looking at the real desktop, which is where a sharer looks.
 *
 * Only the desktop app can draw over other windows. In a browser this module
 * does nothing; the tile keeps drawing the pointers there as before.
 */
import type { ParticipantInfo } from '../hooks/useLiveKit';
import {
  STREAM_POINTER_IDLE_MS,
  STREAM_POINTER_PING_MS,
  type RemotePointer,
} from '../stores/streamPointerStore';

/** One pointer as the desktop overlay draws it. Coordinates are fractions of the shared picture. */
export interface OverlayPointer {
  id: string;
  name: string;
  /** A concrete `rgb(…)` colour: the overlay page has none of the app's CSS variables. */
  color: string;
  x: number;
  y: number;
  /** Faded: it has not moved for `STREAM_POINTER_IDLE_MS`. */
  idle: boolean;
  /** The time of the click whose ring is still showing, or 0. */
  ping: number;
}

/**
 * How long a faded pointer is still sent. It stays in the list a little past
 * the fade so the overlay can play the fade out instead of dropping the mark.
 */
const FADED_GRACE_MS = 1000;

/**
 * The overlay's list for the pointers on the local share. A pointer from
 * someone no longer in the call is left out; one that has been still past the
 * fade and its grace is dropped.
 */
export function overlayPointersFor(
  pointers: ReadonlyMap<string, RemotePointer> | undefined,
  participants: readonly ParticipantInfo[],
  now: number,
  describe: (participant: ParticipantInfo) => { name: string; color: string },
): OverlayPointer[] {
  if (!pointers) return [];
  const list: OverlayPointer[] = [];
  for (const [identity, pointer] of pointers) {
    const participant = participants.find((p) => p.identity === identity && !p.isLocal);
    if (!participant) continue;
    const stillFor = now - pointer.movedAt;
    if (stillFor >= STREAM_POINTER_IDLE_MS + FADED_GRACE_MS) continue;
    const { name, color } = describe(participant);
    list.push({
      id: identity,
      name,
      color,
      x: pointer.point.x,
      y: pointer.point.y,
      idle: stillFor >= STREAM_POINTER_IDLE_MS,
      ping: pointer.pingAt > 0 && now - pointer.pingAt < STREAM_POINTER_PING_MS ? pointer.pingAt : 0,
    });
  }
  return list;
}

/**
 * `rgb(var(--accent-mint))` as the concrete colour the overlay can draw:
 * custom properties resolve their own `var()` references in the computed style.
 */
export function resolveCssColor(color: string, root: Element = document.documentElement): string {
  const match = /^rgb\(var\((--[\w-]+)\)\)$/.exec(color);
  if (!match) return color;
  const channels = getComputedStyle(root).getPropertyValue(match[1]!).trim();
  return channels ? `rgb(${channels})` : color;
}

/** Whether two lists would draw the same overlay, so an unchanged one is not sent again. */
export function sameOverlay(a: readonly OverlayPointer[], b: readonly OverlayPointer[]): boolean {
  if (a.length !== b.length) return false;
  return a.every((pointer, index) => {
    const other = b[index]!;
    return pointer.id === other.id
      && pointer.x === other.x
      && pointer.y === other.y
      && pointer.idle === other.idle
      && pointer.ping === other.ping
      && pointer.name === other.name
      && pointer.color === other.color;
  });
}
