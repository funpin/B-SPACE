import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { reportWindowDragRegions } from './windowDragRegions';

interface Rect { x: number; y: number; width: number; height: number }

const STRIP: Rect = { x: 0, y: 0, width: 1280, height: 33 };

let frames: Array<FrameRequestCallback | undefined> = [];
let sizeObservers: FakeResizeObserver[] = [];
const teardowns: Array<() => void> = [];

class FakeResizeObserver {
  readonly observed = new Set<Element>();
  disconnected = false;
  constructor(readonly callback: () => void) { sizeObservers.push(this); }
  observe(element: Element): void { this.observed.add(element); }
  unobserve(element: Element): void { this.observed.delete(element); }
  disconnect(): void { this.disconnected = true; this.observed.clear(); }
}

function place(element: Element, rect: Rect): void {
  element.getBoundingClientRect = () => ({
    ...rect, top: rect.y, left: rect.x, right: rect.x + rect.width, bottom: rect.y + rect.height, toJSON: () => rect,
  });
}

function mark(className: string, rect: Rect): HTMLElement {
  const element = document.createElement('div');
  element.className = className;
  place(element, rect);
  document.body.append(element);
  return element;
}

/** Runs the animation frames asked for so far. */
function runFrames(): void {
  // A cancelled frame leaves a hole.
  for (const frame of frames.splice(0)) frame?.(0);
}

/** Lets the mutation observer deliver, then runs the frame it asked for. */
async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
  runFrames();
}

function shell(): ReturnType<typeof vi.fn<(regions: WindowDragRegions) => void>> {
  const setDragRegions = vi.fn<(regions: WindowDragRegions) => void>();
  window.backspace = { setDragRegions } as unknown as BackspaceElectronAPI;
  return setDragRegions;
}

function start(): () => void {
  const stop = reportWindowDragRegions();
  teardowns.push(stop);
  return stop;
}

beforeEach(() => {
  frames = [];
  sizeObservers = [];
  vi.stubGlobal('ResizeObserver', FakeResizeObserver);
  vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => frames.push(callback));
  vi.stubGlobal('cancelAnimationFrame', (handle: number) => { frames[handle - 1] = undefined; });
});

afterEach(() => {
  for (const teardown of teardowns.splice(0)) teardown();
  document.body.replaceChildren();
  delete window.backspace;
  vi.unstubAllGlobals();
});

