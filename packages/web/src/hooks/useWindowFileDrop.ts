import { useEffect, useState } from 'react';
import { activeFileDropTarget, type FileDropTarget } from '../stores/fileDropStore';

/**
 * Marks the app shell: the parts of the window where a dropped file goes to
 * the open conversation's composer. Anything outside it (modals, dialogs,
 * popovers portaled to `body`, the image viewer) refuses the drop.
 */
export const FILE_DROP_SURFACE_ATTR = 'data-file-drop-surface';

/**
 * Marks an element with its own file drop handling (the sticker image
 * picker). File drags over it are left entirely to its own handlers.
 */
export const FILE_DROP_ZONE_ATTR = 'data-file-drop-zone';

/**
 * How long the overlay stays up without a `dragover`. Browsers fire
 * `dragover` repeatedly while a drag is over the page, even when the pointer
 * is still (the HTML spec allows up to 350 ms ± 200 ms between them), so a
 * silence longer than that means the drag left or was cancelled without a
 * `dragleave` reaching the window: an iframe embed swallowed it, or the
 * engine dropped one of the enter/leave pairs.
 */
export const FILE_DROP_WATCHDOG_MS = 1000;

export type WindowFileDropState =
  | { kind: 'idle' }
  | { kind: 'accept'; label: string }
  | { kind: 'denied'; label: string };

const IDLE: WindowFileDropState = { kind: 'idle' };

type Resolution =
  | { kind: 'own' }
  | { kind: 'idle' }
  | { kind: 'accept'; target: FileDropTarget }
  | { kind: 'denied'; target: FileDropTarget };

/**
 * True for a drag that carries files from outside the page. In-page drags
 * (reordering spaces, channels, voice tiles) and dragged text or links carry
 * no `Files` type and are never touched.
 */
export function carriesFiles(dataTransfer: DataTransfer | null): boolean {
  if (!dataTransfer) return false;
  // `types` is a frozen array in current engines and a DOMStringList in old WebKit.
  return Array.from(dataTransfer.types).includes('Files');
}

function elementOf(target: EventTarget | null): Element | null {
  if (target instanceof Element) return target;
  if (target instanceof Node) return target.parentElement;
  return null;
}

function resolve(eventTarget: EventTarget | null): Resolution {
  const el = elementOf(eventTarget);
  if (el?.closest(`[${FILE_DROP_ZONE_ATTR}]`)) return { kind: 'own' };
  if (!el?.closest(`[${FILE_DROP_SURFACE_ATTR}]`)) return { kind: 'idle' };
  const target = activeFileDropTarget();
  if (!target) return { kind: 'idle' };
  return target.canAttach ? { kind: 'accept', target } : { kind: 'denied', target };
}

function toState(r: Resolution): WindowFileDropState {
  if (r.kind === 'accept' || r.kind === 'denied') return { kind: r.kind, label: r.target.label };
  return IDLE;
}

function sameState(a: WindowFileDropState, b: WindowFileDropState): boolean {
  if (a.kind !== b.kind) return false;
  if (a.kind === 'idle' || b.kind === 'idle') return true;
  return a.label === b.label;
}

/**
 * Makes the whole window a drop target for files.
 *
 * Listens on `window` in the capture phase, so a file drag is decided before
 * any element's own drag handlers run: the in-page reordering handlers stop
 * propagation on drop and would otherwise swallow a file let go over the
 * space strip. For a file drag outside a `data-file-drop-zone` the default is
 * always prevented, so the browser never opens or downloads the file, and
 * propagation is stopped, so no in-page handler mistakes it for its own drag.
 * The drop is handed to the active composer only over the app shell and only
 * when the user may attach files there.
 *
 * `dragenter`/`dragleave` fire for every element crossed, so "is a drag over
 * the window" is a counter of entered elements; it resets on drop, on the
 * counter reaching zero, on `dragend`, and on the watchdog above.
 */
export function useWindowFileDrop(): WindowFileDropState {
  const [state, setState] = useState<WindowFileDropState>(IDLE);

  useEffect(() => {
    let depth = 0;
    let watchdog: ReturnType<typeof setTimeout> | undefined;

    const show = (next: WindowFileDropState): void => {
      setState((prev) => (sameState(prev, next) ? prev : next));
    };

    const reset = (): void => {
      depth = 0;
      if (watchdog !== undefined) clearTimeout(watchdog);
      watchdog = undefined;
      show(IDLE);
    };

    const armWatchdog = (): void => {
      if (watchdog !== undefined) clearTimeout(watchdog);
      watchdog = setTimeout(reset, FILE_DROP_WATCHDOG_MS);
    };

    const over = (e: DragEvent): void => {
      armWatchdog();
      const r = resolve(e.target);
      if (r.kind === 'own') {
        show(IDLE);
        return;
      }
      e.preventDefault();
      e.stopPropagation();
      if (e.dataTransfer) e.dataTransfer.dropEffect = r.kind === 'accept' ? 'copy' : 'none';
      show(toState(r));
    };

    const onDragEnter = (e: DragEvent): void => {
      if (!carriesFiles(e.dataTransfer)) return;
      depth += 1;
      over(e);
    };

    const onDragOver = (e: DragEvent): void => {
      if (!carriesFiles(e.dataTransfer)) return;
      over(e);
    };

    const onDragLeave = (e: DragEvent): void => {
      if (!carriesFiles(e.dataTransfer)) return;
      depth = Math.max(0, depth - 1);
      if (depth === 0) reset();
    };

    const onDrop = (e: DragEvent): void => {
      if (!carriesFiles(e.dataTransfer)) return;
      const r = resolve(e.target);
      reset();
      if (r.kind === 'own') return;
      e.preventDefault();
      e.stopPropagation();
      if (r.kind === 'accept' && e.dataTransfer) r.target.accept(e.dataTransfer);
    };

    window.addEventListener('dragenter', onDragEnter, true);
    window.addEventListener('dragover', onDragOver, true);
    window.addEventListener('dragleave', onDragLeave, true);
    window.addEventListener('drop', onDrop, true);
    window.addEventListener('dragend', reset, true);
    return () => {
      window.removeEventListener('dragenter', onDragEnter, true);
      window.removeEventListener('dragover', onDragOver, true);
      window.removeEventListener('dragleave', onDragLeave, true);
      window.removeEventListener('drop', onDrop, true);
      window.removeEventListener('dragend', reset, true);
      if (watchdog !== undefined) clearTimeout(watchdog);
    };
  }, []);

  return state;
}
