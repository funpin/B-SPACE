import { useMemo } from 'react';
import { useSpaceStore } from '../stores/spaceStore';
import { useVoiceStore } from '../stores/voiceStore';
import { parseFederatedUsername } from '../utils/identity';
import { getCanonicalUserView } from '../utils/userViewLookup';
import { voiceSessionOrigin } from '../utils/dmCall';
import type { ParticipantInfo } from './useLiveKit';
import type { User } from '@backspace/shared';

export interface VoiceParticipantMeta {
  displayName: string;
  avatar: string | null;
  user: User | null;
  origin: string;
}

/** What `resolveVoiceParticipantMeta` looks a participant up in. */
export interface VoiceParticipantMetaSources {
  members: ReturnType<typeof useSpaceStore.getState>['members'];
  spaces: ReturnType<typeof useSpaceStore.getState>['spaces'];
  dmChannels: ReturnType<typeof useSpaceStore.getState>['dmChannels'];
  channelOriginMap: ReturnType<typeof useSpaceStore.getState>['channelOriginMap'];
  sessionOrigin: string;
}

/** The current store contents, for a caller outside React. */
export function currentVoiceParticipantMetaSources(): VoiceParticipantMetaSources {
  const space = useSpaceStore.getState();
  return {
    members: space.members,
    spaces: space.spaces,
    dmChannels: space.dmChannels,
    channelOriginMap: space.channelOriginMap,
    sessionOrigin: voiceSessionOrigin(useVoiceStore.getState()),
  };
}

/**
 * Resolves display metadata (displayName, avatar, user) for a voice participant
 * by looking it up in space members, then DM members, then the user carried on
 * the participant, and `origin`, the instance that issued `user`.
 */
export function resolveVoiceParticipantMeta(
  participant: ParticipantInfo,
  sources: VoiceParticipantMetaSources,
): VoiceParticipantMeta {
  // 1. Try space members (primary — covers space voice channels)
  const member = sources.members.find(m => m.userId === participant.userId);
  if (member?.user) {
    const origin = sources.spaces.find(sp => sp.id === member.spaceId)?._instanceOrigin ?? '';
    const canonical = getCanonicalUserView(member.user as User, origin);
    const { baseName } = parseFederatedUsername(canonical.username);
    return {
      displayName: canonical.displayName ?? baseName,
      avatar: canonical.avatar ?? null,
      user: canonical,
      origin,
    };
  }

  // 2. Fallback to DM channel members (covers DM calls)
  for (const dm of sources.dmChannels) {
    const dmMember = dm.members?.find(m => m.id === participant.userId);
    if (dmMember) {
      const origin = sources.channelOriginMap.get(dm.id) ?? '';
      const canonical = getCanonicalUserView(dmMember as User, origin);
      const { baseName } = parseFederatedUsername(canonical.username);
      return {
        displayName: canonical.displayName ?? baseName,
        avatar: canonical.avatar ?? null,
        user: canonical,
        origin,
      };
    }
  }

  // 3. Fallback to cached user from ParticipantInfo (federation carry-forward).
  // Route through the userViews cache: a User captured from federation handoff
  // can be a stale stub view, and the cache may hold a fresher home view.
  // The row was issued by the instance hosting the call.
  if (participant.cachedUser) {
    const callOrigin = sources.sessionOrigin;
    const canonical = getCanonicalUserView(participant.cachedUser, callOrigin);
    const { baseName } = parseFederatedUsername(canonical.username);
    return {
      displayName: canonical.displayName ?? baseName,
      avatar: canonical.avatar ?? null,
      user: canonical,
      origin: callOrigin,
    };
  }

  // 4. Final fallback — parse username from LiveKit identity
  const { baseName } = parseFederatedUsername(participant.username);
  return { displayName: baseName, avatar: null, user: null as User | null, origin: '' };
}

/**
 * `resolveVoiceParticipantMeta` for a component.
 *
 * Reactive — re-renders when member data changes (e.g. user updates avatar mid-call).
 */
export function useVoiceParticipantMeta(participant: ParticipantInfo): VoiceParticipantMeta {
  const members = useSpaceStore((s) => s.members);
  const spaces = useSpaceStore((s) => s.spaces);
  const dmChannels = useSpaceStore((s) => s.dmChannels);
  const channelOriginMap = useSpaceStore((s) => s.channelOriginMap);
  const sessionOrigin = useVoiceStore(voiceSessionOrigin);

  return useMemo(
    () => resolveVoiceParticipantMeta(participant, { members, spaces, dmChannels, channelOriginMap, sessionOrigin }),
    [members, spaces, dmChannels, channelOriginMap, sessionOrigin, participant],
  );
}
