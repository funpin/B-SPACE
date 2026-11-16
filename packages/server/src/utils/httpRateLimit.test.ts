import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import Database from 'better-sqlite3';
import { drizzle } from 'drizzle-orm/better-sqlite3';
import { migrate } from 'drizzle-orm/better-sqlite3/migrator';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import * as schema from '../db/schema.js';

const settings = vi.hoisted(() => ({ uploadDir: '' }));
let db: ReturnType<typeof drizzle<typeof schema>>;
let sqlite: Database.Database;
vi.mock('../db/index.js', () => ({ getDb: () => db, schema }));
vi.mock('../config.js', () => ({ config: settings }));
vi.mock('../utils/federationAuth.js', () => ({ getOurOrigin: () => 'https://chat.test' }));
vi.mock('../utils/auth.js', () => ({ authenticate: async () => undefined }));
import { uploadRoutes } from '../routes/uploads.js';
import { stickerRoutes } from '../routes/stickers.js';
import {
  GLOBAL_RATE_LIMIT, PUBLIC_FILE_RATE_LIMIT, registerClientFilesThenRateLimit, registerRateLimit,
} from './httpRateLimit.js';

/**
 * What a first launch of the web client in a fresh browser profile asks for
 * within one minute, measured on a production build on 2026-11-16: 41 files
 * for the page, the 117 precache entries again for the service worker, and on
 * a busy channel about 90 more for the API and the channel's images.
 */
const COLD_START_CLIENT_FILES = 158;
const COLD_START_IMAGES = 90;

let app: FastifyInstance;
let scratch: string;

beforeEach(async () => {
  // The suite shares the loopback address and runs with the limits off; these
  // tests are about the limits, so they need them on whatever the shell set.
  vi.stubEnv('DISABLE_RATE_LIMITS', '');
  scratch = await mkdtemp(path.join(tmpdir(), 'backspace-rate-limit-'));
  app = Fastify({ logger: false });
});

afterEach(async () => {
  await app.close();
  vi.unstubAllEnvs();
  await rm(scratch, { recursive: true, force: true });
});

async function statusesOf(count: number, url: (index: number) => string): Promise<number[]> {
  const statuses: number[] = [];
  for (let i = 0; i < count; i += 1) statuses.push((await app.inject({ url: url(i) })).statusCode);
  return statuses;
}

const refused = (statuses: number[]): number => statuses.filter((status) => status === 429).length;

describe('the built client and the global limit', () => {
  const CLIENT_FILES = ['/', '/index.html', '/sw.js', '/assets/index-abc123.js', '/fonts/Onest-latin.woff2'];

  beforeEach(async () => {
    const dist = path.join(scratch, 'dist');
    await mkdir(path.join(dist, 'assets'), { recursive: true });
    await mkdir(path.join(dist, 'fonts'), { recursive: true });
    await writeFile(path.join(dist, 'index.html'), '<!doctype html>');
    await writeFile(path.join(dist, 'sw.js'), '// worker');
    await writeFile(path.join(dist, 'assets', 'index-abc123.js'), '// chunk');
    await writeFile(path.join(dist, 'fonts', 'Onest-latin.woff2'), 'font');
    expect(await registerClientFilesThenRateLimit(app, dist)).toBe(true);
    app.get('/api/ping', async () => ({ ok: true }));
    await app.ready();
  });

  it('serves a cold start of the client twice over without refusing a file', async () => {
    const statuses = await statusesOf(COLD_START_CLIENT_FILES * 2, (i) => CLIENT_FILES[i % CLIENT_FILES.length]!);
    expect(statuses.every((status) => status === 200)).toBe(true);
  });

  it('leaves the whole API budget for the API after the client has loaded', async () => {
    await statusesOf(COLD_START_CLIENT_FILES, (i) => CLIENT_FILES[i % CLIENT_FILES.length]!);
    const api = await statusesOf(GLOBAL_RATE_LIMIT.max, () => '/api/ping');
    expect(api.every((status) => status === 200)).toBe(true);
  });

  it('still refuses the API past its budget, in the shared error shape, and keeps serving the client', async () => {
    await statusesOf(GLOBAL_RATE_LIMIT.max, () => '/api/ping');
    const over = await app.inject({ url: '/api/ping' });
    expect(over.statusCode).toBe(429);
    expect(over.headers['retry-after']).toMatch(/^\d+$/);
    expect(over.json()).toEqual({
      error: 'Too many requests',
      code: 'rate_limited',
      statusCode: 429,
      retryAfter: Number(over.headers['retry-after']),
    });
    expect((await app.inject({ url: '/assets/index-abc123.js' })).statusCode).toBe(200);
  });

  it('reports a checkout with no built client and still registers the limit', async () => {
    const bare = Fastify({ logger: false });
    try {
      expect(await registerClientFilesThenRateLimit(bare, path.join(scratch, 'missing'))).toBe(false);
      bare.get('/api/ping', async () => ({ ok: true }));
      await bare.ready();
      for (let i = 0; i < GLOBAL_RATE_LIMIT.max; i += 1) await bare.inject({ url: '/api/ping' });
      expect((await bare.inject({ url: '/api/ping' })).statusCode).toBe(429);
    } finally {
      await bare.close();
    }
  });
});

