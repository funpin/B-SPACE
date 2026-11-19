/** Type augmentation for the Electron IPC bridge exposed by preload.ts */

// Recovery mode types (Task 11)
type RecoveryReasonCode = 'load-failed' | 'render-gone' | 'unresponsive' | 'renderer-stalled';
// 'available-manual': an update exists but this build cannot install it in
// place, so the recovery surface offers a download rather than a Restart button
// that would do nothing. See packages/desktop/src/updateCapability.ts.
type UpdateState =
  | 'idle'
  | 'checking'
  | 'downloading'
  | 'available-manual'
  | 'external'
  | 'downloaded'
  | 'error';
interface RecoveryState {
  mode: 'normal' | 'recovery';
  reason: { code: RecoveryReasonCode; detail: string } | null;
  updateState: UpdateState;
  updateVersion: string | null;
  lastUpdateError: { message: string; code: string | null; at: number } | null;
  lastCheckResult: 'up-to-date' | 'failed' | null;
}
/** A rectangle of the viewport, as `getBoundingClientRect()` gives it. */
interface WindowDragRect {
  x: number;
  y: number;
  width: number;
  height: number;
}
/** Where the window is dragged by, and the exceptions inside those parts. */
interface WindowDragRegions {
  drag: WindowDragRect[];
  noDrag: WindowDragRect[];
}
type RecoveryAction =
  | 'reload'
  | 'check-update'
  | 'install-update'
  | 'change-instance'
  | 'open-releases'
  | 'quit';

/**
 * Whether a System Audio share on this OS build carries Backspace's own
 * playback to viewers. See packages/desktop/src/systemAudioCapability.ts.
 */
type OwnAudioInSystemAudio = 'excluded' | 'included' | 'unavailable' | 'unknown';

interface ElectronScreenSource {
  id: string;                      // "screen:0:0" or "window:12345:0"
  name: string;                    // "Entire Screen" or "Firefox"
  thumbnailDataUrl: string;        // PNG data URL at 320×180
  appIconDataUrl: string | null;   // App icon (windows only)
  isScreen: boolean;               // true = display, false = window
}

/**
 * Where the desktop updater currently is.
 *
 * Declared without `export` on purpose: this file is a global ambient
 * declaration that augments `interface Window`. A single `export` would turn it
 * into a module and drop that augmentation across the whole package.
 *
 * Mirrors `UpdateStatus` in `packages/desktop/src/updateStatus.ts`. The two are
 * separate declarations on purpose: this is a wire contract across a process
 * boundary between two packages that ship and version independently, and the
 * web client must not take a build dependency on the Electron package. The
 * runtime guard in `updateStore.ts` is what keeps them honest.
 */
type DesktopUpdateStatus =
  | { phase: 'idle' }
  | { phase: 'checking' }
  | { phase: 'available'; version: string }
  | { phase: 'downloading'; version: string; percent: number; bytesPerSecond: number }
  | { phase: 'ready'; version: string }
  | { phase: 'failed'; version: string | null; message: string }
  | { phase: 'up-to-date'; checkedAt: number };

/**
 * `auto` means this build can install its own updates. `manual` means it cannot
 * and the user has to download a new build, which is the case for ad-hoc signed
 * macOS builds. The renderer never reasons about code signing; it reads this.
 */
type DesktopUpdateCapability = 'auto' | 'manual' | 'external';

interface DesktopUpdateSnapshot {
  capability: DesktopUpdateCapability;
  dismissedVersion: string | null;
  status: DesktopUpdateStatus;
}

interface BackspaceElectronAPI {
  // Platform info
  platform: NodeJS.Platform;
  // Window controls
  minimize: () => void;
  maximize: () => void;
  close: () => void;

  // Notifications & badge
  showNotification: (title: string, body: string, options?: import('./notifications').NotificationOptions) => void;
  onNotificationClick?: (callback: (options: import('./notifications').NotificationOptions) => void) => () => void;
  setBadgeCount: (count: number) => void;
  /** Absent on desktop builds older than the tray states. */
  setTrayState?: (state: import('../utils/trayState').TrayState) => void;
  /** The tray menu's quick controls. Absent on desktop builds older than the animated tray. */
  setTrayContext?: (context: import('../utils/trayState').TrayContext) => void;
  /** A quick control clicked in the tray menu. Absent on the same older builds. */
  onTrayAction?: (callback: (action: import('../utils/trayState').TrayAction) => void) => () => void;

