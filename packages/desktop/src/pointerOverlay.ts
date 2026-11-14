/**
 * Stream pointers on the sharer's own screen.
 *
 * Viewers of a screen share can point at it (the web client's stream pointer,
 * see packages/web/src/utils/streamPointerProtocol.ts). Inside the app those
 * pointers are drawn on the stream tile; the sharer, though, is looking at
 * their real desktop, not at the tile. This draws the pointers there: a
 * transparent, click-through, always-on-top window over the display being
 * shared.
 *
 * - Only a whole-screen share has one: a shared window's position on the
 *   desktop is not something Electron can read for another application's
 *   window, so there is no rectangle to map the picture onto.
 * - The window is excluded from capture (`setContentProtection`), otherwise it
 *   would be captured into the share and every viewer would see each pointer
 *   twice — the drawn one and the captured one, a frame behind.
 * - It never takes focus or the mouse: pointing must not get in the way of
 *   whatever the sharer is doing.
 * - It is on every Space, the full-screen ones included (see
 *   `overlayWindowOptions`): a viewer keeps pointing at whatever the stream
 *   shows, and on macOS that can be an app the sharer swiped to full screen.
 *
 * The renderer owns the pointer state (who is pointing, idle fading, colours,
 * names) and sends the full list on every change; this module only validates
 * it and draws it.
 */
import {
  BrowserWindow,
  desktopCapturer,
  screen,
  type BrowserWindowConstructorOptions,
  type Display,
  type Rectangle,
  type VisibleOnAllWorkspacesOptions,
} from 'electron';

/** One pointer as the renderer sends it. Coordinates are fractions of the shared picture. */
export interface OverlayPointer {
  id: string;
  name: string;
  /** A CSS `rgb(…)` colour; anything else is replaced by the default. */
  color: string;
  x: number;
  y: number;
  /** Faded: the pointer has not moved for a while. */
  idle: boolean;
  /** Changes on every click, so the ring restarts. 0 draws none. */
  ping: number;
}

/** No call shows more pointers than this; it bounds the IPC payload's cost. */
export const MAX_OVERLAY_POINTERS = 32;
const MAX_NAME_LENGTH = 64;
const MAX_ID_LENGTH = 128;
const DEFAULT_COLOR = 'rgb(232 188 104)';
const RGB_PATTERN = /^rgb\(\s*\d{1,3}(?:\s*,\s*|\s+)\d{1,3}(?:\s*,\s*|\s+)\d{1,3}\s*\)$/;

function isFraction(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1;
}

/** The pointers in an untrusted IPC payload, or an empty list when it is not a list of them. */
export function sanitizeOverlayPointers(input: unknown): OverlayPointer[] {
  if (!Array.isArray(input)) return [];
  const pointers: OverlayPointer[] = [];
  for (const raw of input.slice(0, MAX_OVERLAY_POINTERS)) {
    if (typeof raw !== 'object' || raw === null) continue;
    const entry = raw as Record<string, unknown>;
    if (typeof entry.id !== 'string' || entry.id.length === 0 || entry.id.length > MAX_ID_LENGTH) continue;
    if (!isFraction(entry.x) || !isFraction(entry.y)) continue;
    const name = typeof entry.name === 'string' ? entry.name.slice(0, MAX_NAME_LENGTH) : '';
    const color = typeof entry.color === 'string' && RGB_PATTERN.test(entry.color) ? entry.color : DEFAULT_COLOR;
    const ping = typeof entry.ping === 'number' && Number.isFinite(entry.ping) && entry.ping > 0 ? entry.ping : 0;
    pointers.push({ id: entry.id, name, color, x: entry.x, y: entry.y, idle: entry.idle === true, ping });
  }
  return pointers;
}

/**
 * The display a `DesktopCapturerSource` shows, or null for a window source or
 * a screen Electron cannot place. Wayland's portal leaves `display_id` empty;
 * with a single display there is no doubt which one it is.
 */
export function displayForSource(
  source: { id: string; display_id?: string },
  displays: readonly Pick<Display, 'id'>[],
): Pick<Display, 'id'> | null {
  if (!source.id.startsWith('screen:')) return null;
  if (source.display_id) {
    return displays.find((display) => String(display.id) === source.display_id) ?? null;
  }
  return displays.length === 1 ? displays[0]! : null;
}

