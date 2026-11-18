/**
 * Reads what the native macOS shell sends on a local media channel and feeds
 * it to a video decoder.
 *
 * The wire format is the shell's (`MediaWire` in packages/desktop-macos, and
 * "Video on the channel" in its README): a text message is JSON and announces
 * the format of the video that follows; a binary message is one frame behind a
 * nine-byte header (what it is, when it was captured).
 *
 * This file is the logic alone, so that it can be tested without a socket or
 * a decoder; `reader.worker.ts` gives it the real ones.
 */

/** How to configure a decoder for the frames that follow. */
export interface VideoFormat {
  /** As WebCodecs names it: `avc1.64002a`. */
  codec: string;
  width: number;
  height: number;
  /** The decoder configuration record (`avcC`). */
  description: Uint8Array;
}

export interface EncodedFrame {
  /** Whether the frame can be decoded on its own. */
  key: boolean;
  /** When it was captured, in microseconds since 1970. */
  timestamp: number;
  data: Uint8Array;
}

/** As much of a `VideoDecoder` as the reader uses. */
export interface FrameDecoder {
  /** Frames given to the decoder and not decoded yet (`decodeQueueSize`). */
  readonly waiting: number;
  configure(format: VideoFormat): void;
  decode(frame: EncodedFrame): void;
  /** Drops everything that waits. The decoder has to be configured again. */
  reset(): void;
}

export const KEY_FRAME = 1;
export const DELTA_FRAME = 2;
export const HEADER_LENGTH = 9;

/**
 * More frames than this waiting to be decoded means the page cannot keep up.
 * Nothing between the screen and the decoder drops a frame, so a decoder that
 * is slower than the stream for a moment would stay late for good, and later
 * with every such moment (measured: 30 frames and 0.8 s at 3024 by 1964 on a
 * busy machine). What waits is thrown away and decoding starts again from a
 * frame asked for.
 */
export const MOST_FRAMES_WAITING = 4;

export class ChannelReader {
  /** What happened so far; for diagnostics. */
  readonly counts = { frames: 0, decoded: 0, skipped: 0, fellBehind: 0, decoderErrors: 0 };
  private format: VideoFormat | null = null;
  /** The next frame given to the decoder has to be a key frame. */
  private needsKeyFrame = true;

  /**
   * @param askForKeyFrame sends the shell the request for a frame that can be
   *   decoded on its own.
   */
  constructor(
    private readonly decoder: FrameDecoder,
    private readonly askForKeyFrame: () => void,
    private readonly mostWaiting = MOST_FRAMES_WAITING,
  ) {}

  /** A text message: the announcement of a format, or something to ignore. */
  text(message: string): void {
    const format = parseFormat(message);
    if (!format) return;
    this.format = format;
    this.decoder.configure(format);
    // A decoder that was just configured takes nothing but a key frame.
    this.needsKeyFrame = true;
  }

  /** A binary message: one frame. */
  binary(message: ArrayBuffer): void {
    if (message.byteLength <= HEADER_LENGTH) return;
    const view = new DataView(message);
    const kind = view.getUint8(0);
    if (kind !== KEY_FRAME && kind !== DELTA_FRAME) return;
    this.counts.frames += 1;
    if (!this.format) {
      this.counts.skipped += 1;
      return;
    }
    const key = kind === KEY_FRAME;

    if (!this.needsKeyFrame && this.decoder.waiting > this.mostWaiting) {
      this.counts.fellBehind += 1;
      this.counts.skipped += this.decoder.waiting;
      this.startAgain();
    }
    if (this.needsKeyFrame) {
      if (!key) {
        this.counts.skipped += 1;
        return;
      }
      this.needsKeyFrame = false;
    }
    this.counts.decoded += 1;
    this.decoder.decode({
      key,
      timestamp: Math.round(view.getFloat64(1, true) * 1000),
      data: new Uint8Array(message, HEADER_LENGTH),
    });
  }

  /** The decoder reported an error: it is of no use until it starts again. */
  decoderFailed(): void {
    this.counts.decoderErrors += 1;
    if (this.format) this.startAgain();
  }

  private startAgain(): void {
    if (!this.format) return;
    this.decoder.reset();
    this.decoder.configure(this.format);
    this.needsKeyFrame = true;
    this.askForKeyFrame();
  }
}

/** The request the shell answers with a key frame. */
export const KEY_FRAME_REQUEST = JSON.stringify({ type: 'keyframe' });

function parseFormat(message: string): VideoFormat | null {
  let value: unknown;
  try {
    value = JSON.parse(message);
  } catch {
    return null;
  }
  if (typeof value !== 'object' || value === null) return null;
  const { type, codec, width, height, description } = value as Record<string, unknown>;
  if (type !== 'video' || typeof codec !== 'string' || typeof description !== 'string') return null;
  if (!isSize(width) || !isSize(height)) return null;
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(description), (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
  if (bytes.length === 0) return null;
  return { codec, width, height, description: bytes };
}

function isSize(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value > 0 && value <= 16384;
}
