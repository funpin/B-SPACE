import { describe, expect, it } from 'vitest';
import {
  KEYFRAME_ANSWER_TIMEOUT_MS,
  KEYFRAME_FORCE_COOLDOWN_MS,
  KeyframeRequestTracker,
  nudgedScale,
  readLayerSamples,
} from './keyframeWatchdog';

const layer = (keyRequests: number, keyFramesEncoded: number, id = 'out-1') => ({ id, keyRequests, keyFramesEncoded });

describe('KeyframeRequestTracker', () => {
  it('leaves an encoder that answers its keyframe requests alone', () => {
    const tracker = new KeyframeRequestTracker();
    expect(tracker.observe([layer(0, 1)], 0)).toBe(false);
    expect(tracker.observe([layer(1, 1)], 1000)).toBe(false);
    expect(tracker.observe([layer(1, 2)], 2000)).toBe(false);
    expect(tracker.observe([layer(1, 2)], 5000)).toBe(false);
  });

  it('forces a keyframe once a request has gone unanswered for the timeout', () => {
    const tracker = new KeyframeRequestTracker();
    tracker.observe([layer(0, 1)], 0);
    expect(tracker.observe([layer(1, 1)], 1000)).toBe(false);
    expect(tracker.observe([layer(3, 1)], 1000 + KEYFRAME_ANSWER_TIMEOUT_MS - 1)).toBe(false);
    expect(tracker.observe([layer(4, 1)], 1000 + KEYFRAME_ANSWER_TIMEOUT_MS)).toBe(true);
  });

  it('does not judge requests that arrived before the first look', () => {
    const tracker = new KeyframeRequestTracker();
    tracker.observe([layer(40, 1)], 0);
    expect(tracker.observe([layer(40, 1)], 10_000)).toBe(false);
  });

  it('forces at most once per cooldown, and again after it when still ignored', () => {
    const tracker = new KeyframeRequestTracker();
    tracker.observe([layer(0, 1)], 0);
    tracker.observe([layer(1, 1)], 1000);
    expect(tracker.observe([layer(2, 1)], 3000)).toBe(true);

    tracker.observe([layer(3, 1)], 3500);
    expect(tracker.observe([layer(4, 1)], 5500)).toBe(false);

    expect(tracker.observe([layer(5, 1)], 3000 + KEYFRAME_FORCE_COOLDOWN_MS)).toBe(true);
  });

  it('watches each layer on its own, so an answering backup layer cannot hide a stalled primary', () => {
    const tracker = new KeyframeRequestTracker();
    tracker.observe([layer(0, 1, 'h264'), layer(0, 1, 'vp8')], 0);
    tracker.observe([layer(1, 1, 'h264'), layer(1, 2, 'vp8')], 1000);
    expect(tracker.observe([layer(1, 1, 'h264'), layer(1, 2, 'vp8')], 3000)).toBe(true);
  });

  it('baselines a layer again after it leaves the stats', () => {
    const tracker = new KeyframeRequestTracker();
    tracker.observe([layer(0, 1)], 0);
    tracker.observe([layer(1, 1)], 1000);
    tracker.observe([], 2000);
    expect(tracker.observe([layer(5, 1)], 3000)).toBe(false);
  });
});

describe('readLayerSamples', () => {
  it('reads the active H.264 layers and their tallest frame, and nothing of VP9', () => {
    const entries: RTCStats[] = [
      { id: 'h264', type: 'codec', timestamp: 0, mimeType: 'video/H264' } as RTCStats,
      { id: 'vp9', type: 'codec', timestamp: 0, mimeType: 'video/VP9' } as RTCStats,
      { id: 'a', type: 'outbound-rtp', timestamp: 0, kind: 'video', codecId: 'h264', pliCount: 2, firCount: 1, keyFramesEncoded: 4, frameHeight: 1080, active: true } as RTCStats,
      // VP9 resizes without a keyframe: never nudged.
      { id: 'v', type: 'outbound-rtp', timestamp: 0, kind: 'video', codecId: 'vp9', pliCount: 9, keyFramesEncoded: 0, frameHeight: 1440, active: true } as RTCStats,
      { id: 'b', type: 'outbound-rtp', timestamp: 0, kind: 'video', pliCount: 0, keyFramesEncoded: 1, frameHeight: 540, active: false } as RTCStats,
      { id: 'c', type: 'outbound-rtp', timestamp: 0, kind: 'audio', pliCount: 9 } as RTCStats,
    ];
    const report = new Map(entries.map((entry) => [entry.id, entry])) as unknown as RTCStatsReport;

    expect(readLayerSamples(report)).toEqual({
      samples: [{ id: 'a', keyRequests: 3, keyFramesEncoded: 4 }],
      frameHeight: 1080,
    });
  });
});

describe('nudgedScale', () => {
  it('takes a few pixels off the encoded height', () => {
    const scale = nudgedScale(1, 1438)!;
    expect(Math.round(1438 / scale)).toBe(1434);
    expect(Math.round(720 / nudgedScale(2, 720)!)).toBe(358);
  });

  it('leaves a frame too small to nudge', () => {
    expect(nudgedScale(1, 30)).toBeNull();
    expect(nudgedScale(1, Number.NaN)).toBeNull();
  });
});
