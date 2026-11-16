import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  VOICE_CONNECTING_TTL_MS,
  VOICE_CONNECT_FAILED_TTL_MS,
  VOICE_SILENT_REMOVAL_MS,
  VOICE_UNRESPONSIVE_AFTER_MS,
} from '@backspace/shared/src/voiceConnection.js';
import { VoiceAttempts, VoiceWatchdog, type VoiceAttemptNotice } from './voiceLink.js';

describe('VoiceAttempts', () => {
  let notices: VoiceAttemptNotice[];
  let attempts: VoiceAttempts;
  const socket = {};

  beforeEach(() => {
    vi.useFakeTimers();
    notices = [];
    attempts = new VoiceAttempts((notice) => notices.push(notice));
  });

  afterEach(() => {
    attempts.reset();
    vi.useRealTimers();
  });

  it('announces a new attempt and lists it for its channel', () => {
    attempts.report('ann', socket, 'voice-1', 'space-1', 'connecting');

    expect(notices).toEqual([{ userId: 'ann', channelId: 'voice-1', spaceId: 'space-1', state: 'connecting' }]);
    expect(attempts.forChannel('voice-1')).toEqual([{ userId: 'ann', state: 'connecting' }]);
    expect(attempts.forChannel('voice-2')).toEqual([]);
  });

  it('does not announce a repeated report, but restarts its lifetime', () => {
    attempts.report('ann', socket, 'voice-1', 'space-1', 'connecting');
    vi.advanceTimersByTime(VOICE_CONNECTING_TTL_MS - 1000);
    attempts.report('ann', socket, 'voice-1', 'space-1', 'connecting');
    vi.advanceTimersByTime(VOICE_CONNECTING_TTL_MS - 1000);

    expect(notices).toHaveLength(1);
    expect(attempts.forChannel('voice-1')).toHaveLength(1);
  });

  it('withdraws a connecting report nobody repeated', () => {
    attempts.report('ann', socket, 'voice-1', 'space-1', 'connecting');
    vi.advanceTimersByTime(VOICE_CONNECTING_TTL_MS);

    expect(notices.at(-1)).toEqual({ userId: 'ann', channelId: 'voice-1', spaceId: 'space-1', state: 'idle' });
    expect(attempts.forChannel('voice-1')).toEqual([]);
  });

  it('carries the reason of a failure and shows it for a shorter time', () => {
    attempts.report('ann', socket, 'voice-1', 'space-1', 'connecting');
    attempts.report('ann', socket, 'voice-1', 'space-1', 'failed', 'media_unreachable');

    expect(notices.at(-1)).toEqual({
      userId: 'ann', channelId: 'voice-1', spaceId: 'space-1', state: 'failed', reason: 'media_unreachable',
    });
    expect(attempts.forChannel('voice-1')).toEqual([{ userId: 'ann', state: 'failed', reason: 'media_unreachable' }]);

    vi.advanceTimersByTime(VOICE_CONNECT_FAILED_TTL_MS);
    expect(notices.at(-1)?.state).toBe('idle');
  });

  it('gives a failure without a reason the general one, and a connecting report none', () => {
    attempts.report('ann', socket, 'voice-1', 'space-1', 'failed');
    expect(notices.at(-1)?.reason).toBe('connect_failed');

    attempts.report('bob', socket, 'voice-1', 'space-1', 'connecting', 'not_allowed');
    expect(notices.at(-1)).toEqual({ userId: 'bob', channelId: 'voice-1', spaceId: 'space-1', state: 'connecting' });
  });

  it('ends the attempt in the old channel when the user tries another', () => {
    attempts.report('ann', socket, 'voice-1', 'space-1', 'connecting');
    attempts.report('ann', socket, 'voice-2', 'space-2', 'connecting');

    expect(notices.slice(1)).toEqual([
      { userId: 'ann', channelId: 'voice-1', spaceId: 'space-1', state: 'idle' },
      { userId: 'ann', channelId: 'voice-2', spaceId: 'space-2', state: 'connecting' },
    ]);
    // The first report's timer must not end the second attempt.
    vi.advanceTimersByTime(VOICE_CONNECTING_TTL_MS - 1);
    expect(attempts.forChannel('voice-2')).toHaveLength(1);
  });

  it('withdraws once, and says nothing when there is no attempt', () => {
    attempts.withdraw('ann');
    expect(notices).toEqual([]);

    attempts.report('ann', socket, 'voice-1', 'space-1', 'connecting');
    attempts.withdraw('ann');
    attempts.withdraw('ann');
    expect(notices.filter((notice) => notice.state === 'idle')).toHaveLength(1);
  });

  it('ends an attempt when the socket that reported it closes, and only then', () => {
    const otherTab = {};
    attempts.report('ann', socket, 'voice-1', 'space-1', 'connecting');

    attempts.ownerClosed('ann', otherTab);
    expect(attempts.forChannel('voice-1')).toHaveLength(1);

    attempts.ownerClosed('ann', socket);
    expect(attempts.forChannel('voice-1')).toEqual([]);
    expect(notices.at(-1)?.state).toBe('idle');
  });
});

describe('VoiceWatchdog', () => {
  const everyone = () => true;

  it('never judges a client that sends no heartbeats', () => {
    const watchdog = new VoiceWatchdog();
    watchdog.touch('old-client', 0, false);

    expect(watchdog.sweep(VOICE_SILENT_REMOVAL_MS * 10, everyone)).toEqual({ unresponsive: [], remove: [] });
  });

  it('marks a client that stopped sending them, then frees its place', () => {
    const watchdog = new VoiceWatchdog();
    watchdog.touch('ann', 0, true);

    expect(watchdog.sweep(VOICE_UNRESPONSIVE_AFTER_MS, everyone).unresponsive).toEqual([]);
    expect(watchdog.sweep(VOICE_UNRESPONSIVE_AFTER_MS + 1, everyone)).toEqual({ unresponsive: ['ann'], remove: [] });
    expect(watchdog.sweep(VOICE_SILENT_REMOVAL_MS + 1, everyone)).toEqual({ unresponsive: [], remove: ['ann'] });
    // Removed means forgotten: the next sweep has nothing to say about them.
    expect(watchdog.sweep(VOICE_SILENT_REMOVAL_MS * 2, everyone)).toEqual({ unresponsive: [], remove: [] });
  });

  it('counts any voice message as a sign of life once heartbeats were seen', () => {
    const watchdog = new VoiceWatchdog();
    watchdog.touch('ann', 0, true);
    watchdog.touch('ann', 20_000, false);

    expect(watchdog.sweep(20_000 + VOICE_UNRESPONSIVE_AFTER_MS, everyone).unresponsive).toEqual([]);
    expect(watchdog.sweep(20_001 + VOICE_UNRESPONSIVE_AFTER_MS, everyone).unresponsive).toEqual(['ann']);
  });

  it('forgets users who no longer hold a place, and users it is told to forget', () => {
    const watchdog = new VoiceWatchdog();
    watchdog.touch('ann', 0, true);
    watchdog.touch('bob', 0, true);

    expect(watchdog.sweep(VOICE_UNRESPONSIVE_AFTER_MS + 1, (userId) => userId === 'bob').unresponsive).toEqual(['bob']);
    // ann was dropped by the sweep above even though she is "watched" again.
    expect(watchdog.sweep(VOICE_UNRESPONSIVE_AFTER_MS + 2, everyone).unresponsive).toEqual(['bob']);

    watchdog.forget('bob');
    expect(watchdog.sweep(VOICE_SILENT_REMOVAL_MS + 1, everyone)).toEqual({ unresponsive: [], remove: [] });
  });
});
