import { BrowserWindow, ipcMain, type IpcMainEvent, type IpcMainInvokeEvent } from 'electron';
import path from 'path';
import type { DesktopLanguage } from './l10n';
import type { UpdateSnapshot, UpdateStatus } from './updateStatus';

/**
 * The update window: what the user sees after choosing "Check for Updates…"
 * in the tray or the app menu. It follows the updater live: checking, up to
 * date, the download with its progress and speed, then a Restart button
 * (resources/update.html).
 *
 * It belongs to the desktop app, not to the web client, so it works the same
 * whatever version the connected instance serves, and on the instance picker
 * and the recovery page too.
 */

/** What the page asks for when it loads and receives on every change. */
export interface UpdateWindowState {
  snapshot: UpdateSnapshot;
  currentVersion: string;
}

export interface UpdateWindowDeps {
  getSnapshot: () => UpdateSnapshot;
  currentVersion: () => string;
  language: () => DesktopLanguage;
  /** Starts a check through the same path as the menus. */
  check: () => void;
  /** Quits and installs the downloaded update (or opens the download page on a manual build). */
  install: () => void;
  openReleases: () => void;
  /** The window it is centred over, when there is one. */
  parent: () => BrowserWindow | null;
}

/** IPC channels, all scoped to the update window's own webContents. */
export const UPDATE_WINDOW_CHANNELS = {
  get: 'update-window:get',
  status: 'update-window:status',
  check: 'update-window:check',
  install: 'update-window:install',
  releases: 'update-window:releases',
  close: 'update-window:close',
} as const;

/**
 * Whether opening the window should also start a check. Not while a download
 * runs or waits for a restart: a new check would throw the user's progress
 * back to "Checking…" for nothing. Not on a build whose updates the package
 * manager owns.
 */
export function shouldCheckOnOpen(snapshot: UpdateSnapshot): boolean {
  if (snapshot.capability === 'external') return false;
  const busy: ReadonlyArray<UpdateStatus['phase']> = ['checking', 'downloading', 'ready'];
  return !busy.includes(snapshot.status.phase);
}

/** The dock / taskbar progress for a status: a fraction while downloading, -1 (none) otherwise. */
export function taskbarProgress(status: UpdateStatus): number {
  if (status.phase !== 'downloading') return -1;
  return Math.max(0, Math.min(1, status.percent / 100));
}

const WIDTH = 420;
const HEIGHT = 248;

export class UpdateWindow {
  private window: BrowserWindow | null = null;
  private handlersRegistered = false;

  constructor(private readonly deps: UpdateWindowDeps) {}

  /** Opens the window, or brings it to the front, and checks when that makes sense. */
  open(): void {
    this.registerHandlers();
    const snapshot = this.deps.getSnapshot();
    if (this.window && !this.window.isDestroyed()) {
      this.window.show();
      this.window.focus();
    } else {
      this.window = this.create();
    }
    if (shouldCheckOnOpen(snapshot)) this.deps.check();
  }

  /** Pushes the updater's state to the window, if it is open. */
  notify(snapshot: UpdateSnapshot): void {
    if (!this.window || this.window.isDestroyed()) return;
    const state: UpdateWindowState = { snapshot, currentVersion: this.deps.currentVersion() };
    this.window.webContents.send(UPDATE_WINDOW_CHANNELS.status, state);
  }

  private create(): BrowserWindow {
    const parent = this.deps.parent();
    const window = new BrowserWindow({
      width: WIDTH,
      height: HEIGHT,
      useContentSize: true,
      resizable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      show: false,
      title: 'B:SPACE',
      titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
      autoHideMenuBar: true,
      backgroundColor: '#0c0c0e',
      ...(parent && !parent.isDestroyed() && parent.isVisible() ? { parent } : {}),
      webPreferences: {
        preload: path.join(__dirname, 'updatePreload.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
      },
    });
    window.removeMenu();
    // A local page with nothing to link out to: every navigation and pop-up is refused.
    window.webContents.on('will-navigate', (event) => event.preventDefault());
    window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    window.once('ready-to-show', () => window.show());
    window.on('closed', () => {
      if (this.window === window) this.window = null;
    });
    void window.loadFile(path.join(__dirname, '..', 'resources', 'update.html'), {
      query: { lang: this.deps.language() },
    });
    return window;
  }

  private fromThisWindow(event: IpcMainEvent | IpcMainInvokeEvent): boolean {
    return this.window !== null && !this.window.isDestroyed() && event.sender === this.window.webContents;
  }

  private registerHandlers(): void {
    if (this.handlersRegistered) return;
    this.handlersRegistered = true;
    ipcMain.handle(UPDATE_WINDOW_CHANNELS.get, (event): UpdateWindowState | null => {
      if (!this.fromThisWindow(event)) return null;
      return { snapshot: this.deps.getSnapshot(), currentVersion: this.deps.currentVersion() };
    });
    ipcMain.on(UPDATE_WINDOW_CHANNELS.check, (event) => {
      if (this.fromThisWindow(event) && shouldCheckOnOpen(this.deps.getSnapshot())) this.deps.check();
    });
    ipcMain.on(UPDATE_WINDOW_CHANNELS.install, (event) => {
      if (this.fromThisWindow(event)) this.deps.install();
    });
    ipcMain.on(UPDATE_WINDOW_CHANNELS.releases, (event) => {
      if (this.fromThisWindow(event)) this.deps.openReleases();
    });
    ipcMain.on(UPDATE_WINDOW_CHANNELS.close, (event) => {
      if (this.fromThisWindow(event)) this.window?.close();
    });
  }
}
