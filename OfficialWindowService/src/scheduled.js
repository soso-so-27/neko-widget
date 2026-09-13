// Finite, operator-reviewed editions. No scheduler, mutable state or private bindings.
import worker, { activeFiles } from './index.js';

export const CHANNELS = Object.freeze(['official-cats', 'nap-cats', 'cat-tabby-nap']);
export const INDEX_PATH = '/__schedule/index.json';
export const MAX_EDITIONS = 512;
const DAY = 86400_000, HASH = /^[a-f0-9]{64}$/;
const fail = () => { throw new Error('Invalid finite schedule'); };
const keys = (value, expected) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).length === expected.length && expected.every(key => Object.hasOwn(value, key));
export function instant(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) return fail();
  const time = Date.parse(value);
  if (!Number.isFinite(time) || new Date(time).toISOString().replace('.000Z', 'Z') !== value) return fail();
  return time;
}
export function validateSchedule(index) {
  if (!keys(index, ['schemaVersion', 'startsAt', 'through', 'editions']) || index.schemaVersion !== 1
      || !Array.isArray(index.editions) || !index.editions.length || index.editions.length > MAX_EDITIONS) fail();
  const start = instant(index.startsAt), through = instant(index.through);
  if (through <= start || through - start > 14 * DAY) fail();
  let next = start;
  for (const [position, edition] of index.editions.entries()) {
    if (!keys(edition, ['id', 'startsAt', 'endsAt', 'catalogs'])
        || edition.id !== `edition-${String(position).padStart(3, '0')}`
        || !keys(edition.catalogs, CHANNELS) || !Object.values(edition.catalogs).every(hash => typeof hash === 'string' && HASH.test(hash))) fail();
    const from = instant(edition.startsAt), until = instant(edition.endsAt);
    if (from !== next || until <= from || until - from > 2 * DAY || until > through) fail();
    next = until;
  }
  if (next !== through) fail();
  return index;
}
export function selectEdition(index, now = Date.now()) {
  validateSchedule(index);
  if (!Number.isFinite(now) || now < instant(index.startsAt) || now >= instant(index.through)) return null;
  return index.editions.find(edition => instant(edition.startsAt) <= now && now < instant(edition.endsAt)) ?? null;
}
export function publicPath(url) {
  const legacy = /^\/(catalog\.json|[a-f0-9]{64}\.jpg)$/.exec(url.pathname);
  const window = /^\/windows\/(nap-cats|cat-tabby-nap)\/(catalog\.json|[a-f0-9]{64}\.jpg)$/.exec(url.pathname);
  if (url.search || (!legacy && !window)) return null;
  return { channel: window ? window[1] : 'official-cats', filename: window ? window[2] : legacy[1] };
}
async function bytes(binding, url, maximum) {
  const response = await binding.fetch(new Request(url, { method: 'GET', redirect: 'manual' }));
  if (response.status !== 200 || !response.body) throw new Error('Schedule asset unavailable');
  const reader = response.body.getReader(), chunks = [];
  let count = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      count += value.byteLength;
      if (count > maximum) throw new Error('Schedule asset too large');
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  if (!count) throw new Error('Empty schedule asset');
  const result = new Uint8Array(count);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
  return result;
}
function reply(status, head) {
  return new Response(head ? null : status === 404 ? 'Not found' : 'Feed temporarily unavailable', {
    status, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', ...(status === 503 ? { 'Retry-After': '300' } : {}) },
  });
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url), route = publicPath(url), head = request.method === 'HEAD';
    // Never expose the index, edition prefixes, unknown windows or future files.
    if (!route) return reply(404, head);
    if (request.method !== 'GET' && !head) return worker.fetch(request, env);
    try {
      const raw = await bytes(env.OFFICIAL_ASSETS, new URL(INDEX_PATH, url), 256 * 1024);
      const index = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw));
      const selected = selectEdition(index);
      if (!selected) return reply(503, head);
      let servedCatalog;
      const binding = { async fetch(input) {
        const requested = new URL(input.url), allowed = publicPath(requested);
        if (!allowed || allowed.channel !== route.channel) return reply(404, false);
        const internal = new URL(`/__schedule/editions/${selected.id}${requested.pathname}`, url);
        if (allowed.filename !== 'catalog.json') {
          return env.OFFICIAL_ASSETS.fetch(new Request(internal, { method: 'GET', redirect: 'manual' }));
        }
        const catalogBytes = await bytes(env.OFFICIAL_ASSETS, internal, 256 * 1024);
        const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', catalogBytes))].map(value => value.toString(16).padStart(2, '0')).join('');
        if (digest !== selected.catalogs[route.channel]) throw new Error('Wrong scheduled catalog');
        servedCatalog = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(catalogBytes));
        if (servedCatalog.generatedAt !== selected.startsAt || instant(servedCatalog.validUntil) < instant(selected.endsAt)
            || instant(servedCatalog.validUntil) > instant(index.through)) throw new Error('Scheduled catalog lease mismatch');
        if (route.channel === 'cat-tabby-nap' && (!Array.isArray(servedCatalog.photos)
            || servedCatalog.photos.some(photo => photo?.catID !== 'generated-tabby-nap'))) throw new Error('Different cat in scheduled cat window');
        return new Response(catalogBytes, { status: 200 });
      } };
      const response = await worker.fetch(request, { OFFICIAL_ASSETS: binding });
      // Catalog, image I/O or hashing can cross a cutover, not just a photo expiry.
      const now = Date.now();
      if (selectEdition(index, now)?.id !== selected.id) return reply(503, head);
      if (response.status === 200) {
        const files = activeFiles(servedCatalog, now, route.channel);
        if (route.filename !== 'catalog.json' && !files.has(route.filename)) return reply(404, head);
      }
      return response;
    } catch { return reply(503, head); }
  },
};
