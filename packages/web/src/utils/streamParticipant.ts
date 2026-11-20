/**
 * The viewer's side of the stream participant: the second LiveKit participant
 * a native client publishes its screen share through, while the user's own
 * participant stays in the page (docs/systems/voice.md, "The stream
 * participant").
 *
 * Nothing in the client shows a stream participant. Its share is its owner's
 * share: the functions here are the one place that says so, and everything
 * that goes from a participant to a share or back (the participant list, the
 * watch subscription, the share's lifecycle events, the statistics) goes
 * through them. Everything keyed by a sharer (watchers, pointers, the resume
 * memory, the republish tracker) stays keyed by the owner's identity, which is
 * also the identity the owner's page sends and receives data under.
 */
import { streamOwnerOf } from '@backspace/shared/src/streamParticipant';

/** What is read of a LiveKit participant here. */
export interface IdentifiedParticipant {
  identity: string;
  attributes?: Readonly<Record<string, string>>;
}

/**
 * Whether a participant is somebody's stream participant. Decided by the
 * attribute the server signs into the stream token, never by the identity's
 * look: no token lets a participant set its own attributes.
 */
export function isStreamParticipant(participant: IdentifiedParticipant): boolean {
  return streamOwnerOf(participant.attributes) !== null;
}

/**
 * The identity a participant's screen share is listed under: its owner's for
 * a stream participant, its own for anyone else.
 */
export function sharerIdentityOf(participant: IdentifiedParticipant): string {
  return streamOwnerOf(participant.attributes) ?? participant.identity;
}

/**
 * The participants whose publications can carry the screen share of the user
 * with `identity`: the user's own participant (a share published from the
 * page) and the user's stream participant (a share published from a native
 * shell). A stream participant carries nothing under its own identity.
 */
export function shareCarriersOf<P extends IdentifiedParticipant>(participants: Iterable<P>, identity: string): P[] {
  const carriers: P[] = [];
  for (const participant of participants) {
    if (sharerIdentityOf(participant) === identity) carriers.push(participant);
  }
  return carriers;
}

/**
 * The key a stream participant's connection quality is kept under, next to
 * its owner's own: the share and the voice travel over two connections.
 */
export function streamQualityKey(identity: string): string {
  return `${identity}:stream`;
}
