// A dedicated read-only feed. No bindings to private windows, accounts or media.
const CATALOG_BYTES = 256 * 1024;
const IMAGE_BYTES = 4 * 1024 * 1024;
const SLUG = /^[a-z0-9-]{1,64}$/;
const HASH = /^[a-f0-9]{64}$/;
const TOP_KEYS = new Set(['schemaVersion', 'channelID', 'enabled', 'generatedAt', 'validUntil', 'photos']);
const PHOTO_KEYS = new Set(['id', 'catID', 'catName', 'credit', 'caption', 'photographedOn', 'publishedAt', 'expiresAt', 'imageFilename', 'sha256', 'width', 'height']);

function time(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) return NaN;
  const result = Date.parse(value);
  return Number.isFinite(result) && new Date(result).toISOString().replace('.000Z', 'Z') === value ? result : NaN;
}

function text(value, maximum, caption = false) {
  return typeof value === 'string' && [...value].length > 0 && [...value].length <= maximum
    && value.trim() === value && !/[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u2028\u2029\ud800-\udfff]/u.test(value)
    && (caption ? value.split('\n').length <= 3 : !value.includes('\n'));
}

export function activeFiles(catalog, now = Date.now()) {
  const invalid = () => { throw new Error('Invalid official catalog'); };
  if (!catalog || typeof catalog !== 'object' || Array.isArray(catalog)
      || Object.keys(catalog).some(key => !TOP_KEYS.has(key))
      || catalog.schemaVersion !== 1 || catalog.channelID !== 'official-cats'
      || typeof catalog.enabled !== 'boolean' || !Array.isArray(catalog.photos)
      || catalog.photos.length > 60 || (!catalog.enabled && catalog.photos.length !== 0)) invalid();
  const generated = time(catalog.generatedAt), until = time(catalog.validUntil);
  if (!Number.isFinite(generated) || !Number.isFinite(until)
      || generated > now + 300_000 || until <= generated || until - generated > 48 * 3600_000 || now >= until) invalid();
  const ids = new Set(), files = new Set();
  for (const photo of catalog.photos) {
    if (!photo || typeof photo !== 'object' || Array.isArray(photo)
        || Object.keys(photo).some(key => !PHOTO_KEYS.has(key))
        || typeof photo.id !== 'string' || !SLUG.test(photo.id) || ids.has(photo.id)
        || typeof photo.catID !== 'string' || !SLUG.test(photo.catID)
        || !text(photo.catName, 30) || !text(photo.credit, 80)
        || (photo.caption !== undefined && !text(photo.caption, 100, true))
        || typeof photo.sha256 !== 'string' || !HASH.test(photo.sha256)
        || photo.imageFilename !== `${photo.sha256}.jpg`
        || !Number.isInteger(photo.width) || photo.width < 1 || photo.width > 2048
        || !Number.isInteger(photo.height) || photo.height < 1 || photo.height > 2048) invalid();
    if (photo.photographedOn !== undefined && (typeof photo.photographedOn !== 'string'
        || !/^\d{4}-\d{2}-\d{2}$/.test(photo.photographedOn)
        || !Number.isFinite(time(`${photo.photographedOn}T00:00:00Z`)))) invalid();
    const published = time(photo.publishedAt), expires = time(photo.expiresAt);
    if (!Number.isFinite(published) || !Number.isFinite(expires) || published > generated
        || expires <= published || expires - published > 14 * 86400_000) invalid();
    ids.add(photo.id);
    if (published <= now && now < expires) files.add(photo.imageFilename);
  }
  return files;
}

async function readAsset(binding, url, maximum) {
  // Discard incoming cookies, auth, conditional and range headers.
  const response = await binding.fetch(new Request(url, { method: 'GET', redirect: 'manual' }));
  if (response.status !== 200 || !response.body) throw new Error('Asset unavailable');
  const reader = response.body.getReader(), chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximum) throw new Error('Asset too large');
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  if (size === 0) throw new Error('Empty asset');
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}

function reply(body, status, contentType, head = false, extra = {}) {
  return new Response(head ? null : body, {
    status,
    headers: {
      'Content-Type': contentType,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
      ...extra,
    },
  });
}

export default {
  async fetch(request, env) {
    const head = request.method === 'HEAD';
    if (request.method !== 'GET' && !head) return reply('Method not allowed', 405, 'text/plain; charset=utf-8', false, { Allow: 'GET, HEAD' });
    const url = new URL(request.url);
    const image = /^\/([a-f0-9]{64}\.jpg)$/.exec(url.pathname);
    if (url.search || (url.pathname !== '/catalog.json' && !image)) return reply('Not found', 404, 'text/plain; charset=utf-8', head);
    try {
      const raw = await readAsset(env.OFFICIAL_ASSETS, new URL('/catalog.json', url), CATALOG_BYTES);
      const catalog = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw));
      const files = activeFiles(catalog);
      if (!image) return reply(JSON.stringify(catalog), 200, 'application/json; charset=utf-8', head);
      if (!files.has(image[1])) return reply('Not found', 404, 'text/plain; charset=utf-8', head);
      const bytes = await readAsset(env.OFFICIAL_ASSETS, new URL(url.pathname, url), IMAGE_BYTES);
      const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(byte => byte.toString(16).padStart(2, '0')).join('');
      if (`${digest}.jpg` !== image[1]) throw new Error('Image digest mismatch');
      // Asset I/O may cross a publication deadline. Check again at reply time.
      if (!activeFiles(catalog).has(image[1])) return reply('Not found', 404, 'text/plain; charset=utf-8', head);
      return reply(bytes, 200, 'image/jpeg', head);
    } catch {
      // A broken/expired edition must not reveal other files or old photos.
      return reply('Feed temporarily unavailable', 503, 'text/plain; charset=utf-8', head, { 'Retry-After': '300' });
    }
  },
};