describe('window drag regions', () => {
  it('does nothing in a browser and in Electron, which have no such member', () => {
    mark('titlebar-drag', STRIP);
    start();
    window.backspace = { platform: 'darwin' } as unknown as BackspaceElectronAPI;
    start();
    expect(sizeObservers).toHaveLength(0);
    expect(frames).toHaveLength(0);
  });

  it('reports the marked elements as soon as it starts', () => {
    const setDragRegions = shell();
    mark('flex-shrink-0 titlebar-drag', STRIP);
    mark('titlebar-no-drag', { x: 1200, y: 4, width: 60, height: 24 });
    mark('unrelated', { x: 0, y: 40, width: 1280, height: 700 });
    start();
    expect(setDragRegions).toHaveBeenCalledTimes(1);
    expect(setDragRegions).toHaveBeenCalledWith({
      drag: [STRIP],
      noDrag: [{ x: 1200, y: 4, width: 60, height: 24 }],
    });
  });

  it('reports that there is nothing to drag by', () => {
    const setDragRegions = shell();
    start();
    expect(setDragRegions).toHaveBeenCalledWith({ drag: [], noDrag: [] });
  });

  it('leaves out an element that is not laid out, and counts one marked both ways as an exception', () => {
    const setDragRegions = shell();
    mark('titlebar-drag', { x: 0, y: 0, width: 0, height: 0 });
    mark('titlebar-drag titlebar-no-drag', { x: 10, y: 4, width: 20, height: 20 });
    start();
    expect(setDragRegions).toHaveBeenCalledWith({ drag: [], noDrag: [{ x: 10, y: 4, width: 20, height: 20 }] });
  });

  it('rounds away the noise of a fractional scale', () => {
    const setDragRegions = shell();
    mark('titlebar-drag', { x: 0, y: 0, width: 1280.0000001, height: 32.999999 });
    start();
    expect(setDragRegions).toHaveBeenCalledWith({ drag: [STRIP], noDrag: [] });
  });

  it('reports again when a marked element changes size', () => {
    const setDragRegions = shell();
    const strip = mark('titlebar-drag', STRIP);
    start();
    expect(sizeObservers[0]?.observed.has(strip)).toBe(true);

    place(strip, { ...STRIP, width: 1600 });
    sizeObservers[0]?.callback();
    sizeObservers[0]?.callback();
    expect(frames).toHaveLength(1);
    runFrames();
    expect(setDragRegions).toHaveBeenCalledTimes(2);
    expect(setDragRegions).toHaveBeenLastCalledWith({ drag: [{ ...STRIP, width: 1600 }], noDrag: [] });
  });

  it('says nothing when the window resizes and the regions stay where they were', () => {
    const setDragRegions = shell();
    mark('titlebar-drag', STRIP);
    start();
    window.dispatchEvent(new Event('resize'));
    runFrames();
    expect(setDragRegions).toHaveBeenCalledTimes(1);
  });

  it('follows an element that appears later, inside something else, and one that goes away', async () => {
    const setDragRegions = shell();
    start();

    const wrapper = document.createElement('section');
    const strip = document.createElement('div');
    strip.className = 'titlebar-drag';
    place(strip, STRIP);
    wrapper.append(strip);
    document.body.append(wrapper);
    await settle();
    expect(setDragRegions).toHaveBeenLastCalledWith({ drag: [STRIP], noDrag: [] });
    expect(sizeObservers[0]?.observed.has(strip)).toBe(true);

    wrapper.remove();
    await settle();
    expect(setDragRegions).toHaveBeenLastCalledWith({ drag: [], noDrag: [] });
    expect(sizeObservers[0]?.observed.has(strip)).toBe(false);
    expect(setDragRegions).toHaveBeenCalledTimes(3);
  });

  it('follows a class put on an element, or taken off it, later', async () => {
    const setDragRegions = shell();
    const button = mark('toolbar-button', { x: 1200, y: 4, width: 60, height: 24 });
    mark('titlebar-drag', STRIP);
    start();

    button.classList.add('titlebar-no-drag');
    await settle();
    expect(setDragRegions).toHaveBeenLastCalledWith({ drag: [STRIP], noDrag: [{ x: 1200, y: 4, width: 60, height: 24 }] });

    button.classList.remove('titlebar-no-drag');
    await settle();
    expect(setDragRegions).toHaveBeenLastCalledWith({ drag: [STRIP], noDrag: [] });
  });

  it('does not measure for changes that have nothing marked in them', async () => {
    shell();
    const strip = mark('titlebar-drag', STRIP);
    start();

    const message = document.createElement('p');
    message.textContent = 'hello';
    document.body.append(message);
    message.className = 'message is-new';
    strip.setAttribute('data-state', 'idle');
    message.remove();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(frames).toHaveLength(0);
  });

  it('stops when told to', async () => {
    const setDragRegions = shell();
    const strip = mark('titlebar-drag', STRIP);
    const stop = start();
    window.dispatchEvent(new Event('resize'));
    stop();

    expect(sizeObservers[0]?.disconnected).toBe(true);
    place(strip, { ...STRIP, width: 900 });
    runFrames();
    window.dispatchEvent(new Event('resize'));
    mark('titlebar-no-drag', { x: 1, y: 1, width: 5, height: 5 });
    await settle();
    expect(setDragRegions).toHaveBeenCalledTimes(1);
  });
});
