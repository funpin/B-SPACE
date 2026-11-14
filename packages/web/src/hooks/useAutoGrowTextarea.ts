import { useLayoutEffect, type RefObject } from 'react';

/** Sets a textarea's height to that of its text, keeping where it was scrolled to. */
function fitToText(textarea: HTMLTextAreaElement): void {
  const scrollTop = textarea.scrollTop;
  // Collapse first so scrollHeight reports the text's height, not the box's.
  textarea.style.height = 'auto';
  // border-box sizing: the height includes the borders scrollHeight leaves out.
  const edges = textarea.offsetHeight - textarea.clientHeight;
  textarea.style.height = `${textarea.scrollHeight + edges}px`;
  textarea.scrollTop = scrollTop;
}

/**
 * Keeps a textarea exactly as tall as its text. The textarea's own CSS
 * `max-height` caps the growth; past it the text scrolls inside the box, so
 * pair this with `overflow-y-auto` and a max height.
 *
 * The height is recomputed when `value` changes and when the box changes
 * width (the window resizes, a side panel opens), since both change how many
 * lines the text wraps to.
 */
export function useAutoGrowTextarea(ref: RefObject<HTMLTextAreaElement>, value: string): void {
  useLayoutEffect(() => {
    const textarea = ref.current;
    if (textarea) fitToText(textarea);
  }, [ref, value]);

  useLayoutEffect(() => {
    const textarea = ref.current;
    if (!textarea || typeof ResizeObserver === 'undefined') return;
    let width = textarea.clientWidth;
    const observer = new ResizeObserver(() => {
      // Only a new width rewraps the text; the height set here is no reason to refit.
      if (textarea.clientWidth === width) return;
      width = textarea.clientWidth;
      fitToText(textarea);
    });
    observer.observe(textarea);
    return () => observer.disconnect();
  }, [ref]);
}
