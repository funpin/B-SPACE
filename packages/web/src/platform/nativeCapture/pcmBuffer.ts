/**
 * The sound of a native capture between the channel and the audio thread.
 *
 * Samples arrive from the shell in pieces, at the pace of its capture and of
 * the thread that reads the channel; the audio thread takes them 128 frames at
 * a time, on its own clock. The buffer holds a little in reserve so that a
 * piece arriving late is not a gap, and never much: what a viewer hears has to
 * stay with the picture.
 *
 * - Nothing is played until the reserve (`target`) is there. That holds at the
 *   start and again after the buffer ran dry. Playing starts from the reserve
 *   and no further back: what piled up before the audio thread took its
 *   first block, or while the channel's reader was held up, is skipped, or
 *   the sound would stay that much late for as long as it plays.
 * - When more than `most` waits (the page was held up and a burst arrived, or
 *   the two clocks drifted apart), the oldest sound is skipped down to the
 *   reserve. A skip is a click; sound that stays late is worse.
 *
 * No allocation happens in `push` or `pull`: both run for every piece of
 * sound, `pull` on the audio thread.
 */

/**
 * The name the audio worklet's processor is registered under. Here, and not
 * in the worklet's own file, because the page needs the name and must not
 * run that file.
 */
export const SOUND_PROCESSOR = 'native-system-audio';

/** The reserve before sound is played. */
export const TARGET_SECONDS = 0.06;
/** What may wait before the oldest sound is skipped. */
export const MOST_SECONDS = 0.25;

export class PcmBuffer {
  /** Frames kept in reserve before sound is played. */
  readonly target: number;
  /** Frames that may wait before the oldest are skipped. */
  readonly most: number;
  /** Frames taken in since the start. */
  received = 0;
  /** Frames skipped because too much was waiting. */
  skipped = 0;
  /** Frames played out. */
  played = 0;
  /** Times the buffer ran dry while playing. */
  ranDry = 0;

  private readonly ring: Float32Array;
  private readonly capacity: number;
  private readAt = 0;
  private held = 0;
  private filling = true;

  constructor(
    readonly channels: number,
    sampleRate: number,
    targetSeconds = TARGET_SECONDS,
    mostSeconds = MOST_SECONDS,
  ) {
    this.target = Math.max(1, Math.round(sampleRate * targetSeconds));
    this.most = Math.max(this.target, Math.round(sampleRate * mostSeconds));
    // Room for all that may wait and for a piece as large again.
    this.capacity = this.most * 2;
    this.ring = new Float32Array(this.capacity * channels);
  }

  /** Frames waiting to be played. */
  get waiting(): number {
    return this.held;
  }

  /** Takes in samples laid out frame after frame, each channel's in turn. */
  push(samples: Float32Array): void {
    const { channels, capacity, ring, most } = this;
    let frames = Math.floor(samples.length / channels);
    if (frames === 0) return;
    this.received += frames;
    // A piece longer than all that may wait: only its end is worth keeping.
    let from = 0;
    if (frames > most) {
      from = (frames - most) * channels;
      this.skipped += frames - most;
      frames = most;
    }
    let writeAt = ((this.readAt + this.held) % capacity) * channels;
    const end = from + frames * channels;
    for (let index = from; index < end; index++) {
      ring[writeAt] = samples[index]!;
      writeAt += 1;
      if (writeAt === ring.length) writeAt = 0;
    }
    this.held += frames;
    if (this.held > most) {
      const skip = this.held - this.target;
      this.readAt = (this.readAt + skip) % capacity;
      this.held = this.target;
      this.skipped += skip;
    }
  }

  /**
   * Fills one block of output, a channel to an array. Silence while the
   * reserve fills. An output with more channels than the sound repeats the
   * last one; one with fewer leaves the rest out.
   */
  pull(outputs: readonly Float32Array[]): void {
    const frames = outputs[0]?.length ?? 0;
    if (frames === 0) return;
    if (this.filling) {
      if (this.held < this.target) {
        for (const output of outputs) output.fill(0);
        return;
      }
      this.filling = false;
      const skip = this.held - this.target;
      this.readAt = (this.readAt + skip) % this.capacity;
      this.held = this.target;
      this.skipped += skip;
    }
    const { channels, capacity, ring } = this;
    const playing = Math.min(frames, this.held);
    for (let out = 0; out < outputs.length; out++) {
      const output = outputs[out]!;
      const channel = Math.min(out, channels - 1);
      let readAt = this.readAt * channels + channel;
      for (let frame = 0; frame < playing; frame++) {
        output[frame] = ring[readAt]!;
        readAt += channels;
        if (readAt >= ring.length) readAt -= ring.length;
      }
      if (playing < frames) output.fill(0, playing);
    }
    this.readAt = (this.readAt + playing) % capacity;
    this.held -= playing;
    this.played += playing;
    if (playing < frames) {
      this.filling = true;
      this.ranDry += 1;
    }
  }
}

/** The first byte of a binary message that carries sound (`MediaWire.Kind.audio` in the shell). */
const SOUND = 3;
/** The header of a binary message: its kind and when it was captured. */
const HEADER_BYTES = 9;
const BYTES_A_SAMPLE = 4;

/**
 * The samples of one binary message from the channel, as a buffer of their
 * own: 32-bit little-endian floats, frame after frame. Null for a message that
 * is not sound or is not whole samples.
 *
 * A copy, because the samples start nine bytes into the message and an array
 * of floats cannot start there; the copy is also what is handed to the audio
 * thread.
 */
export function soundOf(message: ArrayBuffer): ArrayBuffer | null {
  if (message.byteLength <= HEADER_BYTES) return null;
  if (new Uint8Array(message, 0, 1)[0] !== SOUND) return null;
  if ((message.byteLength - HEADER_BYTES) % BYTES_A_SAMPLE !== 0) return null;
  return message.slice(HEADER_BYTES);
}