describe('served uploads and sticker images', () => {
  const UPLOAD = '/api/uploads/380800553325223936.png';
  const STICKER = `/api/stickers/assets/${'a'.repeat(64)}.webp`;

  beforeEach(async () => {
    settings.uploadDir = path.join(scratch, 'uploads');
    await mkdir(settings.uploadDir, { recursive: true });
    await writeFile(path.join(settings.uploadDir, '380800553325223936.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47]));
    sqlite = new Database(':memory:');
    db = drizzle(sqlite, { schema });
    migrate(db, { migrationsFolder: path.resolve('drizzle') });
    await registerRateLimit(app);
    await app.register(uploadRoutes);
    await app.register(stickerRoutes);
    app.get('/api/ping', async () => ({ ok: true }));
    await app.ready();
  });

  afterEach(() => {
    sqlite.close();
  });

  it('gives each of the two routes the public file budget in place of the global one', async () => {
    expect(PUBLIC_FILE_RATE_LIMIT.max).toBeGreaterThan(GLOBAL_RATE_LIMIT.max);
    for (const url of [UPLOAD, STICKER]) {
      const response = await app.inject({ url });
      expect(response.headers['x-ratelimit-limit']).toBe(String(PUBLIC_FILE_RATE_LIMIT.max));
    }
  });

  it('serves the images of a cold start on top of a spent API budget', async () => {
    const api = await statusesOf(GLOBAL_RATE_LIMIT.max, () => '/api/ping');
    expect(refused(api)).toBe(0);
    expect((await app.inject({ url: '/api/ping' })).statusCode).toBe(429);

    const uploads = await statusesOf(COLD_START_IMAGES, () => UPLOAD);
    expect(uploads.every((status) => status === 200)).toBe(true);
    // No such sticker, which the route answers itself: the limiter let it through.
    const stickers = await statusesOf(COLD_START_IMAGES, () => STICKER);
    expect(stickers.every((status) => status === 404)).toBe(true);
  });

  it('does not let image requests spend the API budget', async () => {
    await statusesOf(GLOBAL_RATE_LIMIT.max + COLD_START_IMAGES, (i) => (i % 2 === 0 ? UPLOAD : STICKER));
    const api = await statusesOf(GLOBAL_RATE_LIMIT.max, () => '/api/ping');
    expect(refused(api)).toBe(0);
  });

  it('ends each route\'s budget on its own count', async () => {
    const uploads = await statusesOf(PUBLIC_FILE_RATE_LIMIT.max, () => UPLOAD);
    expect(refused(uploads)).toBe(0);
    expect((await app.inject({ url: UPLOAD })).statusCode).toBe(429);
    expect((await app.inject({ url: STICKER })).statusCode).toBe(404);
  });
});