  /**
   * Viewers' pointers on this client's screen share, drawn by the desktop app
   * over the shared display. Absent on desktop builds older than the overlay.
   */
  setStreamPointerOverlay?: (pointers: import('../utils/streamPointerOverlay').OverlayPointer[]) => void;
  endStreamPointerOverlay?: () => void;
  /** Whether the share captures the overlay after all; absent on builds before the check. */
  onStreamPointerOverlayCaptured?: (callback: (captured: boolean) => void) => () => void;

  // Auto-update, legacy per-event channels.
  //
  // Kept because the desktop app and the instance it connects to version
  // independently. Unused by this client; the snapshot API below replaces them.
  onUpdateAvailable: (callback: (info: { version: string }) => void) => void;
  onUpdateDownloaded: (callback: (info: { version: string }) => void) => void;
  onUpdateError: (callback: (error: { message: string; releaseUrl: string }) => void) => void;
  installUpdate: () => void;
  checkForUpdates: () => void;
  getVersion: () => Promise<string>;

  // Auto-update, current surface.
  //
  // Optional because an older desktop app does not expose them. A client served
  // by a newer instance can find itself running inside an older app, so every
  // call site must feature-detect. See updateStore.ts.
  getUpdateStatus?: () => Promise<unknown>;
  isSandboxed?: () => Promise<boolean>;
  onUpdateStatusChanged?: (callback: (snapshot: unknown) => void) => (() => void);
  dismissUpdate?: (version: string) => void;
  openReleasePage?: () => void;

  // Window focus (Task 2.2)
  onWindowFocusChange: (callback: (focused: boolean) => void) => void;

  // Deep linking (Task 2.3)
  onDeepLink: (callback: (url: string) => void) => void;

  // Instance-origin-aware URL routing
  setConnectedOrigins: (origins: string[]) => void;
  onOpenInternalRoute: (callback: (path: string) => void) => (() => void);

  // Screen share picker coordination
  onScreenShareSources: (callback: (sources: ElectronScreenSource[]) => void) => void;
  selectScreenSource: (sourceId: string | null, shareAudio?: boolean) => void;
  /**
   * Optional: desktop builds before the setup-screen flow lack these two. The
   * web client feature-detects them and falls back to the prompted flow
   * (getDisplayMedia → onScreenShareSources → selectScreenSource).
   */
  getScreenSources?: () => Promise<ElectronScreenSource[]>;
  preselectScreenSource?: (sourceId: string, shareAudio?: boolean) => Promise<void>;
  /**
   * 'system' when the OS picks the source (Wayland screencast portal): the
   * renderer shows a "choose" card that triggers the portal on click instead
   * of listing sources, which would prompt on every open. 'app' elsewhere.
   */
  // The argument is for the native macOS shell: a client that can take a
  // native capture says so and is shown the app's own list of sources; one
  // that says nothing is told 'system'. Electron ignores it.
  getScreenSharePickerMode?: (client?: { nativeCapture?: boolean }) => Promise<'app' | 'system'>;
  /** System-picker captures carry no preselection; this tells main whether to add loopback audio. */
  setScreenShareAudioPreference?: (shareAudio: boolean) => void;
  /**
   * Optional: older desktop builds lack it, and the stream settings
   * then keep their generic per-platform System Audio note.
   */
  // The argument says what this client does for itself. A boolean: whether
  // it opens the Linux system-audio source. `{ nativeAudio: true }`: it
  // takes the native macOS shell's capture (`startNativeSystemAudio`), which
  // leaves the app's own playback out; a client that does not say so is
  // told `unavailable` there, because WebKit's capture has no system audio.
  getSystemAudioCapability?: (does?: boolean | { nativeAudio: true }) => Promise<OwnAudioInSystemAudio>;
  /**
   * Names of the audio routers running now that replay other applications'
   * sound, which a System Audio share then carries twice (macOS; empty
   * elsewhere). Optional: older desktop builds lack it and show no warning.
   */
  getAudioRouters?: () => Promise<string[]>;
  /**
   * Linux: route every other app's playback into a virtual source that the
   * renderer opens as a microphone (`label` names the device). Optional: only
   * desktop builds that ship it have it.
   */
  /**
   * A System Audio capture without B:SPACE's own playback failed to start
   * (Windows refused process loopback). Main re-arms the same source with the
   * plain loopback; resolves true when the capture may be retried once.
   * Absent on desktop builds older than the Windows 10 exclusion.
   */
  reportSystemAudioExclusionFailed?: () => Promise<boolean>;
  startSystemAudio?: () => Promise<
    | { ok: true; label: string }
    | { ok: false; reason: 'unsupported-platform' | 'sandboxed' | 'module-missing' | 'no-pipewire' | 'link-failed' }
  >;
  stopSystemAudio?: () => Promise<void>;

