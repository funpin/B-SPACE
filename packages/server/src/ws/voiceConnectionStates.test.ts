import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import Database from 'better-sqlite3';
import { drizzle } from 'drizzle-orm/better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { WebSocket } from 'ws';
import {
  VOICE_CONNECT_FAILED_TTL_MS,
  VOICE_SILENT_REMOVAL_MS,
  VOICE_UNRESPONSIVE_AFTER_MS,
} from '@backspace/shared/src/voiceConnection.js';
import * as schema from '../db/schema.js';
import { setWorkerId } from '../utils/snowflake.js';

setWorkerId(1);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
type TestDb = ReturnType<typeof drizzle<typeof schema>>;

let testDb: TestDb;
let sqlite: Database.Database;

vi.mock('../db/index.js', () => ({
  getDb: () => testDb,
  schema,
}));

import { connectionManager, VOICE_RECONNECT_GRACE_MS } from './handler.js';
import { handleClientEvent } from './events.js';

const SPACE = 'space-1';
const VOICE = 'voice-1';
const OTHER_VOICE = 'voice-2';

interface Sent { type: string; [key: string]: unknown }

const sockets: WebSocket[] = [];

/** A socket of `userId`; `inSpace` makes the user receive the space's broadcasts. */
function connect(userId: string, inSpace: boolean): WebSocket {
  const socket = { readyState: 1, send: vi.fn() } as unknown as WebSocket;
  connectionManager.addConnection(userId, socket);
  if (inSpace) connectionManager.setUserSpaces(userId, [SPACE]);
  sockets.push(socket);
  return socket;
}

function received(socket: WebSocket, type?: string): Sent[] {
  const all = (socket.send as unknown as ReturnType<typeof vi.fn>).mock.calls
    .map(([raw]) => JSON.parse(raw as string) as Sent);
  return type ? all.filter((event) => event.type === type) : all;
}

function send(userId: string, socket: WebSocket, event: Record<string, unknown>): void {
  handleClientEvent(event, userId, userId, socket, false);
}

function applyMigrations(db: Database.Database): void {
  const migrationsDir = path.resolve(__dirname, '../../drizzle');
  const files = fs.readdirSync(migrationsDir).filter((file) => file.endsWith('.sql')).sort();
  for (const file of files) {
    const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    for (const statement of sql.split(/-->\s*statement-breakpoint/)) {
      const clean = statement.trim();
      if (clean) db.exec(clean);
    }
  }
}

beforeAll(() => {
  sqlite = new Database(':memory:');
  sqlite.pragma('foreign_keys = ON');
  applyMigrations(sqlite);
  testDb = drizzle(sqlite, { schema });

  // ann owns the space, so she may see and join both voice channels. stranger
  // is not a member of it at all.
  for (const id of ['ann', 'stranger']) {
    testDb.insert(schema.users).values({ id, username: id, passwordHash: '!test', createdAt: Date.now() }).run();
  }
  testDb.insert(schema.spaces).values({ id: SPACE, name: 'Space', ownerId: 'ann', createdAt: Date.now() }).run();
  testDb.insert(schema.spaceMembers).values({ spaceId: SPACE, userId: 'ann', joinedAt: Date.now() }).run();
  for (const id of [VOICE, OTHER_VOICE]) {
    testDb.insert(schema.channels).values({ id, spaceId: SPACE, name: id, type: 'voice', createdAt: Date.now() }).run();
  }
});

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(1_000_000);
});

afterEach(() => {
  connectionManager.voiceAttempts.reset();
  connectionManager.voiceWatchdog.reset();
  for (const userId of ['ann', 'stranger']) {
    connectionManager.clearVoiceWs(userId);
    connectionManager.leaveCurrentRoom(userId);
    connectionManager.clearVoiceUserStatus(userId);
  }
  for (const roomId of [VOICE, OTHER_VOICE]) connectionManager.destroyRoom(roomId);
  for (const socket of sockets.splice(0)) connectionManager.removeConnection(socket);
  vi.clearAllTimers();
  vi.useRealTimers();
});

