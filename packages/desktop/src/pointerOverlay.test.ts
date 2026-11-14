import { describe, it, expect, vi, beforeEach } from 'vitest';

const electron = vi.hoisted(() => {
  /** Records what the overlay does to its window; nothing native is created. */
  class FakeWindow {
    static created: FakeWindow[] = [];
    readonly calls: { method: string; args: unknown[] }[] = [];
    readonly webContents = {
      on: (): void => { },
      setWindowOpenHandler: (): void => { },
      executeJavaScript: (): Promise<void> => Promise.resolve(),
    };
    private visible = false;
    private destroyed = false;

    constructor(readonly options: Record<string, unknown>) {
      FakeWindow.created.push(this);
    }

    private record(method: string, args: unknown[]): void {
      this.calls.push({ method, args });
    }

    setAlwaysOnTop(...args: unknown[]): void { this.record('setAlwaysOnTop', args); }
    setVisibleOnAllWorkspaces(...args: unknown[]): void { this.record('setVisibleOnAllWorkspaces', args); }
    setIgnoreMouseEvents(...args: unknown[]): void { this.record('setIgnoreMouseEvents', args); }
    setContentProtection(...args: unknown[]): void { this.record('setContentProtection', args); }
    setBounds(...args: unknown[]): void { this.record('setBounds', args); }
    loadURL(): Promise<void> { return Promise.resolve(); }
    on(): void { }
    isDestroyed(): boolean { return this.destroyed; }
    destroy(): void { this.destroyed = true; }
    isVisible(): boolean { return this.visible; }
    showInactive(): void { this.visible = true; this.record('showInactive', []); }
    show(): void { this.visible = true; this.record('show', []); }
    focus(): void { this.record('focus', []); }
    hide(): void { this.visible = false; this.record('hide', []); }
  }
  const display = { id: 7, bounds: { x: 0, y: 0, width: 1512, height: 982 } };
  return {
    FakeWindow,
    display,
    screen: { on: vi.fn(), removeListener: vi.fn(), getAllDisplays: vi.fn(() => [display]) },
  };
});

vi.mock('electron', () => ({ BrowserWindow: electron.FakeWindow, screen: electron.screen }));

import {
  sanitizeOverlayPointers,
  displayForSource,
  overlayWindowOptions,
  OVERLAY_WORKSPACES,
  MAX_OVERLAY_POINTERS,
  PointerOverlay,
} from './pointerOverlay';

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

describe('overlayWindowOptions', () => {
  const bounds = { x: 10, y: 20, width: 1920, height: 1080 };

  it('makes a non-activating panel on macOS, the only window kind that joins another app\'s full-screen Space', () => {
    const options = overlayWindowOptions(bounds, 'darwin');
    expect(options.type).toBe('panel');
    expect(options.hiddenInMissionControl).toBe(true);
  });

  it('keeps the plain window type on Windows and Linux', () => {
    for (const platform of ['win32', 'linux'] as const) {
      const options = overlayWindowOptions(bounds, platform);
      expect(options.type).toBeUndefined();
      expect(options.hiddenInMissionControl).toBeUndefined();
    }
  });

  it('covers the display and never takes focus, shows itself or shows in the taskbar', () => {
    for (const platform of ['darwin', 'win32', 'linux'] as const) {
      expect(overlayWindowOptions(bounds, platform)).toMatchObject({
        ...bounds,
        show: false,
        frame: false,
        transparent: true,
        focusable: false,
        skipTaskbar: true,
        webPreferences: { sandbox: true, contextIsolation: true, nodeIntegration: false },
      });
    }
  });
});

describe('PointerOverlay window', () => {
  const pointer = { id: 'bob', name: 'Bob', color: 'rgb(134 239 172)', x: 0.5, y: 0.5, idle: false, ping: 0 };

  beforeEach(() => {
    electron.FakeWindow.created.length = 0;
  });

  async function openOverlay(): Promise<InstanceType<typeof electron.FakeWindow>> {
    const overlay = new PointerOverlay();
    overlay.setTarget(electron.display.id);
    overlay.update([pointer]);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(electron.FakeWindow.created).toHaveLength(1);
    return electron.FakeWindow.created[0]!;
  }

  it('joins every Space and full-screen app without turning the app into a dock-less agent', async () => {
    expect(OVERLAY_WORKSPACES).toEqual({ visibleOnFullScreen: true, skipTransformProcessType: true });
    const win = await openOverlay();
    expect(win.calls).toContainEqual({ method: 'setVisibleOnAllWorkspaces', args: [true, OVERLAY_WORKSPACES] });
    expect(win.calls).toContainEqual({ method: 'setAlwaysOnTop', args: [true, 'screen-saver'] });
  });

  it('stays click-through, out of the capture, and is shown without activating', async () => {
    const win = await openOverlay();
    expect(win.options).toMatchObject(electron.display.bounds);
    expect(win.calls).toContainEqual({ method: 'setIgnoreMouseEvents', args: [true] });
    expect(win.calls).toContainEqual({ method: 'setContentProtection', args: [true] });
    const shown = win.calls.map((call) => call.method).filter((method) => ['showInactive', 'show', 'focus'].includes(method));
    expect(shown).toEqual(['showInactive']);
  });
});
