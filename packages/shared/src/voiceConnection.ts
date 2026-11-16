/**
 * What a client and the server tell each other about the state of a voice
 * connection, beyond "joined" and "left": an attempt to join that is still
 * running or has failed, and the trouble of someone who is in the channel.
 * See docs/systems/voice.md, "Connection states".
 */

/** An attempt to join a voice channel, as its client reports it. `idle` withdraws it. */
export const VOICE_CONNECTING_STATES = ['connecting', 'failed', 'idle'] as const;
export type VoiceConnectingState = (typeof VOICE_CONNECTING_STATES)[number];

export function isVoiceConnectingState(value: unknown): value is VoiceConnectingState {
  return typeof value === 'string' && (VOICE_CONNECTING_STATES as readonly string[]).includes(value);
}

/**
 * Why a first connection did not come up. A closed list: the code travels to
 * every member who can see the channel, so it must not carry free text.
 *
 * - `media_unreachable`: signalling worked, the media path did not come up in time.
 * - `server_unreachable`: the voice server did not answer.
 * - `not_allowed`: the voice server refused the join.
 * - `token_failed`: the instance did not issue a token.
 * - `connect_failed`: anything else.
 */
export const VOICE_CONNECT_FAILURE_REASONS = [
  'media_unreachable',
  'server_unreachable',
  'not_allowed',
  'token_failed',
  'connect_failed',
] as const;
export type VoiceConnectFailureReason = (typeof VOICE_CONNECT_FAILURE_REASONS)[number];

export function isVoiceConnectFailureReason(value: unknown): value is VoiceConnectFailureReason {
  return typeof value === 'string' && (VOICE_CONNECT_FAILURE_REASONS as readonly string[]).includes(value);
}

/** One member's attempt, as the server relays it and as a snapshot lists it. */
export interface VoiceConnectingEntry {
  userId: string;
  state: Exclude<VoiceConnectingState, 'idle'>;
  /** Present only with `failed`. */
  reason?: VoiceConnectFailureReason;
}

/**
 * Trouble of a member who is in the channel. Each flag is absent when false,
 * so a status from an older client or server reads as "no trouble".
 */
export interface VoiceLinkFlags {
  /** The client lost its voice connection and is restoring it. Reported by the client. */
  isReconnecting?: boolean;
  /** The client has no microphone access, so the member cannot be heard. Reported by the client. */
  isMicUnavailable?: boolean;
  /** The client went silent: its socket closed without a leave, or it stopped sending heartbeats. Set by the server only. */
  isUnresponsive?: boolean;
}

/** What a member's client reports about itself while in voice, plus the flags above. */
export interface VoiceUserStatus extends VoiceLinkFlags {
  isMuted: boolean;
  isDeafened: boolean;
  isCameraOn: boolean;
  isScreenSharing: boolean;
}

/** How often a client in voice tells the server its page is alive. */
export const VOICE_HEARTBEAT_INTERVAL_MS = 10_000;
/**
 * Silence after which the server marks a member unresponsive while their
 * socket is still open. Two heartbeats may be lost before it trips: a hidden
 * page's timers run late, and one late beat must not flag anyone.
 */
export const VOICE_UNRESPONSIVE_AFTER_MS = 25_000;
/** Silence on an open socket after which the server frees the member's place. */
export const VOICE_SILENT_REMOVAL_MS = 90_000;
/** How long a `connecting` report stands without being repeated. */
export const VOICE_CONNECTING_TTL_MS = 60_000;
/** How long a `failed` report stays visible to the others. */
export const VOICE_CONNECT_FAILED_TTL_MS = 30_000;

/**
 * The one connection mark a row shows, most serious first. `failed` and
 * `unresponsive` share a mark: either way the member is listed but cannot be
 * reached.
 */
export const VOICE_CONNECTION_MARKS = [
  'failed',
  'unresponsive',
  'reconnecting',
  'lost',
  'mic-unavailable',
  'weak',
  'connecting',
] as const;
export type VoiceConnectionMark = (typeof VOICE_CONNECTION_MARKS)[number];

export interface VoiceConnectionMarkInput extends VoiceLinkFlags {
  /** The member's attempt to join, when they are not in the channel yet. */
  connecting?: VoiceConnectingEntry['state'] | null;
  /** LiveKit's verdict on the member's network, when they are in the room. */
  quality?: 'excellent' | 'good' | 'poor' | 'lost' | 'unknown' | null;
}

/** The mark for a member, or null when nothing is wrong. */
export function resolveVoiceConnectionMark(input: VoiceConnectionMarkInput): VoiceConnectionMark | null {
  if (input.connecting === 'failed') return 'failed';
  if (input.isUnresponsive) return 'unresponsive';
  if (input.isReconnecting) return 'reconnecting';
  if (input.quality === 'lost') return 'lost';
  if (input.isMicUnavailable) return 'mic-unavailable';
  if (input.quality === 'poor') return 'weak';
  if (input.connecting === 'connecting') return 'connecting';
  return null;
}