describe('voice_connecting', () => {
  it('relays an attempt to the members who can see the channel, and to nobody else', () => {
    const ann = connect('ann', true);
    const annOtherTab = connect('ann', true);
    const stranger = connect('stranger', false);

    send('ann', ann, { type: 'voice_connecting', channelId: VOICE, state: 'connecting' });

    const expected = { type: 'voice_connecting_update', channelId: VOICE, userId: 'ann', state: 'connecting' };
    expect(received(ann, 'voice_connecting_update')).toEqual([expected]);
    expect(received(annOtherTab, 'voice_connecting_update')).toEqual([expected]);
    expect(received(stranger)).toEqual([]);
  });

  it('drops a report from a user who may not join the channel, without an answer', () => {
    const ann = connect('ann', true);
    const stranger = connect('stranger', false);

    send('stranger', stranger, { type: 'voice_connecting', channelId: VOICE, state: 'connecting' });
    send('stranger', stranger, { type: 'voice_connecting', channelId: 'no-such-channel', state: 'connecting' });
    send('stranger', stranger, { type: 'voice_connecting', channelId: VOICE, state: 'bogus' });

    expect(received(ann)).toEqual([]);
    expect(received(stranger)).toEqual([]);
    expect(connectionManager.voiceAttempts.forChannel(VOICE)).toEqual([]);
  });

  it('relays a failure with a reason from the list, and replaces an unknown one', () => {
    const ann = connect('ann', true);

    send('ann', ann, { type: 'voice_connecting', channelId: VOICE, state: 'failed', reason: 'media_unreachable' });
    expect(received(ann, 'voice_connecting_update').at(-1)).toMatchObject({ state: 'failed', reason: 'media_unreachable' });

    send('ann', ann, { type: 'voice_connecting', channelId: OTHER_VOICE, state: 'failed', reason: '<script>' });
    expect(received(ann, 'voice_connecting_update').at(-1)).toMatchObject({
      channelId: OTHER_VOICE, state: 'failed', reason: 'connect_failed',
    });
  });

  it('withdraws a failure on idle, on its own after a while, and when the socket closes', () => {
    const watcher = connect('ann', true);
    const ann = connect('ann', true);
    const idleCount = () => received(watcher, 'voice_connecting_update').filter((event) => event.state === 'idle').length;

    send('ann', ann, { type: 'voice_connecting', channelId: VOICE, state: 'failed', reason: 'not_allowed' });
    send('ann', ann, { type: 'voice_connecting', state: 'idle' });
    expect(idleCount()).toBe(1);

    send('ann', ann, { type: 'voice_connecting', channelId: VOICE, state: 'failed' });
    vi.advanceTimersByTime(VOICE_CONNECT_FAILED_TTL_MS);
    expect(idleCount()).toBe(2);

    send('ann', ann, { type: 'voice_connecting', channelId: VOICE, state: 'connecting' });
    connectionManager.removeConnection(ann);
    expect(idleCount()).toBe(3);
  });

  it('ends the attempt before announcing the join it turned into', () => {
    const ann = connect('ann', true);

    send('ann', ann, { type: 'voice_connecting', channelId: VOICE, state: 'connecting' });
    send('ann', ann, { type: 'voice_join', channelId: VOICE });

    const order = received(ann)
      .filter((event) => event.type === 'voice_connecting_update' || event.type === 'voice_state_update')
      .map((event) => `${event.type}:${String(event.state ?? event.action)}`);
    expect(order).toEqual([
      'voice_connecting_update:connecting',
      'voice_connecting_update:idle',
      'voice_state_update:join',
    ]);
    expect(connectionManager.voiceAttempts.forChannel(VOICE)).toEqual([]);
  });

  it('ignores a report for the channel the user is already in', () => {
    const ann = connect('ann', true);
    send('ann', ann, { type: 'voice_join', channelId: VOICE });

    send('ann', ann, { type: 'voice_connecting', channelId: VOICE, state: 'connecting' });

    expect(received(ann, 'voice_connecting_update')).toEqual([]);
  });

  it('lists attempts in the snapshot of a member who can see the channel', () => {
    const ann = connect('ann', true);
    send('ann', ann, { type: 'voice_connecting', channelId: VOICE, state: 'failed', reason: 'server_unreachable' });

    expect(connectionManager.buildSpaceVoiceState(SPACE, 'ann').voiceConnecting).toEqual({
      [VOICE]: [{ userId: 'ann', state: 'failed', reason: 'server_unreachable' }],
    });
    expect(connectionManager.buildSpaceVoiceState(SPACE, 'stranger').voiceConnecting).toEqual({});
  });
});