  // Instance URL management
  getInstanceUrl: () => Promise<string | null>;
  setInstanceUrl: (url: string) => Promise<void>;
  clearInstanceUrl: () => Promise<void>;

  // Language: the renderer owns the choice; main relabels its tray and menus.
  // Optional because an older desktop app does not expose it.
  setLanguage?: (language: string) => void;

  // Auto-launch settings
  getAutoLaunchSettings: () => Promise<{ openAtLogin: boolean; startMinimized: boolean }>;
  setAutoLaunchSettings: (settings: { openAtLogin?: boolean; startMinimized?: boolean }) =>
    Promise<{ openAtLogin: boolean; startMinimized: boolean }>;

  // Activity detection (game/app process scanning)
  onActivityDetected: (callback: (activity: unknown) => void) => (() => void);
  getCurrentActivity: () => Promise<unknown>;

  // Keybind support
  getKeybindPortalStatus?: () => Promise<KeybindPortalStatus | null>;
  onKeybindPortalStatus?: (callback: (status: KeybindPortalStatus) => void) => () => void;
  retryKeybindPortal?: () => void;
  // Older installed shells use send-based IPC and return void.
  syncKeybinds: (keybinds: Array<{ actionId: string; keys: number[]; mouseButton?: number }>) => Promise<boolean> | void;
  onKeybindAction: (callback: (action: { actionId: string; pressed: boolean }) => void) => (() => void);
  onAccessibilityStatus: (callback: (status: { trusted: boolean }) => void) => (() => void);
  onKeybindHookError: (callback: (error: { message: string }) => void) => (() => void);
  checkAccessibility: () => Promise<boolean>;

  // Recovery mode bridge (Task 11)
  rendererReady: () => void;
  getRecoveryState: () => Promise<RecoveryState>;
  onRecoveryStateChanged: (cb: (state: RecoveryState) => void) => () => void;
  recoveryAction: (action: RecoveryAction) => void;

  // Native macOS shell only (`nativeOnly` in bridgeContract.json). WebKit has
  // no -webkit-app-region, so the page reports where its title bar is; see
  // platform/windowDragRegions.ts. Electron does not have this member.
  setDragRegions?: (regions: WindowDragRegions) => void;
  // Native macOS shell only. It listens for the global keybinds with the
  // Input Monitoring permission, not Accessibility as the Electron build
  // does: this has the system ask for it and opens its list in System
  // Settings. `checkAccessibility` and `onAccessibilityStatus` report that
  // permission there.
  openKeybindPermissionSettings?: () => void;
  // Native macOS shell only. WebKit's own screen capture gives 30 frames a
  // second at point resolution and no system audio, and cannot be told
  // which source to take. The shell captures the source itself and hands
  // the frames to the page over a local WebSocket: the answer says where to
  // connect and which token to say first. See "The local media channel" and
  // "Video on the channel" in packages/desktop-macos/README.md.
  // A page may have a few captures at once (a share, and the preview of
  // the source it is about to switch to); each is stopped by its id.
  startNativeScreenCapture?: (options: NativeScreenCaptureOptions) => Promise<NativeScreenCaptureResult>;
  stopNativeScreenCapture?: (id: string) => void;
  // A capture ended by itself: the window was closed, the display
  // unplugged, the permission taken away.
  onNativeScreenCaptureEnded?: (cb: (event: { id: string }) => void) => () => void;
  // Native macOS shell only. The system's sound for a share: everything
  // the Mac plays except the app itself. A capture of its own, apart from
  // the picture's, read from a local WebSocket like it: 32-bit float
  // samples at the rate and in the channels the answer names. See
  // "The system's sound" in packages/desktop-macos/README.md.
  startNativeSystemAudio?: () => Promise<NativeSystemAudioResult>;
  stopNativeSystemAudio?: (id: string) => void;
  // A capture ended by itself: the permission was taken away, the system
  // stopped it.
  onNativeSystemAudioEnded?: (cb: (event: { id: string }) => void) => () => void;
  // Native macOS shell only. The shell publishes the share itself: it
  // joins the call as the user's stream participant (docs/systems/voice.md,
  // "The stream participant") with the stream token the page got from the
  // call's server, and sends what it captures with one hardware encode.
  // Nothing of the share passes through the page. One share per window.
  startNativeScreenShare?: (options: NativeScreenShareOptions) => Promise<NativeScreenShareResult>;
  // Changes what is named and nothing else, on the same published track:
  // another source, size or frame rate, another bitrate, the sound on or
  // off. The codec is decided at the start; for another one, stop and start.
  updateNativeScreenShare?: (options: NativeScreenShareUpdate) => Promise<NativeScreenShareResult>;
  stopNativeScreenShare?: () => void;
  // What happens to the share while it runs: it ended by itself, its
  // connection is being restored, its window changed size, its sound
  // ended, and once a second what it sends.
  onNativeScreenShareEvent?: (cb: (event: NativeScreenShareEvent) => void) => () => void;
}

