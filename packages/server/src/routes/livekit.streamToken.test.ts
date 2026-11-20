import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { PermissionBits } from '@backspace/shared/src/permissions.js';
import { STREAM_OF_ATTRIBUTE, streamIdentityOf, streamOwnerOf } from '@backspace/shared/src/streamParticipant.js';
import * as schema from '../db/schema.js';
import { livekitRoutes } from './livekit.js';

/**
 * The stream token: the pass of the second LiveKit participant a native
 * client publishes its screen share through (docs/systems/voice.md, "The
 * stream participant"). What matters is what the token lets its holder do,
 * so the tests read the grants out of the signed token.
 */

const permissionMocks = vi.hoisted(() => ({
  getChannelSpaceId: vi.fn<(id: string) => string | null>(),
  hasPermission: vi.fn<() => boolean>(),
  computePermissions: vi.fn<() => bigint>(() => 0n),
  isDmMember: vi.fn<() => boolean>(),
}));

const state = vi.hoisted(() => ({ dbRow: undefined as unknown }));

vi.mock('../utils/auth.js', () => ({
  authenticate: async (request: { userId?: string; username?: string }) => {
    request.userId = 'user-1';
    request.username = 'alice';
  },
}));

vi.mock('../utils/permissions.js', async (importOriginal) => {
  const real = await importOriginal<typeof import('../utils/permissions.js')>();
  return {
    ...real,
    getChannelSpaceId: permissionMocks.getChannelSpaceId,
    hasPermission: permissionMocks.hasPermission,
    computePermissions: permissionMocks.computePermissions,
    isDmMember: permissionMocks.isDmMember,
  };
});

vi.mock('../db/index.js', () => {
  const chain: Record<string, unknown> = {};
  for (const name of ['select', 'from', 'where']) chain[name] = () => chain;
  chain.get = () => state.dbRow;
  return { getDb: () => chain, schema };
});

vi.mock('../config.js', () => ({
  // Long enough to sign with, and plainly not a key: a secret scanner reads
  // a random-looking literal here as one.
  config: { livekit: { apiKey: 'key', apiSecret: 'x'.repeat(48), url: 'wss://lk.test' } },
}));

interface TokenClaims {
  sub: string;
  exp: number;
  nbf?: number;
  iat?: number;
  attributes?: Record<string, string>;
  video: {
    room?: string;
    roomJoin?: boolean;
    canPublish?: boolean;
    canSubscribe?: boolean;
    canPublishData?: boolean;
    canUpdateOwnMetadata?: boolean;
    canPublishSources?: string[];
  };
}

function claimsOf(token: string): TokenClaims {
  const payload = token.split('.')[1];
  if (!payload) throw new Error('not a signed token');
  return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as TokenClaims;
}

const auth = { authorization: 'Bearer test' };
let app: FastifyInstance;

async function ask(payload: Record<string, unknown>) {
  return app.inject({ method: 'POST', url: '/api/livekit/token', headers: auth, payload });
}

beforeEach(async () => {
  state.dbRow = undefined;
  permissionMocks.getChannelSpaceId.mockReset().mockReturnValue('space-1');
  permissionMocks.hasPermission.mockReset().mockReturnValue(true);
  permissionMocks.isDmMember.mockReset().mockReturnValue(true);
  permissionMocks.computePermissions.mockReset().mockReturnValue(PermissionBits.CONNECT | PermissionBits.SPEAK | PermissionBits.STREAM);
  app = Fastify();
  await app.register(livekitRoutes);
  await app.ready();
});

afterEach(async () => {
  await app.close();
});

describe('the identity of a stream participant', () => {
  it('is told apart from its owner and leads back to it', () => {
    expect(streamIdentityOf('user-1:alice')).toBe('stream.user-1:alice');
    expect(streamOwnerOf({ [STREAM_OF_ATTRIBUTE]: 'user-1:alice' })).toBe('user-1:alice');
  });

  it('is nobody\'s stream without the attribute the server signs', () => {
    expect(streamOwnerOf({})).toBeNull();
    expect(streamOwnerOf(undefined)).toBeNull();
    expect(streamOwnerOf({ [STREAM_OF_ATTRIBUTE]: '' })).toBeNull();
  });
});