describe('connection flags in the voice status', () => {
  function statusUpdates(socket: WebSocket): Sent[] {
    return received(socket, 'voice_status_update');
  }
  const plain = { isMuted: false, isDeafened: false, isCameraOn: false, isScreenSharing: false };

  it('relays the flags a client reports and leaves them out when they are false', () => {
    const ann = connect('ann', true);
    send('ann', ann, { type: 'voice_join', channelId: VOICE });

    send('ann', ann, { type: 'voice_status', ...plain, isReconnecting: true, isMicUnavailable: true });
    expect(statusUpdates(ann).at(-1)).toEqual({
      type: 'voice_status_update', userId: 'ann', channelId: VOICE, ...plain, isReconnecting: true, isMicUnavailable: true,
    });

    send('ann', ann, { type: 'voice_status', ...plain, isMuted: true });
    expect(statusUpdates(ann).at(-1)).toEqual({
      type: 'voice_status_update', userId: 'ann', channelId: VOICE, ...plain, isMuted: true,
    });
  });

  it('does not let a client set the flag that is the server\'s own', () => {
    const ann = connect('ann', true);
    send('ann', ann, { type: 'voice_join', channelId: VOICE });

    send('ann', ann, { type: 'voice_status', ...plain, isUnresponsive: true });

    expect(statusUpdates(ann).at(-1)).not.toHaveProperty('isUnresponsive');
  });

  it('marks a member whose voice socket closed, and unmarks them when they return', () => {
    const watcher = connect('ann', true);
    const ann = connect('ann', true);
    send('ann', ann, { type: 'voice_join', channelId: VOICE });
    send('ann', ann, { type: 'voice_status', ...plain, isMuted: true });

    connectionManager.removeConnection(ann);
    expect(statusUpdates(watcher).at(-1)).toMatchObject({ userId: 'ann', isMuted: true, isUnresponsive: true });
    expect(connectionManager.buildSpaceVoiceState(SPACE, 'ann').voiceUserStates.ann).toMatchObject({ isUnresponsive: true });

    const back = connect('ann', true);
    send('ann', back, { type: 'voice_join', channelId: VOICE });
    expect(statusUpdates(watcher).at(-1)).toMatchObject({ userId: 'ann', isMuted: true });
    expect(statusUpdates(watcher).at(-1)).not.toHaveProperty('isUnresponsive');

    vi.advanceTimersByTime(VOICE_RECONNECT_GRACE_MS * 2);
    expect(connectionManager.getUserRoom('ann')?.roomId).toBe(VOICE);
  });
});

describe('voice watchdog', () => {
  const plain = { isMuted: false, isDeafened: false, isCameraOn: false, isScreenSharing: false };

  function joined(): { ann: WebSocket; watcher: WebSocket } {
    const watcher = connect('ann', true);
    const ann = connect('ann', true);
    send('ann', ann, { type: 'voice_join', channelId: VOICE });
    send('ann', ann, { type: 'voice_status', ...plain });
    return { ann, watcher };
  }

  it('leaves alone a client that never sends heartbeats', () => {
    const { watcher } = joined();

    connectionManager.sweepVoiceWatchdog(Date.now() + VOICE_SILENT_REMOVAL_MS * 5);

    expect(connectionManager.getUserRoom('ann')?.roomId).toBe(VOICE);
    expect(received(watcher, 'voice_status_update').at(-1)).not.toHaveProperty('isUnresponsive');
  });

  it('marks a client that went silent and unmarks it at its next heartbeat', () => {
    const { ann, watcher } = joined();
    send('ann', ann, { type: 'voice_heartbeat' });

    vi.advanceTimersByTime(VOICE_UNRESPONSIVE_AFTER_MS + 1);
    connectionManager.sweepVoiceWatchdog();
    expect(received(watcher, 'voice_status_update').at(-1)).toMatchObject({ userId: 'ann', isUnresponsive: true });

    // A second pass has nothing new to say.
    const before = received(watcher, 'voice_status_update').length;
    connectionManager.sweepVoiceWatchdog();
    expect(received(watcher, 'voice_status_update')).toHaveLength(before);

    send('ann', ann, { type: 'voice_heartbeat' });
    expect(received(watcher, 'voice_status_update').at(-1)).not.toHaveProperty('isUnresponsive');
  });

  it('counts only heartbeats from the socket that owns the voice session', () => {
    const { ann, watcher } = joined();
    send('ann', ann, { type: 'voice_heartbeat' });

    vi.advanceTimersByTime(VOICE_UNRESPONSIVE_AFTER_MS + 1);
    send('ann', watcher, { type: 'voice_heartbeat' });
    connectionManager.sweepVoiceWatchdog();

    expect(received(watcher, 'voice_status_update').at(-1)).toMatchObject({ isUnresponsive: true });
  });

  it('frees the place of a client silent for much longer, and tells its socket', () => {
    const { ann, watcher } = joined();
    send('ann', ann, { type: 'voice_heartbeat' });

    vi.advanceTimersByTime(VOICE_SILENT_REMOVAL_MS + 1);
    connectionManager.sweepVoiceWatchdog();

    expect(connectionManager.getUserRoom('ann')).toBeNull();
    expect(received(ann, 'voice_disconnected')).toEqual([
      { type: 'voice_disconnected', userId: 'ann', channelId: VOICE, reason: 'unresponsive' },
    ]);
    expect(received(watcher, 'voice_state_update').at(-1)).toMatchObject({ userId: 'ann', action: 'leave' });
    expect(connectionManager.getVoiceUserStatus('ann')).toBeUndefined();
  });

  it('leaves a closed socket to the reconnect grace period', () => {
    const { ann } = joined();
    send('ann', ann, { type: 'voice_heartbeat' });
    connectionManager.removeConnection(ann);

    vi.advanceTimersByTime(VOICE_RECONNECT_GRACE_MS - 1);
    connectionManager.sweepVoiceWatchdog();
    expect(connectionManager.getUserRoom('ann')?.roomId).toBe(VOICE);

    vi.advanceTimersByTime(2);
    expect(connectionManager.getUserRoom('ann')).toBeNull();
  });
});