interface NativeScreenCaptureOptions {
  /** An id from `getScreenSources`. */
  sourceId: string;
  /** The most the video may measure; the source's own size when smaller. */
  maxWidth?: number;
  maxHeight?: number;
  /** 1 to 60; 30 when left out. */
  frameRate?: number;
}

type NativeScreenCaptureResult =
  | { ok: true; id: string; url: string; token: string; width: number; height: number; frameRate: number }
  | { ok: false; reason: 'bad-request' | 'no-permission' | 'no-source' | 'unsupported' | 'too-many' | 'failed' };

type NativeSystemAudioResult =
  | { ok: true; id: string; url: string; token: string; sampleRate: number; channels: number }
  | { ok: false; reason: 'no-permission' | 'unsupported' | 'too-many' | 'failed' };

interface NativeScreenShareOptions {
  /** The call's LiveKit address and the stream token its server issued (`purpose: 'stream'`). */
  url: string;
  token: string;
  /** An id from `getScreenSources`. */
  sourceId: string;
  /** The most the video may measure; the source's own size when smaller. */
  maxWidth?: number;
  maxHeight?: number;
  /** 1 to 60; 30 when left out. */
  frameRate?: number;
  /** `h264` when left out. With `h265`, viewers that cannot decode it are sent H.264. */
  codec?: 'h264' | 'h265';
  /** Bits a second: the ceiling, and the floor the encoder keeps while the bandwidth estimate is lower (0 for none). */
  maxBitrate?: number;
  minBitrate?: number;
  /** Whether the system's sound goes with the picture. */
  audio?: boolean;
}

/** Only what is named changes. */
interface NativeScreenShareUpdate {
  sourceId?: string;
  maxWidth?: number;
  maxHeight?: number;
  frameRate?: number;
  maxBitrate?: number;
  minBitrate?: number;
  audio?: boolean;
}

type NativeScreenShareResult =
  | { ok: true; width: number; height: number; frameRate: number }
  | {
      ok: false;
      reason:
        | 'bad-request' | 'no-permission' | 'no-source' | 'unsupported' | 'busy'
        | 'connect-failed' | 'publish-failed' | 'not-running' | 'failed';
    };

type NativeScreenShareEvent =
  | { type: 'ended'; reason: 'source-ended' | 'disconnected' | 'failed' }
  | { type: 'reconnecting' }
  | { type: 'reconnected' }
  | { type: 'resized'; width: number; height: number }
  | { type: 'audio-ended' }
  | {
      type: 'stats';
      /** Bits a second of video sent. */
      bitrate: number;
      frameRate: number;
      width: number;
      height: number;
      /** As WebRTC names them: `video/H265`, `VideoToolbox`. */
      codec: string;
      encoder: string;
      hardware: boolean;
      roundTripMs?: number;
      availableBitrate?: number;
      limitedBy?: string;
      audioBitrate?: number;
    };

interface Window {
  backspace?: BackspaceElectronAPI;
}

interface KeybindPortalStatus {
  state: 'idle' | 'pending' | 'ready' | 'unavailable';
  shortcuts: Record<string, string>;
}
