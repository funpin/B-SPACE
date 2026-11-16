// Dev-only workbench for the voice connection marks. Nothing in the app
// imports this file; `dev-voice-connection.html` is its only entry. It exists
// so every state of a member's connection can be looked at and screenshotted
// without a voice server, a second client or a broken network.
//
// The app's own dev-only `?lang=` picks the language (en, ru, de, pt, zh).
//
// Left: the real participant row, once per mark, as the member's own row and
// as someone else's, with the tooltip text written out beside it. Right: the
// real channel list fed with a store state that has one member in each
// condition, so the rows are seen together and in their real width.
import { createRoot } from 'react-dom/client';
import type { MemberWithUser } from '@backspace/shared';
import {
  VOICE_CONNECTION_MARKS,
  type VoiceConnectionMark,
  type VoiceUserStatus,
} from '@backspace/shared/src/voiceConnection';
import { VoiceChannel } from '../components/voice/VoiceChannel';
import { VoiceUserRow } from '../components/voice/VoiceUserRow';
import { useAuthStore } from '../stores/authStore';
import { useSpaceStore } from '../stores/spaceStore';
import { useVoiceStore } from '../stores/voiceStore';
import { describeVoiceConnectionMark } from '../utils/voiceConnectionText';
import { initI18n } from '../i18n';
import { initializeInterfaceScale } from '../platform/interfaceScale';
import '../styles/globals.css';

const CHANNEL = 'voice-1';
const SPACE = 'space-1';

const PEOPLE: { id: string; name: string }[] = [
  { id: '1', name: 'funpin' },
  { id: '2', name: 'nika' },
  { id: '3', name: 'leo' },
  { id: '4', name: 'vera' },
  { id: '5', name: 'marsel' },
  { id: '6', name: 'akk0' },
  { id: '7', name: 'fox' },
  { id: '8', name: 'mira' },
];

function member({ id, name }: { id: string; name: string }): MemberWithUser {
  return {
    userId: id,
    user: { id, username: name, displayName: name, avatar: null },
    roles: [],
  } as unknown as MemberWithUser;
}

function participant(id: string, name: string, isLocal: boolean) {
  return {
    identity: `${id}:${name}`,
    userId: id,
    username: name,
    homeUserId: null,
    isMuted: false,
    isDeafened: false,
    isCameraOn: false,
    isScreenSharing: false,
    isLocal,
    audioTrack: null,
    videoTrack: null,
    screenTrack: null,
    screenAudioTrack: null,
    lkVideoTrack: null,
    lkScreenTrack: null,
    cachedUser: null,
  };
}

const quiet: VoiceUserStatus = { isMuted: false, isDeafened: false, isCameraOn: false, isScreenSharing: false };

/** One member in each condition: 1 is the viewer and is fine, 7 is connecting, 8 failed. */
function seedStores(): void {
  useAuthStore.setState({ user: { id: '1', username: 'funpin' }, myRowIds: new Map() } as never);
  useSpaceStore.setState({
    members: PEOPLE.map(member),
    channelToSpaceMap: new Map([[CHANNEL, SPACE]]),
    channelOriginMap: new Map(),
  } as never);
  const inChannel = PEOPLE.slice(0, 6);
  useVoiceStore.setState({
    currentVoiceChannelId: CHANNEL,
    isLiveKitConnected: true,
    voiceConnectionStatus: 'connected',
    participants: inChannel.map((person, index) => participant(person.id, person.name, index === 0)),
    voiceUsers: new Map([[CHANNEL, inChannel.map((person) => person.id)]]),
    voiceChannelElapsedSeconds: new Map(),
    connectionQuality: 'good',
    connectionQualities: new Map([['2:nika', 'poor'], ['3:leo', 'lost']]),
    voiceUserStates: new Map<string, VoiceUserStatus>([
      ['2', { ...quiet, isMuted: true }],
      ['4', { ...quiet, isReconnecting: true }],
      ['5', { ...quiet, isMicUnavailable: true }],
      ['6', { ...quiet, isUnresponsive: true }],
    ]),
    voiceConnecting: new Map([[CHANNEL, [
      { userId: '7', state: 'connecting' as const },
      { userId: '8', state: 'failed' as const, reason: 'media_unreachable' as const },
    ]]]),
    spaceMutedUserIds: new Set(),
    spaceDeafenedUserIds: new Set(),
    permissionMutedUserIds: new Set(),
    participantMutes: new Map(),
    unwatchedCameras: new Set(),
    speakingUserIds: new Set(['1']),
  } as never);
}

function MarkRow({ mark, isSelf }: { mark: VoiceConnectionMark; isSelf: boolean }) {
  const label = describeVoiceConnectionMark(mark, {
    isSelf,
    name: 'nika',
    reason: mark === 'failed' ? 'media_unreachable' : null,
  });
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '220px 1fr', gap: 16, alignItems: 'center' }}>
      <div className="bg-surface-channel rounded-lg" style={{ padding: '4px 8px' }}>
        <VoiceUserRow
          size="compact"
          userId={isSelf ? '1' : '2'}
          displayName={isSelf ? 'funpin' : 'nika'}
          avatar={null}
          connectionMark={{ mark, label }}
          pending={mark === 'connecting' || mark === 'failed'}
        />
      </div>
      <span className="text-xs text-txt-secondary">{label}</span>
    </div>
  );
}

function Workbench() {
  // Least serious first, the order a connection goes wrong in.
  const marks = [...VOICE_CONNECTION_MARKS].reverse();
  return (
    <div
      className="bg-surface-base text-txt-primary"
      style={{ minHeight: 'calc(100 * var(--app-vh))', padding: 32, display: 'flex', gap: 48, flexWrap: 'wrap', alignItems: 'flex-start' }}
    >
      <section style={{ display: 'flex', flexDirection: 'column', gap: 20, flex: '1 1 520px', minWidth: 0 }}>
        <h1 className="text-lg font-semibold">Voice connection marks</h1>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <h2 className="text-xs text-txt-tertiary">Someone else's row</h2>
          {marks.map((mark) => <MarkRow key={mark} mark={mark} isSelf={false} />)}
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <h2 className="text-xs text-txt-tertiary">The viewer's own row</h2>
          {marks.map((mark) => <MarkRow key={mark} mark={mark} isSelf />)}
        </div>
      </section>

      <section style={{ display: 'flex', flexDirection: 'column', gap: 12, width: 260 }}>
        <h2 className="text-xs text-txt-tertiary">The channel list, one member in each condition</h2>
        <div className="bg-surface-channel rounded-xl" style={{ padding: 8 }}>
          <VoiceChannel channelId={CHANNEL} channelName="voice" onClick={() => undefined} />
        </div>
      </section>
    </div>
  );
}

async function start(): Promise<void> {
  initializeInterfaceScale();
  await initI18n();
  seedStores();
  const host = document.getElementById('root');
  if (!host) throw new Error('#root is missing');
  createRoot(host).render(<Workbench />);
}

void start();