describe('POST /api/livekit/token for a stream', () => {
  it('issues a pass that can publish a screen share and its sound, and nothing else', async () => {
    const res = await ask({ channelId: 'c1', purpose: 'stream' });
    expect(res.statusCode).toBe(200);
    const body = res.json() as { token: string; url: string };
    expect(body.url).toBe('wss://lk.test');
    const claims = claimsOf(body.token);
    expect(claims.sub).toBe('stream.user-1:alice');
    expect(claims.attributes).toEqual({ streamOf: 'user-1:alice' });
    expect(claims.video).toEqual({
      room: 'c1',
      roomJoin: true,
      canPublish: true,
      canPublishSources: ['screen_share', 'screen_share_audio'],
      canSubscribe: false,
      canPublishData: false,
      canUpdateOwnMetadata: false,
    });
  });

  it('gives a short time to join with it', async () => {
    const claims = claimsOf((await ask({ channelId: 'c1', purpose: 'stream' })).json().token as string);
    const lifetime = claims.exp - Math.floor(Date.now() / 1000);
    expect(lifetime).toBeGreaterThan(60);
    expect(lifetime).toBeLessThanOrEqual(600);
  });

  it('refuses a member who may not stream in the channel', async () => {
    permissionMocks.computePermissions.mockReturnValue(PermissionBits.CONNECT | PermissionBits.SPEAK);
    const res = await ask({ channelId: 'c1', purpose: 'stream' });
    expect(res.json()).toMatchObject({ statusCode: 403, code: 'voice_stream_forbidden', error: 'Missing STREAM permission' });
  });

  it('lets an administrator stream whatever the channel says', async () => {
    permissionMocks.computePermissions.mockReturnValue(PermissionBits.ADMINISTRATOR);
    const res = await ask({ channelId: 'c1', purpose: 'stream' });
    expect(res.statusCode).toBe(200);
  });

  it('applies the same guards as the voice pass', async () => {
    permissionMocks.hasPermission.mockReturnValue(false);
    expect((await ask({ channelId: 'c1', purpose: 'stream' })).json()).toMatchObject({ statusCode: 403, code: 'voice_connect_forbidden' });
    permissionMocks.getChannelSpaceId.mockReturnValue(null);
    expect((await ask({ channelId: 'c1', purpose: 'stream' })).json()).toMatchObject({ statusCode: 404, code: 'channel_not_found' });
    permissionMocks.isDmMember.mockReturnValue(false);
    expect((await ask({ dmChannelId: 'd1', purpose: 'stream' })).json()).toMatchObject({ statusCode: 403, code: 'not_dm_member' });
  });

  it('issues one for a direct call, in the call\'s own room', async () => {
    const local = claimsOf((await ask({ dmChannelId: 'd1', purpose: 'stream' })).json().token as string);
    expect(local.video.room).toBe('dm-d1');
    expect(local.sub).toBe('stream.user-1:alice');

    state.dbRow = { federatedId: 'fed-room-7' };
    const federated = claimsOf((await ask({ dmChannelId: 'd1', purpose: 'stream' })).json().token as string);
    expect(federated.video.room).toBe('fed-room-7');
  });

  it('refuses a purpose it does not know', async () => {
    expect((await ask({ channelId: 'c1', purpose: 'camera' })).json()).toMatchObject({ statusCode: 400, code: 'validation_failed' });
    expect((await ask({ channelId: 'c1', purpose: 7 })).json()).toMatchObject({ statusCode: 400, code: 'validation_failed' });
  });
});

describe('POST /api/livekit/token for voice', () => {
  it('is what it was, and says that this server issues stream passes', async () => {
    for (const payload of [{ channelId: 'c1' }, { channelId: 'c1', purpose: 'voice' }]) {
      const res = await ask(payload);
      expect(res.statusCode).toBe(200);
      const body = res.json() as { token: string; url: string; streamTokens?: boolean };
      expect(body.streamTokens).toBe(true);
      const claims = claimsOf(body.token);
      expect(claims.sub).toBe('user-1:alice');
      expect(claims.attributes).toBeUndefined();
      expect(claims.video).toMatchObject({
        room: 'c1',
        roomJoin: true,
        canPublish: true,
        canSubscribe: true,
        canPublishData: true,
        canPublishSources: ['microphone', 'camera', 'screen_share', 'screen_share_audio'],
      });
      expect(claims.video.canUpdateOwnMetadata).not.toBe(true);
    }
  });

  it('cannot be asked to carry the mark of a stream', async () => {
    const claims = claimsOf((await ask({ channelId: 'c1', streamOf: 'user-2:bob', attributes: { streamOf: 'user-2:bob' } })).json().token as string);
    expect(claims.sub).toBe('user-1:alice');
    expect(claims.attributes).toBeUndefined();
  });
});
