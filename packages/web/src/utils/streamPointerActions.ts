import { getActiveRoom } from '../hooks/useLiveKit';
import type { ParticipantInfo } from '../hooks/useLiveKit';
import { useVoiceStore } from '../stores/voiceStore';
import { streamViewers } from './streamViewers';
import { encodeStreamPointer, encodeStreamPointerOverlay, streamPointerFor, type PicturePoint } from './streamPointerProtocol';

/**
 * Sends this client's pointer on `sharer`'s share to the people who can see
 * it: the sharer and everyone watching. Nobody else in the call is sent the
 * traffic. A move is lossy (the next one replaces it); the leave and a click
 * are reliable, because nothing follows them to make up for a lost one.
 */
export function publishStreamPointer(sharer: ParticipantInfo, point: PicturePoint | null, ping = false): void {
  const room = getActiveRoom();
  if (!room) return;
  const state = useVoiceStore.getState();
  const destinationIdentities = [
    sharer,
    ...streamViewers(sharer, state.participants, state.streamWatchers, state.watchingStreams),
  ]
    .filter((p) => !p.isLocal)
    .map((p) => p.identity);
  if (destinationIdentities.length === 0) return;
  room.localParticipant
    .publishData(encodeStreamPointer(streamPointerFor(sharer.identity, point, ping)), {
      reliable: point === null || ping,
      destinationIdentities,
    })
    .catch(() => { });
}

/**
 * Tells everyone in the room whether this client's desktop overlay of the
 * pointers is in its shared picture. Reliable: it changes rarely and nothing
 * follows to correct a lost one. Sent to the whole room rather than the
 * watchers, so someone who starts watching later already knows.
 */
export function publishStreamPointerOverlay(captured: boolean): void {
  const room = getActiveRoom();
  if (!room) return;
  room.localParticipant
    .publishData(encodeStreamPointerOverlay(captured), { reliable: true })
    .catch(() => { });
}