// Self-contained page: no network, no preload, no Node. `render` replaces the
// whole layer from the list main hands it; names go in as text, never markup.
const OVERLAY_HTML = `<!doctype html>
<html><head><meta charset="utf-8">
<style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;cursor:none;user-select:none}
.p{position:absolute;width:0;height:0;transition:left 90ms linear,top 90ms linear,opacity 300ms ease-out}
.p svg{position:absolute;left:0;top:0;filter:drop-shadow(0 1px 2px rgba(0,0,0,.45))}
.p span.n{position:absolute;left:17px;top:17px;padding:2px 7px;border-radius:6px;border-top-left-radius:3px;font:600 12px/1.35 Inter,system-ui,-apple-system,"Segoe UI",sans-serif;color:rgba(0,0,0,.82);white-space:nowrap}
.r{position:absolute;left:-14px;top:-14px;width:28px;height:28px;border-radius:50%;border:2px solid;box-sizing:border-box;animation:ring 700ms ease-out forwards}
@keyframes ring{from{transform:scale(.4);opacity:1}to{transform:scale(1.8);opacity:0}}
</style></head><body><script>
const marks=new Map();
let frame={x:0,y:0,w:0,h:0};
window.render=function(list,f){
  if(f)frame=f;
  const seen=new Set();
  for(const p of list){
    seen.add(p.id);
    let m=marks.get(p.id);
    if(!m){
      const el=document.createElement('div');el.className='p';
      const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');
      svg.setAttribute('width','22');svg.setAttribute('height','22');svg.setAttribute('viewBox','0 0 20 20');
      const path=document.createElementNS('http://www.w3.org/2000/svg','path');
      path.setAttribute('d','M2 1.5 16.5 8.2 10 10.2 7.6 16.8Z');path.setAttribute('stroke','rgba(0,0,0,0.65)');
      path.setAttribute('stroke-width','1.2');path.setAttribute('stroke-linejoin','round');
      svg.appendChild(path);
      const name=document.createElement('span');name.className='n';
      el.appendChild(svg);el.appendChild(name);document.body.appendChild(el);
      m={el,path,name,ping:0};marks.set(p.id,m);
    }
    m.el.style.left=(frame.x+p.x*frame.w)+'px';m.el.style.top=(frame.y+p.y*frame.h)+'px';
    m.el.style.opacity=p.idle?'0':'1';
    m.path.setAttribute('fill',p.color);
    m.name.style.backgroundColor=p.color;
    if(m.name.textContent!==p.name)m.name.textContent=p.name;
    if(p.ping&&p.ping!==m.ping){
      m.ping=p.ping;
      const ring=document.createElement('span');ring.className='r';ring.style.borderColor=p.color;
      ring.addEventListener('animationend',()=>ring.remove());
      m.el.insertBefore(ring,m.el.firstChild);
    }
  }
  for(const [id,m] of marks){if(!seen.has(id)){m.el.remove();marks.delete(id);}}
};
let probeEl=null;
window.probe=function(on,x,y,size){
  if(probeEl){probeEl.remove();probeEl=null;}
  if(!on)return;
  probeEl=document.createElement('div');
  probeEl.style.cssText='position:absolute;left:'+x+'px;top:'+y+'px;width:'+size+'px;height:'+size+'px;background:#ff00ff';
  document.body.appendChild(probeEl);
};
</script></body></html>`;

/**
 * The overlay window's options for `bounds` on `platform`.
 *
 * On macOS a full-screen app has a Space of its own, and an ordinary window
 * cannot join another application's full-screen Space, whatever its
 * collection behaviour, unless the whole app is an agent (no Dock icon, no
 * menu bar). A non-activating panel can: `type: 'panel'` makes Electron add
 * `NSWindowStyleMaskNonactivatingPanel` and always keep the
 * `CanJoinAllSpaces | FullScreenAuxiliary` collection behaviour, so the
 * overlay is on every Space the sharer swipes to, above a full-screen app.
 * Electron's panel is still an `NSWindow`, not an `NSPanel`, so it does not
 * hide when the app deactivates — which it is whenever the sharer works in
 * another app. `hiddenInMissionControl` (the `Transient` behaviour) keeps an
 * empty, screen-sized tile for it out of Mission Control.
 *
 * Windows and Linux have no such Spaces; their window stays a plain one.
 */
export function overlayWindowOptions(bounds: Rectangle, platform: NodeJS.Platform): BrowserWindowConstructorOptions {
  return {
    ...bounds,
    ...(platform === 'darwin' ? { type: 'panel', hiddenInMissionControl: true } : {}),
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    hasShadow: false,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    focusable: false,
    skipTaskbar: true,
    enableLargerThanScreen: true,
    webPreferences: {
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      javascript: true,
      spellcheck: false,
      backgroundThrottling: false,
    },
  };
}

/**
 * Every workspace, full-screen ones included. Without
 * `skipTransformProcessType`, `visibleOnFullScreen` makes Electron turn the
 * whole app into a UI element (`app.dock.hide()`): the Dock icon and the menu
 * bar vanish for as long as the app runs, and the asynchronous transform still
 * did not put an ordinary window onto a full-screen Space. The panel needs no
 * transform. Windows ignores the call; Linux reads only `visible`.
 */
