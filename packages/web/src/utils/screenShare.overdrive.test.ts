import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Track, type Room } from 'livekit-client';
import { applyOverdrive, resetOverdriveSupportForTests, type OverdriveOptions } from './screenShare';

const internals = vi.hoisted(() => ({ getPublisherPC: vi.fn(), getMediaStreamTrack: vi.fn() }));
vi.mock('./livekitInternals', () => internals);
vi.mock('./hwOverdrive', () => ({ activate: vi.fn(), deactivate: vi.fn() }));
vi.mock('../audio/AudioManager', () => ({
  AudioManager: { getInstance: () => ({ setInputVolume: vi.fn() }) },
}));

/**
 * The ceiling of a published share (bitrate, frame rate) is written to the
 * sender with priorities and a degradation preference. WebKit implements the
 * ceiling and not the rest, and rejects a call that carries the rest whole.
 */

const OPTIONS: OverdriveOptions = { maxBitrate: 8_000_000, maxFramerate: 60, degradationPreference: 'maintain-resolution' };

interface Written {
  encodings: Array<Record<string, unknown>>;
  degradationPreference?: string;
}

/** A sender that takes everything (Chromium) or only the ceiling (WebKit). */
function fakeCall(engine: 'chromium' | 'webkit' | 'broken', encodings: Array<Record<string, unknown>> = [{ active: true }]) {
  const written: Written[] = [];
  const track = { id: 'screen-track' };
  const sender = {
    track,
    getParameters: vi.fn(() => ({ encodings: encodings.map((encoding) => ({ ...encoding })) })),
    setParameters: vi.fn(async (params: Written) => {
      const extras = params.degradationPreference !== undefined
        || params.encodings.some((encoding) => 'priority' in encoding || 'networkPriority' in encoding);
      if (engine === 'broken') throw new DOMException('The sender is gone', 'InvalidStateError');
      if (engine === 'webkit' && extras) {
        throw new DOMException('Attempted to set an unimplemented parameter of RtpParameters.', 'OperationError');
      }
      written.push(params);
    }),
  };
  internals.getPublisherPC.mockReturnValue({ getSenders: () => [sender] });
  internals.getMediaStreamTrack.mockReturnValue(track);
  const room = {
    localParticipant: {
      getTrackPublications: () => [{ source: Track.Source.ScreenShare, track: {} }],
    },
  } as unknown as Room;
  return { room, sender, written };
}

beforeEach(() => {
  resetOverdriveSupportForTests();
  vi.spyOn(console, 'warn').mockImplementation(() => undefined);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('applyOverdrive', () => {
  it('writes the ceiling, the priorities and the degradation preference where the engine takes them', async () => {
    const { room, sender, written } = fakeCall('chromium');
    expect(await applyOverdrive(room, Track.Source.ScreenShare, OPTIONS)).toBe(true);
    expect(sender.setParameters).toHaveBeenCalledTimes(1);
    expect(written).toEqual([{
      encodings: [{ active: true, maxBitrate: 8_000_000, maxFramerate: 60, priority: 'high', networkPriority: 'high' }],
      degradationPreference: 'maintain-resolution',
    }]);
  });

  it('writes the ceiling alone where the engine refuses the rest', async () => {
    const { room, sender, written } = fakeCall('webkit');
    expect(await applyOverdrive(room, Track.Source.ScreenShare, OPTIONS)).toBe(true);
    // Refused whole, then read afresh and written without the rest.
    expect(sender.getParameters).toHaveBeenCalledTimes(2);
    expect(written).toEqual([{ encodings: [{ active: true, maxBitrate: 8_000_000, maxFramerate: 60 }] }]);
    expect(console.warn).not.toHaveBeenCalled();
  });

  it('does not ask an engine that refused the rest again', async () => {
    const { room, sender, written } = fakeCall('webkit');
    await applyOverdrive(room, Track.Source.ScreenShare, OPTIONS);
    sender.setParameters.mockClear();
    await applyOverdrive(room, Track.Source.ScreenShare, { ...OPTIONS, maxBitrate: 4_000_000 });
    expect(sender.setParameters).toHaveBeenCalledTimes(1);
    expect(written.at(-1)).toEqual({ encodings: [{ active: true, maxBitrate: 4_000_000, maxFramerate: 60 }] });
  });

  it('reports a call that failed for another reason, and keeps asking for everything', async () => {
    const broken = fakeCall('broken');
    expect(await applyOverdrive(broken.room, Track.Source.ScreenShare, OPTIONS)).toBe(false);
    expect(broken.sender.setParameters).toHaveBeenCalledTimes(1);
    expect(console.warn).toHaveBeenCalledTimes(1);

    const { room, written } = fakeCall('chromium');
    expect(await applyOverdrive(room, Track.Source.ScreenShare, OPTIONS)).toBe(true);
    expect(written[0]?.degradationPreference).toBe('maintain-resolution');
  });

  it('writes the top layer of a share with several', async () => {
    const { room, written } = fakeCall('chromium', [{ rid: 'q' }, { rid: 'f' }]);
    await applyOverdrive(room, Track.Source.ScreenShare, OPTIONS);
    expect(written[0]?.encodings[0]).toEqual({ rid: 'q' });
    expect(written[0]?.encodings[1]).toMatchObject({ rid: 'f', maxBitrate: 8_000_000, priority: 'high' });
  });

  it('is not ready while the sender has only its placeholder encoding', async () => {
    const { room, sender } = fakeCall('chromium', [{}]);
    expect(await applyOverdrive(room, Track.Source.ScreenShare, OPTIONS)).toBe(false);
    expect(sender.setParameters).not.toHaveBeenCalled();
  });
});
