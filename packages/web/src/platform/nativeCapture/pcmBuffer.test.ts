import { describe, expect, it } from 'vitest';
import { PcmBuffer, soundOf } from './pcmBuffer';

/** A buffer with a reserve of 4 frames that lets 8 wait, at one frame a "second". */
function small(channels = 2): PcmBuffer {
  return new PcmBuffer(channels, 1, 4, 8);
}

/** Stereo frames numbered from `first`: the left sample is the number, the right its negative. */
function frames(first: number, count: number): Float32Array {
  const samples = new Float32Array(count * 2);
  for (let index = 0; index < count; index++) {
    samples[index * 2] = first + index;
    samples[index * 2 + 1] = -(first + index);
  }
  return samples;
}

function pull(buffer: PcmBuffer, count: number, channels = 2): number[][] {
  const outputs = Array.from({ length: channels }, () => new Float32Array(count).fill(99));
  buffer.pull(outputs);
  return outputs.map((output) => Array.from(output));
}

describe('PcmBuffer', () => {
  it('plays nothing until its reserve is there', () => {
    const buffer = small();
    buffer.push(frames(1, 3));
    expect(pull(buffer, 2)).toEqual([[0, 0], [0, 0]]);
    expect(buffer.waiting).toBe(3);
    expect(buffer.ranDry).toBe(0);
  });

  it('plays each channel on its own side, in order', () => {
    const buffer = small();
    buffer.push(frames(1, 4));
    expect(pull(buffer, 3)).toEqual([[1, 2, 3], [-1, -2, -3]]);
    expect(buffer.waiting).toBe(1);
  });

  it('starts playing from the reserve, not from all that piled up before', () => {
    const buffer = small();
    buffer.push(frames(1, 7));
    expect(pull(buffer, 2)).toEqual([[4, 5], [-4, -5]]);
    expect(buffer.skipped).toBe(3);
    expect(buffer.waiting).toBe(2);
  });

  it('goes on playing below the reserve once it has started', () => {
    const buffer = small();
    buffer.push(frames(1, 4));
    pull(buffer, 3);
    buffer.push(frames(5, 1));
    expect(pull(buffer, 2)).toEqual([[4, 5], [-4, -5]]);
    expect(buffer.ranDry).toBe(0);
  });

  it('ends a block in silence when it runs dry, and fills its reserve again', () => {
    const buffer = small();
    buffer.push(frames(1, 4));
    expect(pull(buffer, 6)).toEqual([[1, 2, 3, 4, 0, 0], [-1, -2, -3, -4, 0, 0]]);
    expect(buffer.ranDry).toBe(1);
    buffer.push(frames(5, 2));
    expect(pull(buffer, 2)).toEqual([[0, 0], [0, 0]]);
    buffer.push(frames(7, 2));
    expect(pull(buffer, 2)).toEqual([[5, 6], [-5, -6]]);
    expect(buffer.ranDry).toBe(1);
  });

  it('skips the oldest sound down to the reserve when too much waits', () => {
    const buffer = small();
    buffer.push(frames(1, 8));
    expect(buffer.skipped).toBe(0);
    buffer.push(frames(9, 2));
    // Ten waited, eight may: the newest four are kept.
    expect(buffer.waiting).toBe(4);
    expect(buffer.skipped).toBe(6);
    expect(pull(buffer, 4)).toEqual([[7, 8, 9, 10], [-7, -8, -9, -10]]);
  });

  it('keeps only the end of a piece longer than all that may wait', () => {
    const buffer = small();
    buffer.push(frames(1, 20));
    expect(buffer.received).toBe(20);
    expect(buffer.waiting).toBe(8);
    expect(buffer.skipped).toBe(12);
    expect(pull(buffer, 4)[0]).toEqual([17, 18, 19, 20]);
  });

  it('keeps its place over many rounds of the ring', () => {
    const buffer = small();
    let next = 1;
    buffer.push(frames(next, 4));
    next += 4;
    // Playing has started: from here on nothing is skipped.
    expect(pull(buffer, 1)).toEqual([[1], [-1]]);
    let expected = 2;
    for (let round = 0; round < 50; round++) {
      buffer.push(frames(next, 3));
      next += 3;
      const [left, right] = pull(buffer, 3);
      expect(left).toEqual([expected, expected + 1, expected + 2]);
      expect(right).toEqual([-expected, -(expected + 1), -(expected + 2)]);
      expected += 3;
    }
    expect(buffer.skipped).toBe(0);
    expect(buffer.ranDry).toBe(0);
  });

  it('repeats the last channel for an output with more, and leaves out what an output has no room for', () => {
    const mono = new PcmBuffer(1, 1, 2, 8);
    mono.push(Float32Array.of(1, 2));
    expect(pull(mono, 2, 2)).toEqual([[1, 2], [1, 2]]);

    const stereo = small();
    stereo.push(frames(1, 4));
    expect(pull(stereo, 2, 1)).toEqual([[1, 2]]);
  });

  it('ignores samples that do not make a whole frame', () => {
    const buffer = small();
    buffer.push(Float32Array.of(1));
    expect(buffer.received).toBe(0);
    buffer.push(Float32Array.of(1, -1, 2));
    expect(buffer.received).toBe(1);
  });

  it('measures its reserve in the sample rate it is given', () => {
    const buffer = new PcmBuffer(2, 48_000);
    expect(buffer.target).toBe(2880);
    expect(buffer.most).toBe(12_000);
  });
});

describe('soundOf', () => {
  function message(kind: number, samples: number[], extraBytes = 0): ArrayBuffer {
    const bytes = new Uint8Array(9 + samples.length * 4 + extraBytes);
    bytes[0] = kind;
    const view = new DataView(bytes.buffer);
    view.setFloat64(1, 1234.5, true);
    samples.forEach((sample, index) => view.setFloat32(9 + index * 4, sample, true));
    return bytes.buffer;
  }

  it('gives the samples of a sound message as floats of their own', () => {
    const sound = soundOf(message(3, [0.5, -0.25, 1]));
    expect(sound).not.toBeNull();
    expect(Array.from(new Float32Array(sound!))).toEqual([0.5, -0.25, 1]);
  });

  it('is nothing for a message that is not sound', () => {
    expect(soundOf(message(1, [0.5]))).toBeNull();
    expect(soundOf(message(2, [0.5]))).toBeNull();
  });

  it('is nothing for a message without samples or with part of one', () => {
    expect(soundOf(message(3, []))).toBeNull();
    expect(soundOf(message(3, [0.5], 2))).toBeNull();
    expect(soundOf(new ArrayBuffer(0))).toBeNull();
  });
});
