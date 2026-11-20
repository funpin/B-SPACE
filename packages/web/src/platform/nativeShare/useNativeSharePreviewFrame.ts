/**
 * Keeps the native shell's live preview over the page's preview box.
 *
 * The shell draws the preview in a layer above the page, so the page has to
 * say where its box is, and say again whenever the box moves: the layout
 * shifts when the strip slides open, when the window is resized, when the
 * grid above it grows. Observers do not report a box that only moved, so the
 * box is measured once a frame while a preview is shown, and the shell is
 * told only when it has changed and then come to rest. A box caught in the
 * middle of a transition would show the picture sliding a frame behind the
 * page.
 *
 * The layer covers whatever the page draws there, so the picture is hidden
 * (a frame of `null`) while the box is not there, has no size, or is under
 * something of the page's own (`coveredBy`).
 */
import { useEffect, type RefObject } from 'react';
import { placeNativePreview } from './nativeScreenShare';

/** Frames a box has to stand still for before the picture is put over it. */
const FRAMES_AT_REST = 2;

interface Box {
  x: number;
  y: number;
  width: number;
  height: number;
  radius: number;
}

function sameBox(a: Box | null, b: Box | null): boolean {
  if (a === null || b === null) return a === b;
  return Math.abs(a.x - b.x) < 0.5 && Math.abs(a.y - b.y) < 0.5
    && Math.abs(a.width - b.width) < 0.5 && Math.abs(a.height - b.height) < 0.5
    && a.radius === b.radius;
}

function overlaps(a: DOMRect, b: DOMRect): boolean {
  return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
}

/** The box of `element` as the shell wants it, or null when there is nothing to put a picture over. */
export function previewBoxOf(element: Element | null, cover: Element | null): Box | null {
  if (!element || !element.isConnected) return null;
  const rect = element.getBoundingClientRect();
  if (rect.width < 1 || rect.height < 1) return null;
  if (cover && cover.isConnected && overlaps(rect, cover.getBoundingClientRect())) return null;
  // The corners are the frame's that clips the box, when it has one.
  const frame = element.parentElement ?? element;
  const radius = Number.parseFloat(getComputedStyle(frame).borderTopLeftRadius) || 0;
  return { x: rect.left, y: rect.top, width: rect.width, height: rect.height, radius };
}

/**
 * @param box the element the preview goes over
 * @param shown whether there is a preview to show now
 * @param coveredBy an element of the page that may lie over the box (the
 *   quality drawer); while it does, the picture is hidden
 */
export function useNativeSharePreviewFrame(
  box: RefObject<Element | null>,
  shown: boolean,
  coveredBy?: RefObject<Element | null>,
): void {
  useEffect(() => {
    if (!shown) return;
    let sent: Box | null = null;
    let seen: Box | null = null;
    let atRest = 0;
    let frame = 0;
    const measure = () => {
      const next = previewBoxOf(box.current, coveredBy?.current ?? null);
      if (sameBox(next, seen)) atRest += 1;
      else { seen = next; atRest = 0; }
      // Hidden at once; shown or moved only when it has come to rest.
      if (next === null && sent !== null) {
        sent = null;
        placeNativePreview(null);
      } else if (next !== null && atRest >= FRAMES_AT_REST && !sameBox(next, sent)) {
        sent = next;
        placeNativePreview(next);
      } else if (next !== null && sent !== null && !sameBox(next, sent) && atRest === 0) {
        // On the move: the picture waits out of sight rather than trail the box.
        sent = null;
        placeNativePreview(null);
      }
      frame = requestAnimationFrame(measure);
    };
    frame = requestAnimationFrame(measure);
    return () => {
      cancelAnimationFrame(frame);
      placeNativePreview(null);
    };
  }, [box, shown, coveredBy]);
}
