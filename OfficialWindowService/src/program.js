// A finite, reviewed public programme. No private bindings, cron, uploads or renewal.
import worker from './index.js';
import { instant } from './scheduled.js';

export const PROGRAM_PATH = '/__program/index.json';
const DAY = 86400000, HASH = /^[a-f0-9]{64}$/;
const keys = (v, names) => v && typeof v === 'object' && !Array.isArray(v)
  && Object.keys(v).length === names.length && names.every(k => Object.hasOwn(v, k));
const require = value => { if (!value) throw new Error('Invalid public programme'); };
export function weekStart(at) {
  const local = new Date(at + 9 * 3600000);
  local.setUTCHours(0, 0, 0, 0);
  local.setUTCDate(local.getUTCDate() - (local.getUTCDay() + 6) % 7);
  return local.toISOString().slice(0, 10);
}
export function validateThemes(v, now) {
  require(keys(v, ['schemaVersion', 'generatedAt', 'validUntil', 'themes']) && v.schemaVersion === 1);
  const from = instant(v.generatedAt), until = instant(v.validUntil);
  require(from <= now + 300000 && until > now && until > from && until - from <= 2 * DAY
    && Array.isArray(v.themes) && v.themes.length >= 1 && v.themes.length <= 3);
  const monday = instant(weekStart(now) + 'T00:00:00Z');
  for (const [i, theme] of v.themes.entries()) {
    const date = new Date(monday - i * 7 * DAY).toISOString().slice(0, 10);
    require(keys(theme, ['name', 'weekStart', 'channelID']) && theme.weekStart === date
      && typeof theme.name === 'string' && theme.name.trim() === theme.name && [...theme.name].length >= 1
      && [...theme.name].length <= 30 && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029\ud800-\udfff]/u.test(theme.name)
      && theme.channelID === (i === 0 ? 'weekly-theme' : 'weekly-theme-' + date.replaceAll('-', '')));
  }
  return v;
}
export function validateProgram(index) {
  require(keys(index, ['schemaVersion', 'startsAt', 'through', 'editions']) && [1, 2].includes(index.schemaVersion)
    && Array.isArray(index.editions) && index.editions.length >= 1 && index.editions.length <= 512);
  const dailyBlackCats = index.schemaVersion === 2;
  const from = instant(index.startsAt), end = instant(index.through);
  require(end > from && end - from <= (dailyBlackCats ? 60 : 14) * DAY);
  if (dailyBlackCats) {
    // Daily black-cat editions always start at 00:00 JST (15:00 UTC).
    require(index.editions.length <= 60 && new Date(from).getUTCHours() === 15
      && from % 3600000 === 0);
  }
  let next = from;
  for (const [i, edition] of index.editions.entries()) {
    require(keys(edition, dailyBlackCats ? ['id', 'startsAt', 'endsAt', 'catalogs'] : ['id', 'startsAt', 'endsAt', 'catalogs', 'themes'])
      && edition.id === `edition-${String(i).padStart(3, '0')}`);
    const start = instant(edition.startsAt), until = instant(edition.endsAt);
    require(start === next && until > start && until <= end && until - start <= DAY);
    if (dailyBlackCats) {
      require(until - start === DAY);
    } else {
      validateThemes(edition.themes, start);
      require(edition.themes.generatedAt === edition.startsAt && instant(edition.themes.validUntil) >= until
        && instant(edition.themes.validUntil) <= end
        && weekStart(start) === weekStart(until - 1));
    }
    const channels = dailyBlackCats ? ['black-cats'] : ['official-cats', 'black-cats', ...edition.themes.themes.map(t => t.channelID)];
    require(keys(edition.catalogs, channels) && Object.values(edition.catalogs).every(h => typeof h === 'string' && HASH.test(h)));
    next = until;
  }
  require(next === end);
  return index;
}
const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' };
const reply = (status, head = false) => new Response(head ? null : status === 404 ? 'Not found' : 'Feed temporarily unavailable', { status, headers });
async function read(binding, url, maximum = 256 * 1024) {
  const response = await binding.fetch(new Request(url, { redirect: 'manual' }));
  if (response.status !== 200 || !response.body) throw new Error('Public asset unavailable');
  const reader = response.body.getReader(), chunks = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maximum) throw new Error('Public asset too large');
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  if (!length) throw new Error('Empty public asset');
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url), head = request.method === 'HEAD';
    const root = /^\/(catalog\.json|[a-f0-9]{64}\.jpg)$/.exec(url.pathname);
    const route = /^\/windows\/(black-cats|weekly-theme(?:-\d{8})?)\/(catalog\.json|themes\.json|[a-f0-9]{64}\.jpg)$/.exec(url.pathname);
    if (url.search || (!root && !route) || (route?.[2] === 'themes.json' && route[1] !== 'weekly-theme')) return reply(404, head);
    if (request.method !== 'GET' && !head) return new Response('Method not allowed', { status: 405, headers: { ...headers, Allow: 'GET, HEAD' } });
    try {
      const raw = await read(env.OFFICIAL_ASSETS, new URL(PROGRAM_PATH, url));
      const index = validateProgram(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw)));
      const now = Date.now(), selected = index.editions.find(e => instant(e.startsAt) <= now && now < instant(e.endsAt));
      if (!selected) return reply(503, head);
      const channel = root ? 'official-cats' : route[1];
      if (!Object.hasOwn(selected.catalogs, channel)) return reply(404, head);
      if (route?.[2] === 'themes.json') {
        validateThemes(selected.themes, Date.now());
        if (Date.now() >= instant(selected.endsAt)) return reply(503, head);
        return new Response(head ? null : JSON.stringify(selected.themes), { headers: { ...headers, 'Content-Type': 'application/json; charset=utf-8' } });
      }
      const binding = { async fetch(input) {
        const requested = new URL(input.url);
        const internal = new URL(`/__program/editions/${selected.id}${requested.pathname}`, url);
        if (!requested.pathname.endsWith('/catalog.json')) return env.OFFICIAL_ASSETS.fetch(new Request(internal, { redirect: 'manual' }));
        const bytes = await read(env.OFFICIAL_ASSETS, internal);
        const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(v => v.toString(16).padStart(2, '0')).join('');
        require(digest === selected.catalogs[channel]);
        const catalog = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
        require(catalog.generatedAt === selected.startsAt && instant(catalog.validUntil) >= instant(selected.endsAt)
          && instant(catalog.validUntil) <= instant(index.through));
        return new Response(bytes);
      } };
      const result = await worker.fetch(request, { OFFICIAL_ASSETS: binding });
      if (Date.now() >= instant(selected.endsAt)) return reply(503, head);
      return result;
    } catch { return reply(503, head); }
  },
};
