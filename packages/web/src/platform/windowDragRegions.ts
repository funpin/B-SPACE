/**
 * Tells the native macOS shell which parts of the page drag the window.
 *
 * Electron reads `-webkit-app-region` from the style sheet (`.titlebar-drag`
 * and `.titlebar-no-drag` in globals.css). A WKWebView does not know the
 * property and drops it, so for that shell the elements carrying the same two
 * classes are measured and reported through `window.backspace.setDragRegions`,
 * a member only it has. In Electron and in a browser the member is absent and
 * nothing here runs.
 *
 * Rectangles are what `getBoundingClientRect()` gives: visual pixels from the
 * top left corner of the viewport, the interface scale already applied.
 */

const DRAG_CLASS = 'titlebar-drag';
const NO_DRAG_CLASS = 'titlebar-no-drag';
const MARKED = `.${DRAG_CLASS}, .${NO_DRAG_CLASS}`;

/** A fractional scale leaves noise far below a pixel; it is not a change. */
function round(value: number): number {
  return Math.round(value * 100) / 100;
}

function measure(elements: Iterable<Element>): WindowDragRegions {
  const regions: WindowDragRegions = { drag: [], noDrag: [] };
  for (const element of elements) {
    const box = element.getBoundingClientRect();
    // An element that is not laid out (hidden, detached) drags nothing.
    if (box.width <= 0 || box.height <= 0) continue;
    const rect = { x: round(box.x), y: round(box.y), width: round(box.width), height: round(box.height) };
    // Marked both ways, the exception wins, as it does where they overlap.
    (element.classList.contains(NO_DRAG_CLASS) ? regions.noDrag : regions.drag).push(rect);
  }
  return regions;
}

function isOrHoldsMarked(node: Node): boolean {
  return node instanceof Element && (node.matches(MARKED) || node.querySelector(MARKED) !== null);
}

/** Whether these changes to the document could have changed the regions. */
function touchesMarked(records: MutationRecord[]): boolean {
  return records.some((record) => {
    if (record.type === 'attributes') {
      // The class may have just been taken off: look at what it was, too.
      const before = (record.oldValue ?? '').split(/\s+/);
      return isOrHoldsMarked(record.target) || before.includes(DRAG_CLASS) || before.includes(NO_DRAG_CLASS);
    }
    return [...record.addedNodes, ...record.removedNodes].some(isOrHoldsMarked);
  });
}

/**
 * Starts reporting and returns the function that stops it. The regions are
 * measured at once, and again when a marked element appears, goes away or
 * changes size, and when the window is resized; they are sent only when they
 * differ from what was sent last.
 */
export function reportWindowDragRegions(): () => void {
  const bridge = window.backspace;
  if (typeof bridge?.setDragRegions !== 'function') return () => {};
  const send = bridge.setDragRegions.bind(bridge);

  const observed = new Set<Element>();
  let sent: string | null = null;
  let frame: number | null = null;

  const update = (): void => {
    const marked = new Set(document.querySelectorAll(MARKED));
    for (const element of observed) {
      if (!marked.has(element)) {
        sizes.unobserve(element);
        observed.delete(element);
      }
    }
    for (const element of marked) {
      if (!observed.has(element)) {
        sizes.observe(element);
        observed.add(element);
      }
    }
    const regions = measure(marked);
    const next = JSON.stringify(regions);
    if (next === sent) return;
    sent = next;
    send(regions);
  };

  // One measurement per frame, however many things asked for it.
  const schedule = (): void => {
    if (frame !== null) return;
    frame = requestAnimationFrame(() => {
      frame = null;
      update();
    });
  };

  const sizes = new ResizeObserver(schedule);
  const structure = new MutationObserver((records) => {
    if (touchesMarked(records)) schedule();
  });
  structure.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['class'],
    attributeOldValue: true,
  });
  // A region can move without changing size; the interface scale also
  // announces itself with this event (interfaceScale.ts).
  window.addEventListener('resize', schedule);
  update();

  return () => {
    if (frame !== null) cancelAnimationFrame(frame);
    frame = null;
    sizes.disconnect();
    structure.disconnect();
    window.removeEventListener('resize', schedule);
  };
}
