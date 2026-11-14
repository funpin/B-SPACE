import { beforeEach, describe, expect, it, vi, type Mock } from 'vitest';

const electron = vi.hoisted(() => {
  const handlers = new Map<string, (...args: unknown[]) => unknown>();
  // eslint-disable-next-line @typescript-eslint/no-use-before-define
  const windows: InstanceType<typeof FakeWindow>[] = [];
  class FakeWindow {
    destroyed = false;
    visible = true;
    options: Record<string, unknown>;
    listeners = new Map<string, () => void>();
    webContents = {
      send: vi.fn(),
      on: vi.fn(),
      setWindowOpenHandler: vi.fn(),
    };
    loadFile = vi.fn().mockResolvedValue(undefined);
    show = vi.fn();
    focus = vi.fn();
    removeMenu = vi.fn();
    close = vi.fn(() => {
      this.destroyed = true;
      this.listeners.get('closed')?.();
    });
    constructor(options: Record<string, unknown>) {
      this.options = options;
      windows.push(this);
    }
    isDestroyed() { return this.destroyed; }
    isVisible() { return this.visible; }
    once(event: string, listener: () => void) { this.listeners.set(event, listener); }
    on(event: string, listener: () => void) { this.listeners.set(event, listener); }
  }
  return {
    handlers,
    windows,
    FakeWindow,
    ipcMain: {
      handle: (channel: string, handler: (...args: unknown[]) => unknown) => handlers.set(channel, handler),
      on: (channel: string, handler: (...args: unknown[]) => unknown) => handlers.set(channel, handler),
    },
  };
});

vi.mock('electron', () => ({ BrowserWindow: electron.FakeWindow, ipcMain: electron.ipcMain }));

import { shouldCheckOnOpen, taskbarProgress, UpdateWindow, UPDATE_WINDOW_CHANNELS, type UpdateWindowDeps } from './updateWindow';
import type { UpdateSnapshot, UpdateStatus } from './updateStatus';

function snapshot(status: UpdateStatus, capability: UpdateSnapshot['capability'] = 'auto'): UpdateSnapshot {
  return { capability, dismissedVersion: null, status };
}

type TestDeps = UpdateWindowDeps & { check: Mock<() => void>; install: Mock<() => void>; openReleases: Mock<() => void> };

function deps(current: { snapshot: UpdateSnapshot }): TestDeps {
  return {
    getSnapshot: () => current.snapshot,
    currentVersion: () => '2.3.0',
    language: () => 'ru',
    check: vi.fn<() => void>(),
    install: vi.fn<() => void>(),
    openReleases: vi.fn<() => void>(),
    parent: () => null,
  };
}

beforeEach(() => {
  electron.handlers.clear();
  electron.windows.length = 0;
});

describe('shouldCheckOnOpen', () => {
  it('checks from a resting state, after a result and after a failure', () => {
    for (const status of [
      { phase: 'idle' },
      { phase: 'up-to-date', checkedAt: 1 },
      { phase: 'available', version: '2.4.0' },
      { phase: 'failed', version: null, message: 'offline' },
    ] as UpdateStatus[]) {
      expect(shouldCheckOnOpen(snapshot(status))).toBe(true);
    }
  });

  it('leaves a check, a download or a waiting restart alone', () => {
    expect(shouldCheckOnOpen(snapshot({ phase: 'checking' }))).toBe(false);
    expect(shouldCheckOnOpen(snapshot({ phase: 'downloading', version: '2.4.0', percent: 40, bytesPerSecond: 1 }))).toBe(false);
    expect(shouldCheckOnOpen(snapshot({ phase: 'ready', version: '2.4.0' }))).toBe(false);
  });

  it('never checks when the package manager owns updates', () => {
    expect(shouldCheckOnOpen(snapshot({ phase: 'idle' }, 'external'))).toBe(false);
  });
});

describe('taskbarProgress', () => {
  it('is the download fraction while downloading and -1 otherwise', () => {
    expect(taskbarProgress({ phase: 'downloading', version: '2.4.0', percent: 42, bytesPerSecond: 0 })).toBeCloseTo(0.42);
    expect(taskbarProgress({ phase: 'downloading', version: '2.4.0', percent: 140, bytesPerSecond: 0 })).toBe(1);
    expect(taskbarProgress({ phase: 'ready', version: '2.4.0' })).toBe(-1);
    expect(taskbarProgress({ phase: 'idle' })).toBe(-1);
  });
});

describe('UpdateWindow', () => {
  it('opens one sandboxed window in the app language and starts a check', () => {
    const state = { snapshot: snapshot({ phase: 'idle' }) };
    const d = deps(state);
    const window = new UpdateWindow(d);
    window.open();
    window.open();
    expect(electron.windows).toHaveLength(1);
    const created = electron.windows[0]!;
    expect(created.options.webPreferences).toMatchObject({ sandbox: true, contextIsolation: true, nodeIntegration: false });
    expect(created.loadFile).toHaveBeenCalledWith(expect.stringMatching(/resources[\\/]update\.html$/), { query: { lang: 'ru' } });
    expect(created.focus).toHaveBeenCalledOnce();
    expect(d.check).toHaveBeenCalledTimes(2);
  });

  it('does not restart a running download when opened', () => {
    const state = { snapshot: snapshot({ phase: 'downloading', version: '2.4.0', percent: 10, bytesPerSecond: 5 }) };
    const d = deps(state);
    new UpdateWindow(d).open();
    expect(d.check).not.toHaveBeenCalled();
  });

  it('pushes each state to the open window with the installed version', () => {
    const state = { snapshot: snapshot({ phase: 'idle' }) };
    const window = new UpdateWindow(deps(state));
    window.notify(state.snapshot); // nothing open yet: nothing to send
    window.open();
    const next = snapshot({ phase: 'ready', version: '2.4.0' });
    window.notify(next);
    expect(electron.windows[0]!.webContents.send).toHaveBeenCalledWith(UPDATE_WINDOW_CHANNELS.status, { snapshot: next, currentVersion: '2.3.0' });
  });

  it('answers only its own window', () => {
    const state = { snapshot: snapshot({ phase: 'ready', version: '2.4.0' }) };
    const d = deps(state);
    new UpdateWindow(d).open();
    const own = { sender: electron.windows[0]!.webContents };
    const stranger = { sender: {} };

    const get = electron.handlers.get(UPDATE_WINDOW_CHANNELS.get)!;
    expect(get(stranger)).toBeNull();
    expect(get(own)).toEqual({ snapshot: state.snapshot, currentVersion: '2.3.0' });

    electron.handlers.get(UPDATE_WINDOW_CHANNELS.install)!(stranger);
    expect(d.install).not.toHaveBeenCalled();
    electron.handlers.get(UPDATE_WINDOW_CHANNELS.install)!(own);
    expect(d.install).toHaveBeenCalledOnce();

    electron.handlers.get(UPDATE_WINDOW_CHANNELS.releases)!(own);
    expect(d.openReleases).toHaveBeenCalledOnce();
  });

  it('retries a failed check from the window, and forgets the window once closed', () => {
    const state = { snapshot: snapshot({ phase: 'failed', version: null, message: 'offline' }) };
    const d = deps(state);
    const window = new UpdateWindow(d);
    window.open();
    const own = { sender: electron.windows[0]!.webContents };
    electron.handlers.get(UPDATE_WINDOW_CHANNELS.check)!(own);
    expect(d.check).toHaveBeenCalledTimes(2);

    electron.handlers.get(UPDATE_WINDOW_CHANNELS.close)!(own);
    window.open();
    expect(electron.windows).toHaveLength(2);
  });
});
