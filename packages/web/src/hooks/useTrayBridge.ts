import { useEffect } from 'react';
import { useAuthStore, selectMyChosenStatus } from '../stores/authStore';
import { useChatStore } from '../stores/chatStore';
import { useHomeConnectionStore } from '../stores/homeConnectionStore';
import { useSpaceStore } from '../stores/spaceStore';
import { useVoiceStore } from '../stores/voiceStore';
import { isElectron } from '../platform/platform';
import { onTrayAction, updateTrayContext, updateTrayState } from '../platform/notifications';
import { onTrayCelebrate } from '../utils/trayMoments';
import {
  JOY_DURATION_MS,
  pickTrayState,
  sameTrayContext,
  type TrayAction,
  type TrayContext,
  type TrayState,
} from '../utils/trayState';
import { handleDisconnectAction, toggleDeafenFromControl, toggleMuteFromControl } from '../utils/voiceActions';
import i18n from '../i18n';

/** Whether anyone but the user is typing in a DM or in the channel open on screen. */
export function someoneTypingToMe(
  typingUsers: ReadonlyMap<string, readonly { userId: string }[]>,
  watchedChannelIds: ReadonlySet<string>,
  myIds: ReadonlySet<string>,
): boolean {
  for (const [channelId, users] of typingUsers) {
    if (!watchedChannelIds.has(channelId)) continue;
    if (users.some((user) => !myIds.has(user.userId))) return true;
  }
  return false;
}

/** The name the tray menu gives the call the user is in, or null outside one. */
function currentCallName(): string | null {
  const { currentVoiceChannelId, activeDmCall } = useVoiceStore.getState();
  if (!currentVoiceChannelId && !activeDmCall) return null;
  const channel = currentVoiceChannelId
    ? useSpaceStore.getState().channels.find((candidate) => candidate.id === currentVoiceChannelId)
    : undefined;
  if (channel?.name) return channel.name;
  return i18n.t(activeDmCall ? 'voice:status.dmCall' : 'voice:status.voiceChannel');
}

function readTrayContext(): TrayContext {
  const auth = useAuthStore.getState();
  const voice = useVoiceStore.getState();
  const callName = currentCallName();
  return {
    signedIn: auth.user !== null,
    voice: callName === null ? null : { channelName: callName },
    muted: voice.isMuted,
    deafened: voice.isDeafened,
    status: selectMyChosenStatus(auth),
  };
}

function myIds(): Set<string> {
  const { user, myRowIds } = useAuthStore.getState();
  const ids = new Set<string>(myRowIds.values());
  if (user) ids.add(user.id);
  return ids;
}

function readTrayState(celebrating: boolean): TrayState {
  const voice = useVoiceStore.getState();
  const chat = useChatStore.getState();
  const local = voice.participants.find((participant) => participant.isLocal);
  const watched = new Set(useSpaceStore.getState().dmChannels.map((dm) => dm.id));
  if (chat.currentChannelId) watched.add(chat.currentChannelId);
  return pickTrayState({
    homeConnection: useHomeConnectionStore.getState().status,
    voiceConnecting: voice.voiceConnectionStatus === 'connecting' || voice.voiceConnectionStatus === 'reconnecting',
    isScreenSharing: voice.isScreenSharing,
    isSpeaking: local !== undefined && !voice.isMuted && voice.speakingParticipantIds.has(local.identity),
    unreadCount: chat.unreadChannels.size,
    someoneTyping: someoneTypingToMe(chat.typingUsers, watched, myIds()),
    celebrating,
    chosenStatus: selectMyChosenStatus(useAuthStore.getState()),
  });
}

/** Carries out a quick control clicked in the tray menu, as the voice bar or status picker would. */
export function runTrayAction(action: TrayAction): void {
  switch (action.type) {
    case 'toggleMute':
      toggleMuteFromControl();
      return;
    case 'toggleDeafen':
      toggleDeafenFromControl();
      return;
    case 'disconnect':
      handleDisconnectAction();
      return;
    case 'setStatus':
      useAuthStore.getState().updateProfile({ status: action.status }).catch((err: unknown) => {
        console.warn('[tray] could not change the status:', err);
      });
      return;
  }
}

/**
 * Keeps the desktop tray in step with the app: the character's state (and so
 * its animation) and the quick controls in its menu, and runs the controls
 * clicked there. Does nothing outside the desktop app.
 */
export function useTrayBridge(): void {
  useEffect(() => {
    if (!isElectron()) return undefined;
    let lastState: TrayState | null = null;
    let lastContext: TrayContext | null = null;
    let celebrating = false;
    let joyTimer: ReturnType<typeof setTimeout> | null = null;

    const push = () => {
      const state = readTrayState(celebrating);
      if (state !== lastState) {
        lastState = state;
        updateTrayState(state);
      }
      const context = readTrayContext();
      if (!lastContext || !sameTrayContext(context, lastContext)) {
        lastContext = context;
        updateTrayContext(context);
      }
    };

    const stopCelebrating = onTrayCelebrate(() => {
      celebrating = true;
      if (joyTimer) clearTimeout(joyTimer);
      joyTimer = setTimeout(() => {
        celebrating = false;
        joyTimer = null;
        push();
      }, JOY_DURATION_MS);
      push();
    });

    push();
    const unsubscribers = [
      useHomeConnectionStore.subscribe(push),
      useVoiceStore.subscribe(push),
      useChatStore.subscribe(push),
      useAuthStore.subscribe(push),
      useSpaceStore.subscribe(push),
      onTrayAction(runTrayAction),
      stopCelebrating,
    ];
    return () => {
      if (joyTimer) clearTimeout(joyTimer);
      unsubscribers.forEach((unsubscribe) => unsubscribe());
    };
  }, []);
}
