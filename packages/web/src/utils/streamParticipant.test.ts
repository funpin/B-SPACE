import { describe, expect, it } from 'vitest';
import { isStreamParticipant, shareCarriersOf, sharerIdentityOf, streamQualityKey } from './streamParticipant';

const person = (identity: string) => ({ identity, attributes: {} });
const stream = (identity: string, owner: string) => ({ identity, attributes: { streamOf: owner } });

describe('whose share a participant carries', () => {
  it('is its owner\'s for a stream participant and its own for anyone else', () => {
    expect(sharerIdentityOf(stream('stream.bob:Bob', 'bob:Bob'))).toBe('bob:Bob');
    expect(sharerIdentityOf(person('bob:Bob'))).toBe('bob:Bob');
    expect(sharerIdentityOf({ identity: 'bob:Bob' })).toBe('bob:Bob');
  });

  it('is decided by the attribute the server signs, never by the look of the identity', () => {
    expect(isStreamParticipant(person('stream.bob:Bob'))).toBe(false);
    expect(isStreamParticipant(stream('anything', 'bob:Bob'))).toBe(true);
    expect(isStreamParticipant({ identity: 'bob:Bob', attributes: { streamOf: '' } })).toBe(false);
  });
});

describe('the participants that carry a user\'s share', () => {
  const room = [person('bob:Bob'), stream('stream.bob:Bob', 'bob:Bob'), person('carol:Carol'), stream('stream.dave:Dave', 'dave:Dave')];

  it('are the user and the user\'s stream participant', () => {
    expect(shareCarriersOf(room, 'bob:Bob').map((p) => p.identity)).toEqual(['bob:Bob', 'stream.bob:Bob']);
    expect(shareCarriersOf(room, 'carol:Carol').map((p) => p.identity)).toEqual(['carol:Carol']);
  });

  it('are the stream participant alone while its owner is away', () => {
    expect(shareCarriersOf(room, 'dave:Dave').map((p) => p.identity)).toEqual(['stream.dave:Dave']);
  });

  it('never include a stream participant under its own identity', () => {
    expect(shareCarriersOf(room, 'stream.bob:Bob')).toEqual([]);
  });
});

describe('the key of a stream participant\'s connection quality', () => {
  it('is its owner\'s identity with a mark no identity ends with by chance', () => {
    expect(streamQualityKey('bob:Bob')).toBe('bob:Bob:stream');
  });
});
