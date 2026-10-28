// Read-only preview checks. Only the adjacent last-check receipt is replaced;
// this tool never prepares assets, changes current/pending, or deploys.
import assert from 'node:assert/strict';
import { lstat, readdir, readFile, writeFile, rename, unlink } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { randomUUID } from 'node:crypto';
import { blackCatDay, validateBlackCatLoop, BLACK_CAT_CREDIT } from '../src/black-cat-loop.js';
import { activeFiles } from '../src/index.js';
import { activeVersion } from './verify_preview.mjs';
import { directory, file, json, expectedConfig, hash, service } from './schedule_bundle.mjs';
import { validatePublisherJPEG } from './prepare_maintenance.mjs';

export const PREVIEW_ORIGIN = 'https://neko-widget-official-cats-preview.nakanishisoya.workers.dev';
export const DEFAULT_CURRENT = 'C:/dev/neko-official-supply-20260913/output/runtime/current.json';
const ROUTE = '/windows/black-cats/', DAY = 86400000;
const modules = ['index.js', 'program.js', 'scheduled.js', 'black-cat-loop.js'];
const messages = {
  local: 'Invalid local monitor input or receipt.', pending: 'A deployment is pending; no check was accepted.',
  pointer: 'The current pointer is not a recorded black-cat loop.', bundle: 'The approved loop bundle does not match.',
  version: 'The recorded preview Worker version could not be confirmed.', catalog: 'The current catalog does not match the approved JST day.',
  image: 'The current JPEG does not match the approved image.', forbidden: 'A non-current or internal route was not denied.',
  changed: 'The deployment inputs changed during verification.', boundary: 'Verification crossed the JST day boundary.',
};
class CheckError extends Error {
  constructor(code) { super(messages[code]); this.code = code; }
}
// Do not print child-process stderr, remote bodies, or local manifest contents.
async function checked(code, action) {
  try { return await action(); } catch { throw new CheckError(code); }
}
async function noPending(current) {
  try { await lstat(path.join(path.dirname(current), 'pending.json')); }
  catch (error) { if (error.code === 'ENOENT') return; throw new CheckError('pending'); }
  throw new CheckError('pending');
}
function absoluteLocal(value) {
  assert(typeof value === 'string' && path.isAbsolute(value)
    && !value.startsWith('\\\\') && !value.startsWith('//'));
  return path.resolve(value);
}
async function approvedBundle(bundle) {
  const root = await directory(bundle), config = await expectedConfig(); config.main = './program.js';
  assert.equal(config.name, 'neko-widget-official-cats-preview');
  assert.equal(config.account_id, '829a34ef925a39d81b0e9e08800d7c7f');
  assert.equal(config.assets.run_worker_first, true); assert.equal(config.preview_urls, false);
  assert.deepEqual(await json(path.join(root, 'wrangler.jsonc')), config);
  for (const name of modules) assert.deepEqual(await file(path.join(root, name)), await file(path.join(service, 'src', name)));
  const assets = await directory(path.join(root, 'assets'));
  assert.deepEqual(await readdir(assets), ['__program']);
  const program = await directory(path.join(assets, '__program'));
  assert.deepEqual((await readdir(program)).sort(), ['images', 'index.json']);
  const index = validateBlackCatLoop(await json(path.join(program, 'index.json')));
  const images = await directory(path.join(program, 'images'));
  assert.deepEqual((await readdir(images)).sort(), index.images.map(row => row.sha256 + '.jpg').sort());
  for (const row of index.images) {
    const bytes = await file(path.join(images, row.sha256 + '.jpg'), 4 * 1024 * 1024);
    assert.equal(hash(bytes), row.sha256); validatePublisherJPEG(bytes, row.width, row.height);
  }
  const review = await json(path.join(root, 'schedule-review.json'));
  const input = await json(path.join(root, 'loop-config.json')), latest = index.epochs.at(-1);
  assert(review.schemaVersion === 1 && review.kind === 'black-cat-loop' && review.publicationApproved === true
    && review.credit === BLACK_CAT_CREDIT && review.hourJST === 0 && review.imageCount === latest.order.length);
  assert(input.schemaVersion === 1 && input.credit === BLACK_CAT_CREDIT && input.action === latest.action);
  assert.equal(review.action, input.action); assert.equal(review.startDate, input.startDate);
  assert.equal(Date.parse(input.startDate + 'T00:00:00Z') - 9 * 3600000, Date.parse(latest.startsAt));
  assert.deepEqual(review.order.map(row => row.sha256), latest.order);
  assert.deepEqual(review.order.map(row => row.filename), input.order);
  for (const row of review.order) {
    const image = index.images.find(value => value.sha256 === row.sha256);
    assert.equal(row.width, image.width); assert.equal(row.height, image.height);
  }
  return { root, index };
}
async function responseBytes(response, maximum) {
  assert(response.body); const reader = response.body.getReader(), chunks = []; let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      length += value.byteLength; assert(length <= maximum); chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  assert(length > 0); return Buffer.concat(chunks);
}

