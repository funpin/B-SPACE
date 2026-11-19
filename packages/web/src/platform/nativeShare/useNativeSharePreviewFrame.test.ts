import { afterEach, describe, expect, it } from 'vitest';
import { previewBoxOf } from './useNativeSharePreviewFrame';

/** The box the native shell is told to put its live preview over. */

function element(rect: Partial<DOMRect>, radius = ''): { box: HTMLElement; frame: HTMLElement } {
  const frame = document.createElement('div');
  frame.style.borderTopLeftRadius = radius;
  const box = document.createElement('video');
  frame.appendChild(box);
  document.body.appendChild(frame);
  const whole = { left: 0, top: 0, width: 0, height: 0, right: 0, bottom: 0, x: 0, y: 0, ...rect } as DOMRect;
  box.getBoundingClientRect = () => ({
    ...whole, right: whole.left + whole.width, bottom: whole.top + whole.height, toJSON: () => whole,
  });
  return { box, frame };
}

afterEach(() => { document.body.innerHTML = ''; });

describe('the preview\'s box', () => {
  it('is the element as the page measures it, with the corners of the frame that clips it', () => {
    const { box } = element({ left: 120, top: 400, width: 176, height: 99 }, '10px');
    expect(previewBoxOf(box, null)).toEqual({ x: 120, y: 400, width: 176, height: 99, radius: 10 });
  });

  it('has square corners when its frame has none', () => {
    const { box } = element({ left: 0, top: 0, width: 100, height: 50 });
    expect(previewBoxOf(box, null)?.radius).toBe(0);
  });

  it('is nothing for an element that is not there, has no size, or is out of the page', () => {
    expect(previewBoxOf(null, null)).toBeNull();
    expect(previewBoxOf(element({ left: 10, top: 10, width: 0, height: 99 }).box, null)).toBeNull();
    const { box, frame } = element({ left: 10, top: 10, width: 100, height: 50 });
    frame.remove();
    expect(previewBoxOf(box, null)).toBeNull();
  });

  it('is nothing while something of the page lies over it', () => {
    const { box } = element({ left: 100, top: 100, width: 200, height: 100 });
    const over = element({ left: 250, top: 50, width: 400, height: 400 }).box;
    const beside = element({ left: 300, top: 100, width: 400, height: 400 }).box;
    expect(previewBoxOf(box, over)).toBeNull();
    expect(previewBoxOf(box, beside)).not.toBeNull();
  });
});