export const OVERLAY_WORKSPACES: VisibleOnAllWorkspacesOptions = {
  visibleOnFullScreen: true,
  skipTransformProcessType: true,
};

/**
 * Owns the overlay window. `setTarget` says which display is being shared
 * (null when nothing, or a window, is); `update` draws the renderer's list.
 */
/**
 * Where the shared display sits inside the overlay window, in the page's CSS
 * pixels. Pointers are fractions of the display, not of the window: Windows
 * keeps a window off the taskbar, so the overlay can come out shorter than the
 * display, and a pointer placed as a percentage of the window then lands
 * higher the lower it is — exactly at the top, far off at the bottom.
 */
export interface OverlayFrame {
  x: number;
  y: number;
  w: number;
  h: number;
}

export function overlayFrame(display: Rectangle, windowBounds: Rectangle): OverlayFrame {
  return {
    x: display.x - windowBounds.x,
    y: display.y - windowBounds.y,
    w: display.width,
    h: display.height,
  };
}

/** Side of the probe square, in DIP: large enough to survive a quarter-size thumbnail. */
export const CAPTURE_PROBE_SIZE = 32;
/** Where the probe goes, in DIP from the display's top-left: clear of the corners' hot spots. */
export const CAPTURE_PROBE_OFFSET = 48;
/** The thumbnail is this fraction of the display: cheap, and the probe stays 8 px across. */
const PROBE_THUMBNAIL_SCALE = 0.25;
/** How long the probe is drawn before the screen is read: a couple of compositor frames. */
const PROBE_SETTLE_MS = 120;

/**
 * Whether a BGRA bitmap region shows the probe: most of its pixels close to
 * pure magenta. Scaling smears the edges, so the middle decides.
 */
export function bitmapShowsProbe(bgra: Buffer, width: number, height: number): boolean {
  if (width <= 0 || height <= 0 || bgra.length < width * height * 4) return false;
  let magenta = 0;
  let counted = 0;
  for (let y = Math.floor(height / 4); y < Math.ceil((height * 3) / 4); y++) {
    for (let x = Math.floor(width / 4); x < Math.ceil((width * 3) / 4); x++) {
      const i = (y * width + x) * 4;
      const b = bgra[i]!;
      const g = bgra[i + 1]!;
      const r = bgra[i + 2]!;
      counted++;
      if (r > 200 && b > 200 && g < 70) magenta++;
    }
  }
  return counted > 0 && magenta / counted >= 0.5;
}

const delay = (ms: number) => new Promise<void>((resolve) => { setTimeout(resolve, ms); });

export class PointerOverlay {
  private window: BrowserWindow | null = null;
  private ready: Promise<void> | null = null;
  private targetDisplayId: number | null = null;
  private latest: OverlayPointer[] = [];
  /** The window the capture check ran for; one check per window. */
  private probedWindow: BrowserWindow | null = null;
  private readonly onDisplaysChanged = (): void => this.placeOnTarget();

  /**
   * @param onCaptured Called once per overlay window with whether the share
   *   captures it after all. Windows can ignore the exclusion for this
   *   transparent, click-through (layered) window — Windows 10 does — and
   *   then every viewer sees each pointer in the picture as well.
   */
  constructor(private readonly onCaptured: (captured: boolean) => void = () => undefined) {
    screen.on('display-metrics-changed', this.onDisplaysChanged);
    screen.on('display-removed', this.onDisplaysChanged);
  }

  /** The display a new share captures, or null for a window share or a share that ended. */
  setTarget(displayId: number | null): void {
    this.targetDisplayId = displayId;
    if (displayId === null) {
      this.close();
      return;
    }
    this.placeOnTarget();
    this.draw();
  }

  update(input: unknown): void {
    this.latest = sanitizeOverlayPointers(input);
    this.draw();
  }

  /** Nothing to point at for now: removes the window, keeping the target display. */
  close(): void {
    this.latest = [];
    const win = this.window;
    this.window = null;
    this.ready = null;
    if (win && !win.isDestroyed()) win.destroy();
  }

  dispose(): void {
    screen.removeListener('display-metrics-changed', this.onDisplaysChanged);
    screen.removeListener('display-removed', this.onDisplaysChanged);
    this.close();
  }

  private targetDisplay(): Display | null {
    if (this.targetDisplayId === null) return null;
    return screen.getAllDisplays().find((display) => display.id === this.targetDisplayId) ?? null;
  }

  private placeOnTarget(): void {
    const display = this.targetDisplay();
    if (!display) {
      // The shared display went away (unplugged): hide rather than draw on another.
      this.close();
      return;
    }
    if (this.window && !this.window.isDestroyed()) {
      this.window.setBounds(display.bounds);
      this.draw();
    }
  }