export async function verifyBlackCatLoop(current, { fetcher = fetch, versionReader = activeVersion, clock = Date.now } = {}) {
  await noPending(current);
  const before = await checked('pointer', async () => {
    absoluteLocal(current);
    const bytes = await file(current), pointer = JSON.parse(bytes.toString('utf8'));
    assert(pointer.schemaVersion === 2 && pointer.mode === 'loop');
    absoluteLocal(pointer.currentBundle); assert(/^[a-f0-9-]{36}$/.test(pointer.workerVersion));
    return { bytes, pointer };
  });
  const { root, index } = await checked('bundle', () => approvedBundle(before.pointer.currentBundle));
  const config = path.join(root, 'wrangler.jsonc');
  const version = () => checked('version', async () => assert.equal(await versionReader(config), before.pointer.workerVersion));
  await version();
  const now = clock(), selected = await checked('catalog', () => {
    const day = blackCatDay(index, now); assert(day); activeFiles(day.catalog, now, 'black-cats');
    assert.equal(day.end - day.start, DAY); assert.equal((day.end + 9 * 3600000) % DAY, 0); return day;
  });
  const request = (route, method = 'GET') => fetcher(PREVIEW_ORIGIN + route,
    { method, redirect: 'error', signal: AbortSignal.timeout(15000), cache: 'no-store' });
  await checked('catalog', async () => {
    const response = await request(ROUTE + 'catalog.json'); assert.equal(response.status, 200);
    assert(response.headers.get('content-type')?.startsWith('application/json'));
    const catalog = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await responseBytes(response, 256 * 1024)));
    assert.deepEqual(catalog, selected.catalog);
  });
  const photo = selected.catalog.photos[0];
  await checked('image', async () => {
    const response = await request(ROUTE + photo.imageFilename); assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'image/jpeg');
    const bytes = await responseBytes(response, 4 * 1024 * 1024);
    assert.equal(hash(bytes), photo.sha256); validatePublisherJPEG(bytes, photo.width, photo.height);
  });
  // One non-current JPEG exercises the shared deny rule. Prefer tomorrow's
  // selection; checking every stored image would add no route coverage.
  const nextPhoto = blackCatDay(index, selected.end)?.catalog.photos[0];
  const nonCurrent = nextPhoto?.sha256 !== photo.sha256 && nextPhoto
    ? nextPhoto : index.images.find(row => row.sha256 !== photo.sha256);
  const denied = ['/catalog.json', '/windows/weekly-theme/catalog.json', '/loop-config.json', '/schedule-review.json',
    '/__program/index.json', '/__program/images/' + photo.imageFilename, ROUTE + 'catalog.json?future=1',
    ROUTE + '%2e%2e%2f__program/index.json',
    ...(nonCurrent ? [ROUTE + nonCurrent.sha256 + '.jpg'] : [])];
  await checked('forbidden', async () => {
    for (const route of denied) for (const method of ['GET', 'HEAD']) {
      const response = await request(route, method);
      try { assert.equal(response.status, 404); } finally { await response.body?.cancel(); }
    }
  });
  await version();
  await noPending(current);
  await checked('changed', async () => {
    assert.deepEqual(await file(current), before.bytes);
    assert.deepEqual(await approvedBundle(root), { root, index });
  });
  const end = clock();
  if (end < selected.start || end >= selected.end) throw new CheckError('boundary');
  return { checkedAt: new Date(end).toISOString(), workerVersion: before.pointer.workerVersion,
    photoID: photo.id, sha256: photo.sha256, validUntil: selected.catalog.validUntil };
}

export async function checkBlackCatLoop({ current = DEFAULT_CURRENT,
  receipt = path.join(path.dirname(current), 'last-black-cat-loop-check.json'), ...dependencies } = {}) {
  // Only a sibling receipt may be written, never a pointer, pending operation or approved asset.
  await checked('local', async () => {
    current = absoluteLocal(current); receipt = absoluteLocal(receipt);
    assert.equal(path.dirname(receipt), path.dirname(current));
    assert(![path.basename(current).toLowerCase(), 'pending.json'].includes(path.basename(receipt).toLowerCase()));
    await directory(path.dirname(current));
  });
  let previous;
  try { previous = await json(receipt); }
  catch (error) { if (error.code !== 'ENOENT') throw new CheckError('local'); }
  if (previous && (previous.schemaVersion !== 1 || previous.mode !== 'loop-monitor')) throw new CheckError('local');
  let result;
  try {
    const verified = await verifyBlackCatLoop(current, dependencies);
    const changed = !!previous?.lastSuccess && (previous.lastSuccess.photoID !== verified.photoID || previous.lastSuccess.sha256 !== verified.sha256);
    result = { schemaVersion: 1, mode: 'loop-monitor', status: 'ok', notify: changed, ...verified, lastSuccess: verified, failure: null };
  } catch (error) {
    const code = error instanceof CheckError ? error.code : 'local';
    result = { schemaVersion: 1, mode: 'loop-monitor', status: 'failed', checkedAt: new Date((dependencies.clock ?? Date.now)()).toISOString(),
      notify: previous?.failure !== code, failure: code, message: messages[code], lastSuccess: previous?.lastSuccess ?? null };
  }
  const temporary = receipt + '.' + randomUUID() + '.tmp';
  try {
    await writeFile(temporary, JSON.stringify(result, null, 2) + '\n', { flag: 'wx' });
    await rename(temporary, receipt);
  } finally { await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { current: { type: 'string' }, receipt: { type: 'string' } } });
    const result = await checkBlackCatLoop({ ...(values.current ? { current: values.current } : {}),
      ...(values.receipt ? { receipt: values.receipt } : {}) });
    console.log(JSON.stringify(result)); if (result.status === 'failed') process.exitCode = 1;
  } catch { console.error(JSON.stringify({ status: 'failed', notify: true, failure: 'local', message: messages.local })); process.exitCode = 1; }
}
