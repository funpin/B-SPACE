/**
 * Wire format and geometry of the stream pointer: a viewer's mouse shown to
 * everyone else watching the same screen share, the sharer included. Nothing
 * reaches the sharer's machine but a position; the desktop app draws it over
 * the shared display (utils/streamPointerOverlay.ts).
 *
 * `stream_pointer` travels on the LiveKit data channel next to `stream_watch`
 * (see streamWatchProtocol.ts). Moves are lossy and frequent; the leave and
 * the ping are reliable. Clients that predate it ignore it.
 *
 * A position is a fraction of the shared picture itself (0..1 on both axes,
 * origin top-left), never of a tile: every viewer shows the picture at a
 * different size, letterboxed differently and under its own zoom, and the
 * picture is the one thing they all have in common.
 */
export interface StreamPointerPayload {
  type: 'stream_pointer';
  /** The sharer's LiveKit identity, the same string on every client in the room. */
  target: string;
  /** Null when the pointer left the picture or pointing was switched off. */
  x: number | null;
  y: number | null;
  /** A click: receivers flash a ring at the position. */
  ping?: boolean;
}

/** A point of the shared picture, both axes 0..1. */
export interface PicturePoint {
  x: number;
  y: number;
}

export interface Box {
  left: number;
  top: number;
  width: number;
  height: number;
}

export function streamPointerFor(sharerIdentity: string, point: PicturePoint | null, ping = false): StreamPointerPayload {
  const payload: StreamPointerPayload = {
    type: 'stream_pointer',
    target: sharerIdentity,
    // Four decimals place a pointer within a pixel on an 8K picture.
    x: point ? Math.round(point.x * 10_000) / 10_000 : null,
    y: point ? Math.round(point.y * 10_000) / 10_000 : null,
  };
  if (ping) payload.ping = true;
  return payload;
}

export function encodeStreamPointer(payload: StreamPointerPayload): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(new TextEncoder().encode(JSON.stringify(payload)));
}

function isFraction(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1;
}

export function isStreamPointerPayload(value: unknown): value is StreamPointerPayload {
  if (typeof value !== 'object' || value === null) return false;
  const v = value as Record<string, unknown>;
  if (v.type !== 'stream_pointer' || typeof v.target !== 'string') return false;
  if (v.ping !== undefined && typeof v.ping !== 'boolean') return false;
  if (v.x === null && v.y === null) return true;
  return isFraction(v.x) && isFraction(v.y);
}

export function parseStreamPointer(payload: Uint8Array): StreamPointerPayload | null {
  try {
    const parsed: unknown = JSON.parse(new TextDecoder().decode(payload));
    return isStreamPointerPayload(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

/**
 * From a sharer to everyone in the room: whether its desktop overlay of the
 * pointers (packages/desktop/src/pointerOverlay.ts) is in the shared picture.
 * Normally it is kept out of the capture; where Windows ignores that, the
 * picture already shows every pointer, so viewers stop drawing their own
 * copies over it and keep the system cursor. Clients that predate it ignore it.
 */
export interface StreamPointerOverlayPayload {
  type: 'stream_pointer_overlay';
  captured: boolean;
}

export function encodeStreamPointerOverlay(captured: boolean): Uint8Array<ArrayBuffer> {
  const payload: StreamPointerOverlayPayload = { type: 'stream_pointer_overlay', captured };
  return Uint8Array.from(new TextEncoder().encode(JSON.stringify(payload)));
}

export function parseStreamPointerOverlay(payload: Uint8Array): StreamPointerOverlayPayload | null {
  try {
    const parsed: unknown = JSON.parse(new TextDecoder().decode(payload));
    if (typeof parsed !== 'object' || parsed === null) return null;
    const v = parsed as Record<string, unknown>;
    if (v.type !== 'stream_pointer_overlay' || typeof v.captured !== 'boolean') return null;
    return { type: 'stream_pointer_overlay', captured: v.captured };
  } catch {
    return null;
  }
}

/**
 * Where an `object-fit: contain` picture of `pictureWidth`×`pictureHeight`
 * sits inside a box: centred, as large as fits, bands on the long side.
 */
export function containedBox(box: Box, pictureWidth: number, pictureHeight: number): Box | null {
  if (box.width <= 0 || box.height <= 0 || pictureWidth <= 0 || pictureHeight <= 0) return null;
  const scale = Math.min(box.width / pictureWidth, box.height / pictureHeight);
  const width = pictureWidth * scale;
  const height = pictureHeight * scale;
  return {
    left: box.left + (box.width - width) / 2,
    top: box.top + (box.height - height) / 2,
    width,
    height,
  };
}

/**
 * The point of the picture under a client position, or null when the position
 * is on a letterbox band or outside the element. `videoBounds` is the video
 * element's bounding box as the viewer sees it, zoom and pan included.
 */
export function pointInPicture(
  clientX: number,
  clientY: number,
  videoBounds: Box,
  pictureWidth: number,
  pictureHeight: number,
): PicturePoint | null {
  const picture = containedBox(videoBounds, pictureWidth, pictureHeight);
  if (!picture) return null;
  const x = (clientX - picture.left) / picture.width;
  const y = (clientY - picture.top) / picture.height;
  if (x < 0 || x > 1 || y < 0 || y > 1) return null;
  return { x, y };
}
