import worker from './index.js';
import { instant } from './scheduled.js';

export const BLACK_CAT_CREDIT = 'ねこのまど（AI で作った画像）';
export const LOOP_IMAGES_PATH = '/__program/images/';
const DAY = 86400000, HASH = /^[a-f0-9]{64}$/;
const exact = (v, names) => v && typeof v === 'object' && !Array.isArray(v)
  && Object.keys(v).length === names.length && names.every(k => Object.hasOwn(v, k));
const require = value => { if (!value) throw new Error('Invalid black-cat loop'); };
const stamp = value => new Date(value).toISOString().replace('.000Z', 'Z');
const dayStart = at => Math.floor((at + 9 * 3600000) / DAY) * DAY - 9 * 3600000;
const midnight = value => { const at = instant(value); require(dayStart(at) === at); return at; };

export function loopPosition(epoch, at) {
  const days = Math.floor((dayStart(at) - instant(epoch.cycleStartsAt)) / DAY);
  require(days >= 0 && Number.isSafeInteger(days));
  return days % epoch.order.length;
}

export function validateBlackCatLoop(index) {
  require(exact(index, ['schemaVersion', 'credit', 'images', 'epochs']) && index.schemaVersion === 3
    && index.credit === BLACK_CAT_CREDIT && Array.isArray(index.images) && index.images.length >= 1 && index.images.length <= 600
    && Array.isArray(index.epochs) && index.epochs.length >= 1 && index.epochs.length <= 64);
  const hashes = new Set();
  for (const image of index.images) {
    require(exact(image, ['sha256', 'width', 'height']) && HASH.test(image.sha256) && !hashes.has(image.sha256)
      && Number.isInteger(image.width) && image.width >= 1 && image.width <= 2048
      && Number.isInteger(image.height) && image.height >= 1 && image.height <= 2048);
    hashes.add(image.sha256);
  }
  const referenced = new Set();
  for (const [i, epoch] of index.epochs.entries()) {
    require(exact(epoch, ['action', 'startsAt', 'cycleStartsAt', 'order'])
      && Array.isArray(epoch.order) && epoch.order.length >= 1 && epoch.order.length <= 60
      && new Set(epoch.order).size === epoch.order.length && epoch.order.every(hash => hashes.has(hash)));
    epoch.order.forEach(hash => referenced.add(hash));
    const start = midnight(epoch.startsAt), cycle = midnight(epoch.cycleStartsAt);
    require(cycle <= start);
    if (i === 0) { require(epoch.action === 'create' && cycle === start); continue; }
    const previous = index.epochs[i - 1];
    require(start > instant(previous.startsAt));
    if (epoch.action === 'append') {
      require(epoch.order.length > previous.order.length && previous.order.every((hash, n) => epoch.order[n] === hash));
      // Continue the prior cycle, including newly appended slots before 001.
      const nextPosition = loopPosition(previous, start - DAY) + 1;
      require(cycle === start - nextPosition * DAY);
    } else { require(epoch.action === 'reset' && cycle === start); }
  }
  require(referenced.size === hashes.size);
  return index;
}

export function blackCatDay(index, now) {
  require(Number.isFinite(now));
  const epoch = index.epochs.findLast(value => instant(value.startsAt) <= now);
  if (!epoch) return null;
  const start = dayStart(now), end = start + DAY;
  const selected = epoch.order[loopPosition(epoch, now)];
  const image = index.images.find(value => value.sha256 === selected);
  require(image);
  const date = stamp(start + 9 * 3600000).slice(0, 10);
  return { start, end, epoch, catalog: { schemaVersion: 1, channelID: 'black-cats', enabled: true,
    generatedAt: stamp(start), validUntil: stamp(end), photos: [{
      id: 'black-' + date.replaceAll('-', ''), catID: 'generated-black-cat', catName: '黒猫', credit: index.credit,
      publishedAt: stamp(start), expiresAt: stamp(end), imageFilename: selected + '.jpg', ...image,
    }] } };
}

const response = (status, head) => new Response(head ? null : status === 404 ? 'Not found' : 'Feed temporarily unavailable', {
  status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' },
});

export async function serveBlackCatLoop(request, env, index) {
  const url = new URL(request.url), head = request.method === 'HEAD';
  const route = /^\/windows\/black-cats\/(catalog\.json|[a-f0-9]{64}\.jpg)$/.exec(url.pathname);
  if (url.search || !route) return response(404, head);
  const selected = blackCatDay(index, Date.now());
  if (!selected) return response(503, head);
  const filename = selected.catalog.photos[0].imageFilename;
  // Block non-current JPEGs before touching their bytes, including HEAD.
  if (route[1] !== 'catalog.json' && route[1] !== filename) return response(404, head);
  const binding = { async fetch(input) {
    const requested = new URL(input.url);
    if (requested.pathname === '/windows/black-cats/catalog.json') return new Response(JSON.stringify(selected.catalog));
    if (requested.pathname !== '/windows/black-cats/' + filename) return new Response(null, { status: 404 });
    return env.OFFICIAL_ASSETS.fetch(new Request(new URL(LOOP_IMAGES_PATH + filename, url), { redirect: 'manual' }));
  } };
  // Reuse the existing bounded reader and image digest validation. It also
  // rechecks expiry after I/O. The outer check covers catalog I/O as well.
  const result = await worker.fetch(request, { OFFICIAL_ASSETS: binding });
  if (Date.now() < selected.start || Date.now() >= selected.end) return response(503, head);
  return result;
}
