/**
 * Bookkeeping behind the voice connection states the server relays
 * (docs/systems/voice.md, "Connection states"): the attempts to join a voice
 * channel that members report, and the watchdog that notices a member whose
 * client has gone silent.
 *
 * Both are plain state with the effects injected, so they run under fake
 * timers; `handler.ts` and `events.ts` own the sockets and the broadcasts.
 * Nothing here is persisted: an attempt lives for seconds, and a restart of
 * the server ends every voice session anyway.
 */
import {
  VOICE_CONNECTING_TTL_MS,
  VOICE_CONNECT_FAILED_TTL_MS,
  VOICE_SILENT_REMOVAL_MS,
  VOICE_UNRESPONSIVE_AFTER_MS,
  type VoiceConnectFailureReason,
  type VoiceConnectingEntry,
  type VoiceConnectingState,
} from '@backspace/shared/src/voiceConnection.js';

/** What the others are told about one member's attempt. `idle` ends it. */
export interface VoiceAttemptNotice {
  userId: string;
  channelId: string;
  spaceId: string;
  state: VoiceConnectingState;
  reason?: VoiceConnectFailureReason;
}

interface VoiceAttempt {
  channelId: string;
  spaceId: string;
  state: VoiceConnectingEntry['state'];
  reason?: VoiceConnectFailureReason;
  /** The socket that reported it; the attempt ends with that socket. */
  owner: object;
  timer: ReturnType<typeof setTimeout>;
}

/**
 * One attempt per user: a client joins one voice channel at a time, so a
 * report for another channel replaces the earlier one.
 */
export class VoiceAttempts {
  private readonly attempts = new Map<string, VoiceAttempt>();

  constructor(private readonly announce: (notice: VoiceAttemptNotice) => void) {}

  /**
   * Record that `userId` is connecting to `channelId` or has failed to. A
   * repeat of the same report only restarts its lifetime: clients repeat
   * `connecting` on every retry, and the others have already been told.
   */
  report(
    userId: string,
    owner: object,
    channelId: string,
    spaceId: string,
    state: VoiceConnectingEntry['state'],
    reason?: VoiceConnectFailureReason,
  ): void {
    const failureReason = state === 'failed' ? reason ?? 'connect_failed' : undefined;
    const existing = this.attempts.get(userId);
    const unchanged = existing !== undefined
      && existing.channelId === channelId
      && existing.state === state
      && existing.reason === failureReason;

    if (existing) {
      clearTimeout(existing.timer);
      if (existing.channelId !== channelId) {
        this.announce({ userId, channelId: existing.channelId, spaceId: existing.spaceId, state: 'idle' });
      }
    }

    const lifetime = state === 'failed' ? VOICE_CONNECT_FAILED_TTL_MS : VOICE_CONNECTING_TTL_MS;
    const timer = setTimeout(() => {
      // A later report replaced this one and owns the entry now.
      if (this.attempts.get(userId)?.timer === timer) this.withdraw(userId);
    }, lifetime);
    this.attempts.set(userId, { channelId, spaceId, state, reason: failureReason, owner, timer });

    if (!unchanged) {
      this.announce({ userId, channelId, spaceId, state, ...(failureReason ? { reason: failureReason } : {}) });
    }
  }

  /** End the user's attempt, telling the others when there was one. */
  withdraw(userId: string): void {
    const existing = this.attempts.get(userId);
    if (!existing) return;
    clearTimeout(existing.timer);
    this.attempts.delete(userId);
    this.announce({ userId, channelId: existing.channelId, spaceId: existing.spaceId, state: 'idle' });
  }

  /** The socket closed: an attempt it reported cannot finish. */
  ownerClosed(userId: string, owner: object): void {
    if (this.attempts.get(userId)?.owner === owner) this.withdraw(userId);
  }

  /** The attempts aimed at one channel, for a snapshot. */
  forChannel(channelId: string): VoiceConnectingEntry[] {
    const entries: VoiceConnectingEntry[] = [];
    for (const [userId, attempt] of this.attempts) {
      if (attempt.channelId !== channelId) continue;
      entries.push({ userId, state: attempt.state, ...(attempt.reason ? { reason: attempt.reason } : {}) });
    }
    return entries;
  }

  /** Drop everything without announcing. For shutdown and tests. */
  reset(): void {
    for (const attempt of this.attempts.values()) clearTimeout(attempt.timer);
    this.attempts.clear();
  }
}

export interface VoiceWatchdogVerdict {
  /** Silent past the first threshold: mark them, if they are not marked yet. */
  unresponsive: string[];
  /** Silent past the second: free their place. */
  remove: string[];
}

/**
 * Notices a member in voice whose page stopped talking while its socket stays
 * open: a frozen app answers the protocol-level ping (the browser does that
 * without the page), so the socket sweep never sees it.
 *
 * Only clients that have sent a heartbeat in this session are judged by
 * silence. An older client sends none and would otherwise look dead ten
 * seconds after it joined.
 */
export class VoiceWatchdog {
  private readonly heard = new Map<string, { at: number; beats: boolean }>();

  /** A voice message arrived from the socket that owns the user's session. */
  touch(userId: string, now: number, isHeartbeat: boolean): void {
    const entry = this.heard.get(userId);
    this.heard.set(userId, { at: now, beats: isHeartbeat || (entry?.beats ?? false) });
  }

  forget(userId: string): void {
    this.heard.delete(userId);
  }

  /**
   * Who has been silent for too long. `isWatched` says whether a user still
   * holds a place the watchdog is responsible for; the others are forgotten.
   */
  sweep(now: number, isWatched: (userId: string) => boolean): VoiceWatchdogVerdict {
    const verdict: VoiceWatchdogVerdict = { unresponsive: [], remove: [] };
    for (const [userId, entry] of this.heard) {
      if (!isWatched(userId)) {
        this.heard.delete(userId);
        continue;
      }
      if (!entry.beats) continue;
      const silence = now - entry.at;
      if (silence > VOICE_SILENT_REMOVAL_MS) verdict.remove.push(userId);
      else if (silence > VOICE_UNRESPONSIVE_AFTER_MS) verdict.unresponsive.push(userId);
    }
    for (const userId of verdict.remove) this.heard.delete(userId);
    return verdict;
  }

  reset(): void {
    this.heard.clear();
  }
}
