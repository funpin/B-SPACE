/**
 * Whether a system-audio screen share on this machine carries Backspace's own
 * playback (the voice chat, its sounds, in-app embeds) to the viewers. The
 * per-OS-build rule and the Chromium code it follows are stated in
 * docs/systems/voice.md ("System Audio Loopback"); this is that table as code.
 *
 * `unknown` is for a version string this cannot read; the renderer then shows
 * its generic per-platform note.
 */
export type OwnAudioInSystemAudio = 'excluded' | 'included' | 'unavailable' | 'unknown';

/**
 * First Windows build with process loopback (`AUDIOCLIENT_ACTIVATION_TYPE_
 * PROCESS_LOOPBACK`), the capture that leaves one process tree out: Windows 10
 * version 2004. Chromium only forwards the renderer's `restrictOwnAudio` from
 * Windows 11 (`IsWindowsProcessLoopbackCaptureSupported`), but its capture
 * itself has no version check, and the desktop app names the device itself
 * (`systemAudioDeviceId`), so Windows 10 2004+ gets the exclusion too.
 */
export const WINDOWS_OWN_AUDIO_EXCLUSION_BUILD = 19041;

function parseVersion(version: string): number[] | null {
  const match = /^(\d+)(?:\.(\d+))?(?:\.(\d+))?/.exec(version.trim());
  if (!match) return null;
  return [Number(match[1]), Number(match[2] ?? 0), Number(match[3] ?? 0)];
}

function atLeast(version: number[], major: number, minor: number): boolean {
  const [vMajor = 0, vMinor = 0] = version;
  return vMajor > major || (vMajor === major && vMinor >= minor);
}

/**
 * @param platform `process.platform`
 * @param systemVersion `process.getSystemVersion()`: `10.0.<build>` on Windows,
 *   the macOS version on macOS, the kernel release on Linux.
 */
export function ownAudioInSystemAudio(
  platform: NodeJS.Platform,
  systemVersion: string,
  /** Process loopback was tried on this OS version and Windows refused it (processLoopbackMemory.ts). */
  exclusionFailedHere = false,
): OwnAudioInSystemAudio {
  if (platform === 'linux') return 'included';
  const version = parseVersion(systemVersion);
  if (!version) return 'unknown';
  if (platform === 'win32') {
    const build = version[2];
    if (!build) return 'unknown';
    if (exclusionFailedHere) return 'included';
    return build >= WINDOWS_OWN_AUDIO_EXCLUSION_BUILD ? 'excluded' : 'included';
  }
  if (platform === 'darwin') {
    if (atLeast(version, 14, 2)) return 'excluded';
    if (atLeast(version, 13, 0)) return 'included';
    return 'unavailable';
  }
  return 'unknown';
}

/**
 * The audio device id the display-media handler answers a System Audio share
 * with. Where the OS can leave Backspace's own playback out (`excluded`), the
 * handler names Chromium's `loopbackWithoutChrome` itself instead of returning
 * plain `loopback` and relying on Electron to swap it: that swap (Electron
 * 43.4+) only happens when Blink forwarded the renderer's `restrictOwnAudio`
 * constraint, and in practice the share still carried the voice chat. On
 * Windows 10 2004+ and 11 Chromium then opens a WASAPI process loopback that
 * excludes the audio service's process tree; on macOS 14.2+ a CoreAudio Tap
 * excluding it. Once Windows has refused that capture on this OS version
 * (`exclusionFailedHere`), the plain loopback is used again.
 * Everywhere else (`included`, `unavailable`, `unknown`) the id would fail or
 * mean nothing, so the plain loopback stays.
 */
export type SystemAudioDeviceId = 'loopback' | 'loopbackWithoutChrome';

export function systemAudioDeviceId(
  platform: NodeJS.Platform,
  systemVersion: string,
  exclusionFailedHere = false,
): SystemAudioDeviceId {
  if (platform !== 'win32' && platform !== 'darwin') return 'loopback';
  return ownAudioInSystemAudio(platform, systemVersion, exclusionFailedHere) === 'excluded' ? 'loopbackWithoutChrome' : 'loopback';
}
