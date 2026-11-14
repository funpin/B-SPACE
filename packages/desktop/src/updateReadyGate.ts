/**
 * When a downloaded update may be offered as ready to install.
 *
 * electron-updater's `update-downloaded` means "the archive is on disk". On
 * Windows and Linux that is also "installable", so the update is ready at
 * once. On macOS it is not: MacUpdater fires the event the moment its local
 * proxy server is up and only then asks Squirrel.Mac to fetch the archive
 * from it, unpack it and check its signature against the running app
 * (`docs/systems/desktop.md`, "The `update-downloaded` trap"). For the 120 MB
 * B-SPACE archive that takes about a minute, and a Restart clicked inside it
 * leaves `quitAndInstall()` waiting on Squirrel while the 4-second install
 * watchdog reports a failure.
 *
 * So on macOS the update is ready only once both have happened:
 * electron-updater's download and the native `autoUpdater`'s own
 * `update-downloaded` (Squirrel staged it). Until then the caller keeps
 * showing the download, finished but being prepared. Either event may come
 * first.
 */
export interface UpdateReadyGate {
  /** electron-updater's `update-downloaded` for this version. */
  downloaded(version: string): void;
  /** Squirrel.Mac's `update-downloaded`: staged, installs on quit. */
  staged(): void;
  /** A new check cycle starts: forget the previous download and staging. */
  reset(): void;
  /** True between the download and the moment the update is ready. */
  readonly preparing: boolean;
}

export function createUpdateReadyGate(
  platform: NodeJS.Platform,
  onReady: (version: string) => void,
): UpdateReadyGate {
  const needsStaging = platform === 'darwin';
  let version: string | null = null;
  let isStaged = false;
  let fired = false;

  const maybeReady = (): void => {
    if (fired || version === null) return;
    if (needsStaging && !isStaged) return;
    fired = true;
    onReady(version);
  };

  return {
    downloaded(next) {
      if (version !== next) fired = false;
      version = next;
      maybeReady();
    },
    staged() {
      isStaged = true;
      maybeReady();
    },
    reset() {
      version = null;
      isStaged = false;
      fired = false;
    },
    get preparing() {
      return version !== null && !fired;
    },
  };
}
