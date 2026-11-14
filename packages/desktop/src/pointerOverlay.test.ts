import { describe, it, expect, vi } from 'vitest';

vi.mock('electron', () => ({ BrowserWindow: class {}, screen: { on: vi.fn(), removeListener: vi.fn(), getAllDisplays: () => [] } }));

import { sanitizeOverlayPointers, displayForSource, MAX_OVERLAY_POINTERS } from './pointerOverlay';

describe('sanitizeOverlayPointers', () => {
  it('keeps well-formed pointers', () => {
    const pointers = [{ id: 'bob', name: 'Bob', color: 'rgb(134 239 172)', x: 0.5, y: 0.25, idle: false, ping: 12 }];
    expect(sanitizeOverlayPointers(pointers)).toEqual(pointers);
  });

  it('drops entries outside the picture or without an id, and anything that is not a list', () => {
    expect(sanitizeOverlayPointers('nope')).toEqual([]);
    expect(sanitizeOverlayPointers([
      { id: 'a', x: 1.2, y: 0 },
      { id: '', x: 0, y: 0 },
      { x: 0, y: 0 },
      null,
      { id: 'b', x: Number.NaN, y: 0 },
    ])).toEqual([]);
  });

  it('replaces a colour that is not plain rgb, so nothing else reaches the page styles', () => {
    const [pointer] = sanitizeOverlayPointers([{ id: 'a', name: 'A', color: 'url(javascript:alert(1))', x: 0, y: 0 }]);
    expect(pointer!.color).toBe('rgb(232 188 104)');
  });

  it('bounds names and the number of pointers', () => {
    const many = Array.from({ length: MAX_OVERLAY_POINTERS + 5 }, (_, i) => ({ id: `p${i}`, name: 'x'.repeat(200), x: 0, y: 0 }));
    const out = sanitizeOverlayPointers(many);
    expect(out).toHaveLength(MAX_OVERLAY_POINTERS);
    expect(out[0]!.name).toHaveLength(64);
  });
});

describe('displayForSource', () => {
  const displays = [{ id: 1 }, { id: 2 }];

  it('finds the display a screen source shows', () => {
    expect(displayForSource({ id: 'screen:2:0', display_id: '2' }, displays)).toEqual({ id: 2 });
  });

  it('has no display for a window source', () => {
    expect(displayForSource({ id: 'window:42:0', display_id: '' }, displays)).toBeNull();
  });

  it('takes the only display when the source does not name one', () => {
    expect(displayForSource({ id: 'screen:0:0', display_id: '' }, [{ id: 7 }])).toEqual({ id: 7 });
    expect(displayForSource({ id: 'screen:0:0', display_id: '' }, displays)).toBeNull();
  });
});
