/**
 * The stream participant: the second LiveKit participant a native client
 * joins a call with to publish its screen share and the share's sound from
 * the shell, while the user's own participant (voice) stays in the page.
 * See docs/systems/voice.md, "The stream participant".
 *
 * A server marks it in the token it signs: the participant attribute
 * `streamOf` holds the identity of the user the stream belongs to. Clients
 * trust that attribute and nothing else, because a participant cannot set it
 * for itself (no token grants `canUpdateOwnMetadata`).
 */

/** The participant attribute a server signs into a stream token. */
export const STREAM_OF_ATTRIBUTE = 'streamOf';

/**
 * What a stream participant's identity starts with. It keeps the identity
 * apart from its owner's (LiveKit admits an identity once per room), and its
 * first part apart from any user id, so a client that does not know about
 * stream participants shows one more participant rather than the same user
 * twice.
 */
export const STREAM_IDENTITY_PREFIX = 'stream.';

/** The identity of the stream participant of the user whose identity is `ownerIdentity`. */
export function streamIdentityOf(ownerIdentity: string): string {
  return `${STREAM_IDENTITY_PREFIX}${ownerIdentity}`;
}

/**
 * The identity of the user a participant is the stream of, from the
 * participant's attributes; null for every other participant.
 */
export function streamOwnerOf(attributes: Readonly<Record<string, string>> | null | undefined): string | null {
  const owner = attributes?.[STREAM_OF_ATTRIBUTE];
  return typeof owner === 'string' && owner.length > 0 ? owner : null;
}
