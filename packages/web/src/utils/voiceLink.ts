/**
 * The client's side of the voice connection states (docs/systems/voice.md,
 * "Connection states"): telling the instance that hosts a voice channel that
 * this client is connecting to it or has failed to, keeping the watchdog
 * heartbeat going while in the channel, and naming the reason a first
 * connection did not come up.
 *
 * Everything here is sent only to an instance that said it understands it
 * (`supportsVoiceLink` in its `ready`): an older one answers every unknown
 * event with an error.
 */
import { create } from 'zustand';
import { ConnectionError, ConnectionErrorReason } from 'livekit-client';
import {
  VOICE_HEARTBEAT_INTERVAL_MS,
  type VoiceConnectFailureReason,
  type VoiceConnectingState,
} from '@backspace/shared/src/voiceConnection';
import { wsSend } from '../hooks/useWebSocket';
import { getChannelOrigin } from '../stores/spaceStore';

/** Which instances relay voice connection states, per origin. */
export const useVoiceLinkStore = create<{
  hosts: Record<string, boolean>;
  setHost: (origin: string, supported: boolean) => void;
  reset: () => void;
}>((set) => ({
  hosts: {},
  setHost: (origin, supported) => set((state) => ({ hosts: { ...state.hosts, [origin]: supported } })),
  reset: () => set({ hosts: {} }),
}));

function hostSupports(origin: string): boolean {
  return useVoiceLinkStore.getState().hosts[origin] === true;
}

/** Where a first connection stopped. */
export type ConnectStage = 'token' | 'room';

/**
 * The reason code for a first connection that failed. `stage` is where it
 * stopped: before the instance issued a token, or while joining the room.
 */
export function classifyConnectFailure(error: unknown, stage: ConnectStage): VoiceConnectFailureReason {
  if (stage === 'token') return 'token_failed';

  const message = error instanceof Error ? error.message : '';
  // Signalling answered and the media path did not come up: the SDK reports
  // it as an internal error, or as a plain one naming the transport.
  if (/could not establish (pc|publisher|subscriber) connection/i.test(message)) return 'media_unreachable';

  if (error instanceof ConnectionError) {
    switch (error.reason) {
      case ConnectionErrorReason.NotAllowed:
        return 'not_allowed';
      case ConnectionErrorReason.ServerUnreachable:
      case ConnectionErrorReason.WebSocket:
      case ConnectionErrorReason.ServiceNotFound:
      case ConnectionErrorReason.Timeout:
        return 'server_unreachable';
      default:
        return 'connect_failed';
    }
  }
  return 'connect_failed';
}

/** The attempt this client has told an instance about and not ended yet. */
let announced: { channelId: string; origin: string } | null = null;

/**
 * Tell the channel's instance about this client's attempt to join it.
 * `idle` ends whatever attempt was announced, whichever channel it was for.
 */
export function announceVoiceAttempt(
  channelId: string | null,
  state: VoiceConnectingState,
  reason?: VoiceConnectFailureReason,
): void {
  if (state === 'idle') {
    if (!announced) return;
    const ended = announced;
    announced = null;
    if (hostSupports(ended.origin)) {
      wsSend({ type: 'voice_connecting', channelId: ended.channelId, state: 'idle' }, ended.origin);
    }
    return;
  }
  if (!channelId) return;
  const origin = getChannelOrigin(channelId);
  if (!hostSupports(origin)) return;
  // An attempt for a channel on another instance ends there first.
  if (announced && announced.origin !== origin) announceVoiceAttempt(null, 'idle');
  announced = { channelId, origin };
  wsSend({ type: 'voice_connecting', channelId, state, ...(state === 'failed' && reason ? { reason } : {}) }, origin);
}

/** The join the attempt led to made it moot: the instance has ended it itself. */
export function voiceAttemptCompleted(): void {
  announced = null;
}

let heartbeatTimer: ReturnType<typeof setInterval> | null = null;

/**
 * Start telling `origin` every few seconds that this page is alive in voice.
 * One beat goes out at once, so the instance starts judging this client by
 * its silence from the moment it joined.
 */
export function startVoiceHeartbeat(origin: string): void {
  stopVoiceHeartbeat();
  if (!hostSupports(origin)) return;
  wsSend({ type: 'voice_heartbeat' }, origin);
  heartbeatTimer = setInterval(() => {
    wsSend({ type: 'voice_heartbeat' }, origin);
  }, VOICE_HEARTBEAT_INTERVAL_MS);
}

export function stopVoiceHeartbeat(): void {
  if (heartbeatTimer === null) return;
  clearInterval(heartbeatTimer);
  heartbeatTimer = null;
}

/** Test seam. */
export function resetVoiceLinkForTest(): void {
  stopVoiceHeartbeat();
  announced = null;
  useVoiceLinkStore.getState().reset();
}
