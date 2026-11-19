/**
 * The HTTP rate limits: the global one every API route sits under, the budget
 * of the two public file routes, and the one registration order that keeps the
 * built client's own files out of both. See docs/systems/api.md, "Rate
 * limiting".
 */
import fs from 'node:fs';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import rateLimit from '@fastify/rate-limit';
import fastifyStatic from '@fastify/static';
import { errorBody } from './httpErrors.js';

/**
 * The budget of every route that does not declare its own. It is per client
 * address, and only per address. The limiter runs on `onRequest`, while
 * `authenticate` is a route `preHandler`, so nothing has put a user on the
 * request yet when the key is taken: a key that reached for `request.userId`
 * would read undefined on every request and fall back to the address anyway.
 * Stated plainly instead, because the consequence is an operator's to know:
 * everyone behind one NAT, VPN exit or corporate proxy shares one budget.
 * Which address that is comes from `config.trustedProxyHops`, which is what
 * keeps a client from choosing its own.
 */
export const GLOBAL_RATE_LIMIT = { max: 200, timeWindow: '1 minute' } as const;

/**
 * The budget of a route that serves a stored file by its public name: a
 * served upload (`GET /api/uploads/:filename`) and a sticker image
 * (`GET /api/stickers/assets/:filename`). A route passes this as its
 * `config.rateLimit`, which replaces the global limit for it and counts it on
 * its own, so the images of a channel neither spend the API's budget nor wait
 * on it.
 *
 * It is larger than the global one because one screen asks for many of these
 * at once and none of them can be batched: a page of messages with its
 * attachments and avatars, or a sticker picker holding a full collection of
 * 200. They are answered `immutable`, so a browser asks for each file once.
 * It is still a limit because each request reads the database and the disk
 * without authentication.
 */
export const PUBLIC_FILE_RATE_LIMIT = { max: 1000, timeWindow: '1 minute' } as const;

/**
 * Registers the limiter. It covers the routes registered after this call and
 * none registered before it.
 */
export async function registerRateLimit(app: FastifyInstance): Promise<void> {
  await app.register(rateLimit, {
    ...GLOBAL_RATE_LIMIT,
    keyGenerator: (request: FastifyRequest) => request.ip,
    // Test harnesses set DISABLE_RATE_LIMITS=1 to bypass per-IP exhaustion when
    // many tests share the loopback IP. Default unset; production unchanged.
    allowList: () => process.env.DISABLE_RATE_LIMITS === '1' || process.env.DISABLE_RATE_LIMITS === 'true',
    // The shared error shape (see localization.md) plus `retryAfter` in
    // seconds; the plugin sets the Retry-After header itself. One builder
    // covers every per-route override too, so a route that sets its own
    // limit does not need to spell the body out again.
    errorResponseBuilder: (_request, context) => ({
      ...errorBody(429, 'rate_limited'),
      retryAfter: Math.ceil(context.ttl / 1000),
    }),
  });
}

/**
 * Serves the built web client from `webDistPath` when it exists, then
 * registers the limiter, and reports whether there was a client to serve.
 *
 * The order is the point, which is why the two are one call. The limiter only
 * covers routes registered after it, and `@fastify/static` takes no route
 * config that could give its routes a budget of their own, so registering the
 * client's files first is what keeps them out of the global budget. They have
 * to be out of it: a first launch in a fresh browser profile fetches about 160
 * of them within a minute (the page's own, then the service worker's precache
 * of every one), which under the global limit left about 40 requests for the
 * API and the opened channel's images, and the rest of that minute was
 * refused. These routes answer a fixed set of files from disk and read
 * nothing else; the SPA fallback that serves `index.html` for unknown paths is
 * a not-found handler and was never limited either.
 */
export async function registerClientFilesThenRateLimit(app: FastifyInstance, webDistPath: string): Promise<boolean> {
  const hasClient = fs.existsSync(webDistPath);
  if (hasClient) {
    await app.register(fastifyStatic, { root: webDistPath, prefix: '/', wildcard: false });
  }
  await registerRateLimit(app);
  return hasClient;
}
