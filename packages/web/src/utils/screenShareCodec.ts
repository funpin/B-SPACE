/**
 * Which video codec a screen share is encoded with.
 *
 * The user picks Auto (the default), VP9 or H264 in the stream quality
 * controls. Auto exists because the encoder's cost differs by orders of
 * magnitude between machines: VP9 has no hardware encoder on Macs or on most
 * Windows GPUs, so Chromium encodes it in software (libvpx), and a 1440p60
 * share then keeps three to four CPU cores busy. H264 goes to the platform's
 * hardware encoder there (VideoToolbox on macOS, Media Foundation on Windows).
 * Measured on an Apple Silicon Mac sharing 2216x1438 at ~50 fps while watching
 * a 1440p stream: VP9/libvpx 38-85 % renderer CPU and ~385 MB, H264/VideoToolbox
 * ~25 % and ~134 MB, the GPU process 20 % -> 11 %.
 *
 * Why not ask the browser: `navigator.mediaCapabilities.encodingInfo` with
 * `type: 'webrtc'` reported `powerEfficient: false` for H264 on that same Mac
 * while WebRTC's own stats said `powerEfficientEncoder: true` and
 * `encoderImplementation: VideoToolbox`. The platform is the better prior, and
 * the encoder the stats report after publishing is the truth: when H264 turns
 * out to be software (OpenH264, e.g. Firefox or a machine without a hardware
 * encoder), Auto switches the share to VP9 and remembers that for the session
 * (`noteSoftwareH264`).
 */

export type ScreenShareCodec = 'vp9' | 'h264';
export type ScreenShareCodecChoice = 'auto' | ScreenShareCodec;

export const SCREEN_SHARE_CODEC_CHOICES: readonly ScreenShareCodecChoice[] = ['auto', 'vp9', 'h264'];

export function isScreenShareCodecChoice(value: unknown): value is ScreenShareCodecChoice {
  return typeof value === 'string' && (SCREEN_SHARE_CODEC_CHOICES as readonly string[]).includes(value);
}

/** Operating systems whose WebRTC stack has a hardware H264 encoder as a rule. */
export type CodecPlatform = 'mac' | 'windows' | 'ios' | 'android' | 'linux' | 'other';

const SOFTWARE_H264_KEY = 'b-space:screen-share-software-h264';

let softwareH264Seen: boolean | null = null;

function readSoftwareH264(): boolean {
  if (softwareH264Seen !== null) return softwareH264Seen;
  try {
    softwareH264Seen = sessionStorage.getItem(SOFTWARE_H264_KEY) === '1';
  } catch {
    softwareH264Seen = false;
  }
  return softwareH264Seen;
}

/**
 * Records that this machine encoded H264 in software, so Auto stops choosing
 * it until the app restarts. Session-scoped on purpose: a driver update or a
 * different GPU can bring the hardware encoder back.
 */
export function noteSoftwareH264(): void {
  softwareH264Seen = true;
  try {
    sessionStorage.setItem(SOFTWARE_H264_KEY, '1');
  } catch {
    // Private mode or blocked storage: the in-memory flag still holds for this page.
  }
}

/** Test seam. */
export function resetSoftwareH264ForTest(): void {
  softwareH264Seen = null;
  try {
    sessionStorage.removeItem(SOFTWARE_H264_KEY);
  } catch {
    // Nothing stored.
  }
}

interface PlatformHints {
  desktopPlatform?: string | null;
  userAgentDataPlatform?: string | null;
  platform?: string | null;
  userAgent?: string | null;
}

/** The OS this client runs on, from the desktop bridge when there is one, else from the browser. */
export function detectCodecPlatform(hints: PlatformHints): CodecPlatform {
  switch (hints.desktopPlatform) {
    case 'darwin': return 'mac';
    case 'win32': return 'windows';
    case 'linux': return 'linux';
    default: break;
  }
  const ua = hints.userAgent ?? '';
  // iPadOS reports itself as a Mac; touch support is what tells them apart,
  // and both have hardware H264, so the distinction does not matter here.
  if (/iPhone|iPad|iPod/i.test(ua)) return 'ios';
  if (/Android/i.test(ua)) return 'android';
  const platform = `${hints.userAgentDataPlatform ?? ''} ${hints.platform ?? ''} ${ua}`;
  if (/\bmac/i.test(platform)) return 'mac';
  // Not a bare /win/: "darwin" contains it.
  if (/windows|\bwin(32|64)\b/i.test(platform)) return 'windows';
  if (/linux|x11|cros/i.test(platform)) return 'linux';
  return 'other';
}

function currentPlatform(): CodecPlatform {
  if (typeof navigator === 'undefined') return 'other';
  const nav = navigator as Navigator & { userAgentData?: { platform?: string } };
  const desktop = typeof window !== 'undefined' ? window.backspace?.platform : undefined;
  return detectCodecPlatform({
    desktopPlatform: desktop ?? null,
    userAgentDataPlatform: nav.userAgentData?.platform ?? null,
    platform: nav.platform ?? null,
    userAgent: nav.userAgent ?? null,
  });
}

const HARDWARE_H264_PLATFORMS: ReadonlySet<CodecPlatform> = new Set(['mac', 'windows', 'ios', 'android']);

/**
 * The codec a share is encoded with. An explicit choice is kept as it is.
 * Auto takes H264 where the platform encodes it in hardware and it has not
 * been seen falling back to software this session, and VP9 everywhere else,
 * which is what every share used before Auto existed.
 */
export function resolveScreenShareCodec(
  choice: ScreenShareCodecChoice,
  platform: CodecPlatform = currentPlatform(),
  softwareH264 = readSoftwareH264(),
): ScreenShareCodec {
  if (choice !== 'auto') return choice;
  if (softwareH264) return 'vp9';
  return HARDWARE_H264_PLATFORMS.has(platform) ? 'h264' : 'vp9';
}

/**
 * Whether the encoder implementation WebRTC reports for H264 is a software
 * one. Chromium names its software H264 encoder OpenH264; hardware encoders
 * report VideoToolbox, MediaFoundation and the like. `powerEfficientEncoder`
 * is not used: it is missing on older engines and not reliable across
 * simulcast adapters.
 */
export function isSoftwareH264Encoder(implementation: string | null): boolean {
  return implementation != null && /openh264/i.test(implementation);
}
