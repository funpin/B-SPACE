import { describe, it, expect, vi } from 'vitest';
import {
  ChannelReader, DELTA_FRAME, KEY_FRAME, KEY_FRAME_REQUEST,
  type EncodedFrame, type FrameDecoder, type VideoFormat,
} from './channelReader';

/** A decoder that only records, with a queue the test fills by hand. */
function fakeDecoder() {
  const calls: string[] = [];
  const frames: EncodedFrame[] = [];
  const formats: VideoFormat[] = [];
  const decoder = {
    waiting: 0,
    configure(format: VideoFormat) { calls.push('configure'); formats.push(format); },
    decode(frame: EncodedFrame) { calls.push(frame.key ? 'key' : 'delta'); frames.push(frame); },
    reset() { calls.push('reset'); this.waiting = 0; },
  } satisfies FrameDecoder;
  return { decoder, calls, frames, formats };
}

const announcement = JSON.stringify({
  type: 'video', codec: 'avc1.64002a', width: 1670, height: 1080, description: btoa('\x01\x64\x00\x2a'),
});

function frame(kind: number, capturedAt = 1_795_000_000_000.5, payload = [1, 2, 3]): ArrayBuffer {
  const buffer = new ArrayBuffer(9 + payload.length);
  const view = new DataView(buffer);
  view.setUint8(0, kind);
  view.setFloat64(1, capturedAt, true);
  new Uint8Array(buffer, 9).set(payload);
  return buffer;
}

function reader() {
  const fake = fakeDecoder();
  const ask = vi.fn();
  return { ...fake, ask, reader: new ChannelReader(fake.decoder, ask) };
}

describe('ChannelReader', () => {
  it('configures the decoder from the announcement', () => {
    const { reader: r, formats } = reader();
    r.text(announcement);
    expect(formats).toEqual([{
      codec: 'avc1.64002a', width: 1670, height: 1080, description: new Uint8Array([1, 0x64, 0, 0x2a]),
    }]);
  });

  it('ignores a text message that is not an announcement', () => {
    const { reader: r, calls } = reader();
    for (const message of [
      'not json', '[]', 'null', '{"type":"audio"}',
      JSON.stringify({ type: 'video', codec: 'avc1.64002a', width: 0, height: 1080, description: 'AQ==' }),
      JSON.stringify({ type: 'video', codec: 'avc1.64002a', width: 1920, height: 1080.5, description: 'AQ==' }),
      JSON.stringify({ type: 'video', codec: 7, width: 1920, height: 1080, description: 'AQ==' }),
      JSON.stringify({ type: 'video', codec: 'avc1.64002a', width: 1920, height: 1080, description: '' }),
      JSON.stringify({ type: 'video', codec: 'avc1.64002a', width: 1920, height: 1080, description: '***' }),
    ]) r.text(message);
    expect(calls).toEqual([]);
  });

  it('hands a frame to the decoder with its time in microseconds', () => {
    const { reader: r, frames } = reader();
    r.text(announcement);
    r.binary(frame(KEY_FRAME, 1_795_000_000_000.5, [9, 8, 7]));
    expect(frames).toHaveLength(1);
    expect(frames[0]!.key).toBe(true);
    expect(frames[0]!.timestamp).toBe(1_795_000_000_000_500);
    expect([...frames[0]!.data]).toEqual([9, 8, 7]);
  });

  it('starts from a key frame and skips what comes before it', () => {
    const { reader: r, calls } = reader();
    r.text(announcement);
    r.binary(frame(DELTA_FRAME));
    r.binary(frame(DELTA_FRAME));
    r.binary(frame(KEY_FRAME));
    r.binary(frame(DELTA_FRAME));
    expect(calls).toEqual(['configure', 'key', 'delta']);
    expect(r.counts).toMatchObject({ frames: 4, decoded: 2, skipped: 2 });
  });

  it('skips frames that arrive before any format', () => {
    const { reader: r, calls } = reader();
    r.binary(frame(KEY_FRAME));
    expect(calls).toEqual([]);
    expect(r.counts.skipped).toBe(1);
  });

  it('ignores a message that is no frame', () => {
    const { reader: r, calls } = reader();
    r.text(announcement);
    r.binary(new ArrayBuffer(0));
    r.binary(new ArrayBuffer(9));
    r.binary(frame(7));
    expect(calls).toEqual(['configure']);
    expect(r.counts.frames).toBe(0);
  });

  it('wants a key frame again after a new format', () => {
    const { reader: r, calls } = reader();
    r.text(announcement);
    r.binary(frame(KEY_FRAME));
    r.text(announcement);
    r.binary(frame(DELTA_FRAME));
    r.binary(frame(KEY_FRAME));
    expect(calls).toEqual(['configure', 'key', 'configure', 'key']);
  });

  it('lets a few frames wait without doing anything', () => {
    const { reader: r, decoder, calls, ask } = reader();
    r.text(announcement);
    r.binary(frame(KEY_FRAME));
    decoder.waiting = 4;
    r.binary(frame(DELTA_FRAME));
    expect(calls).toEqual(['configure', 'key', 'delta']);
    expect(ask).not.toHaveBeenCalled();
  });

  it('throws away what waits and asks for a key frame when it falls behind', () => {
    const { reader: r, decoder, calls, ask } = reader();
    r.text(announcement);
    r.binary(frame(KEY_FRAME));
    decoder.waiting = 5;
    r.binary(frame(DELTA_FRAME));
    expect(calls).toEqual(['configure', 'key', 'reset', 'configure']);
    expect(ask).toHaveBeenCalledTimes(1);
    expect(r.counts).toMatchObject({ fellBehind: 1, skipped: 6 });

    // Everything until the key frame is skipped, and the request is not repeated.
    r.binary(frame(DELTA_FRAME));
    r.binary(frame(DELTA_FRAME));
    expect(ask).toHaveBeenCalledTimes(1);
    r.binary(frame(KEY_FRAME));
    r.binary(frame(DELTA_FRAME));
    expect(calls).toEqual(['configure', 'key', 'reset', 'configure', 'key', 'delta']);
  });

  it('uses the key frame that arrives just as it falls behind', () => {
    const { reader: r, decoder, calls, ask } = reader();
    r.text(announcement);
    r.binary(frame(KEY_FRAME));
    decoder.waiting = 9;
    r.binary(frame(KEY_FRAME));
    expect(calls).toEqual(['configure', 'key', 'reset', 'configure', 'key']);
    expect(ask).toHaveBeenCalledTimes(1);
  });

  it('starts again from a key frame after a decoder error', () => {
    const { reader: r, calls, ask } = reader();
    r.text(announcement);
    r.binary(frame(KEY_FRAME));
    r.decoderFailed();
    r.binary(frame(DELTA_FRAME));
    r.binary(frame(KEY_FRAME));
    expect(calls).toEqual(['configure', 'key', 'reset', 'configure', 'key']);
    expect(ask).toHaveBeenCalledTimes(1);
    expect(r.counts.decoderErrors).toBe(1);
  });

  it('does nothing about a decoder error before any format', () => {
    const { reader: r, calls, ask } = reader();
    r.decoderFailed();
    expect(calls).toEqual([]);
    expect(ask).not.toHaveBeenCalled();
  });

  it('asks in the words the shell understands', () => {
    expect(JSON.parse(KEY_FRAME_REQUEST)).toEqual({ type: 'keyframe' });
  });
});