  private ensureWindow(display: Display): { win: BrowserWindow; ready: Promise<void> } {
    if (this.window && !this.window.isDestroyed() && this.ready) {
      return { win: this.window, ready: this.ready };
    }
    const win = new BrowserWindow(overlayWindowOptions(display.bounds, process.platform));
    // Above full-screen apps and every other window, on every Space.
    win.setAlwaysOnTop(true, 'screen-saver');
    win.setVisibleOnAllWorkspaces(true, OVERLAY_WORKSPACES);
    // Clicks and the wheel go through to whatever is underneath.
    win.setIgnoreMouseEvents(true);
    // Not captured, so the share does not carry a second copy of each pointer.
    win.setContentProtection(true);
    // The page never navigates; anything that tries is refused.
    win.webContents.on('will-navigate', (event) => event.preventDefault());
    win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    win.on('closed', () => {
      if (this.window === win) {
        this.window = null;
        this.ready = null;
      }
    });

    const ready = win.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(OVERLAY_HTML)}`).catch((err: unknown) => {
      console.warn('[Main:PointerOverlay] Failed to load the overlay:', err);
    });
    this.window = win;
    this.ready = ready;
    return { win, ready };
  }

  private draw(): void {
    const display = this.targetDisplay();
    if (!display) return;
    if (this.latest.length === 0 && !this.window) return;

    const { win, ready } = this.ensureWindow(display);
    const list = this.latest;
    void ready.then(() => {
      if (win.isDestroyed() || this.window !== win) return;
      if (list.length > 0 && !win.isVisible()) {
        win.showInactive();
        // Windows may have kept the window off the taskbar when it was made;
        // shown and on top it can take the whole display.
        win.setBounds(display.bounds);
      } else if (list.length === 0 && win.isVisible()) {
        win.hide();
      }
      const frame = overlayFrame(display.bounds, win.getBounds());
      // JSON is a JavaScript expression; the list has been validated field by field.
      void win.webContents.executeJavaScript(`window.render(${JSON.stringify(list)},${JSON.stringify(frame)})`).catch(() => { });
      if (list.length > 0 && this.probedWindow !== win) {
        this.probedWindow = win;
        void this.checkCaptureExclusion(win, display);
      }
    });
  }

  /**
   * Draws a small magenta square on the overlay for a moment and looks at the
   * screen as a capture sees it. If the square is there, the exclusion did not
   * take and the share carries the overlay. Windows only: macOS honours
   * `setContentProtection` for this window.
   */
  private async checkCaptureExclusion(win: BrowserWindow, display: Display): Promise<void> {
    if (process.platform !== 'win32') return;
    try {
      const bounds = win.getBounds();
      const x = display.bounds.x - bounds.x + CAPTURE_PROBE_OFFSET;
      const y = display.bounds.y - bounds.y + CAPTURE_PROBE_OFFSET;
      await win.webContents.executeJavaScript(`window.probe(true,${x},${y},${CAPTURE_PROBE_SIZE})`);
      await delay(PROBE_SETTLE_MS);
      const width = Math.max(1, Math.round(display.bounds.width * PROBE_THUMBNAIL_SCALE));
      const height = Math.max(1, Math.round(display.bounds.height * PROBE_THUMBNAIL_SCALE));
      const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width, height } });
      if (!win.isDestroyed()) void win.webContents.executeJavaScript('window.probe(false)').catch(() => { });
      const source = sources.find((candidate) => candidate.display_id === String(display.id))
        ?? (sources.length === 1 ? sources[0] : undefined);
      if (!source || source.thumbnail.isEmpty()) return;
      const thumb = source.thumbnail.getSize();
      const scaleX = thumb.width / display.bounds.width;
      const scaleY = thumb.height / display.bounds.height;
      const region = source.thumbnail.crop({
        x: Math.round(CAPTURE_PROBE_OFFSET * scaleX),
        y: Math.round(CAPTURE_PROBE_OFFSET * scaleY),
        width: Math.max(1, Math.round(CAPTURE_PROBE_SIZE * scaleX)),
        height: Math.max(1, Math.round(CAPTURE_PROBE_SIZE * scaleY)),
      });
      const size = region.getSize();
      const captured = bitmapShowsProbe(region.toBitmap(), size.width, size.height);
      if (captured) console.warn('[Main:PointerOverlay] The share captures the overlay; viewers are told to stop drawing pointers over it');
      if (this.window === win) this.onCaptured(captured);
    } catch (err) {
      console.warn('[Main:PointerOverlay] Capture check failed:', err);
      if (!win.isDestroyed()) void win.webContents.executeJavaScript('window.probe(false)').catch(() => { });
    }
  }
}
