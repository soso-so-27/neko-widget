// Local schedule inspection. Internal history is never copied into static assets.
import assert from 'node:assert/strict';
import { lstat, realpath, readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { activeFiles } from '../src/index.js';
import { CHANNELS, INDEX_PATH, selectEdition, validateSchedule, instant } from '../src/scheduled.js';
import { validatePublisherJPEG } from './prepare_maintenance.mjs';

export const service = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const stamp = value => new Date(value).toISOString().replace('.000Z', 'Z');
export const hash = bytes => createHash('sha256').update(bytes).digest('hex');
export const route = channel => channel === 'official-cats' ? '' : `windows/${channel}`;
export async function directory(value) {
  assert(typeof value === 'string' && path.isAbsolute(value) && !value.startsWith('\\\\') && !value.startsWith('//'), 'Use absolute local paths');
  const info = await lstat(value);
  assert(info.isDirectory() && !info.isSymbolicLink(), 'Use a regular local directory');
  return realpath(value);
}
export async function file(value, maximum = 2 * 1024 * 1024) {
  const info = await lstat(value);
  assert(info.isFile() && !info.isSymbolicLink() && info.size > 0 && info.size <= maximum, 'Invalid local schedule file');
  return readFile(value);
}
export const json = async value => JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await file(value)));
export function outside(source, target) {
  const relative = path.relative(source, target);
  return relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative);
}
export async function newOutput(output, inputs = []) {
  assert(typeof output === 'string' && path.isAbsolute(output), 'Use an absolute output path');
  const parent = await directory(path.dirname(output)), target = path.join(parent, path.basename(output));
  for (const input of inputs) assert(outside(await directory(input), target), 'Output must be outside every input');
  try { await lstat(target); assert.fail('Output already exists'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  return target;
}
export async function expectedConfig(scheduled = false) {
  const config = await json(path.join(service, 'wrangler.jsonc'));
  delete config.$schema;
  config.main = scheduled ? './scheduled.js' : './worker.js';
  config.assets.directory = './assets';
  return config;
}
export async function validateDeployment(bundle, scheduled = false) {
  const root = await directory(bundle);
  assert.deepEqual(await json(path.join(root, 'wrangler.jsonc')), await expectedConfig(scheduled), 'Deployment configuration changed');
  assert.deepEqual(await file(path.join(root, scheduled ? 'index.js' : 'worker.js')),
    await file(path.join(service, 'src/index.js')), 'Base Worker changed');
  if (scheduled) assert.deepEqual(await file(path.join(root, 'scheduled.js')), await file(path.join(service, 'src/scheduled.js')), 'Scheduled Worker changed');
  return root;
}
export async function readEdition(assetRoot, record, at, { through, expectedHashes } = {}) {
  assert(record?.schemaVersion === 1 && Array.isArray(record.channels), 'Edition history required');
  assert.deepEqual(record.channels.map(row => row.channelID).sort(), [...CHANNELS].sort(), 'Exactly the three existing channels are required');
  const photos = [], catalogs = {};
  for (const channel of CHANNELS) {
    const location = await directory(path.join(assetRoot, route(channel)));
    const catalogBytes = await file(path.join(location, 'catalog.json'), 256 * 1024), catalog = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(catalogBytes));
    activeFiles(catalog, at, channel);
    assert.equal(catalog.generatedAt, record.generatedAt, 'Edition and history time differ');
    assert(instant(catalog.generatedAt) <= at, 'Future edition cannot be restored');
    if (through !== undefined) assert(instant(catalog.validUntil) <= through, 'Catalog outlives schedule');
    if (expectedHashes) assert.equal(hash(catalogBytes), expectedHashes[channel], 'Scheduled catalog hash differs');
    const row = record.channels.find(row => row.channelID === channel);
    assert.equal(row.enabled, catalog.enabled, 'History and pause state differ');
    assert(Array.isArray(row.history), 'History required');
    if (channel === 'cat-tabby-nap') {
      assert.equal(row.catID, 'generated-tabby-nap', 'Cat-window constraint required');
      assert([...row.history, ...catalog.photos].every(photo => photo.catID === row.catID), 'Different cat in cat window');
    }
    const historicalIDs = new Set();
    for (const photo of row.history) {
      assert(typeof photo.id === 'string' && /^[a-z0-9-]{1,64}$/.test(photo.id) && !historicalIDs.has(photo.id)
        && /^[a-f0-9]{64}$/.test(photo.sha256) && instant(photo.publishedAt) <= at, 'Invalid or future publication history');
      historicalIDs.add(photo.id);
    }
    const expected = new Set(['catalog.json', ...catalog.photos.map(photo => photo.imageFilename), ...(channel === 'official-cats' ? ['windows'] : [])]);
    const entries = await readdir(location);
    assert(entries.length === expected.size && entries.every(name => expected.has(name)), 'Unexpected edition asset');
    for (const photo of catalog.photos) {
      const previous = row.history.find(known => known.id === photo.id);
      assert(previous && previous.sha256 === photo.sha256 && previous.publishedAt === photo.publishedAt, 'Photo missing from publication history');
      const bytes = await file(path.join(location, photo.imageFilename), 4 * 1024 * 1024);
      assert.equal(hash(bytes), photo.sha256, 'Edition JPEG checksum differs');
      validatePublisherJPEG(bytes, photo.width, photo.height);
      photos.push({ channel, photo, bytes });
    }
    catalogs[channel] = { catalog, bytes: catalogBytes };
  }
  const windows = await readdir(await directory(path.join(assetRoot, 'windows')));
  assert.deepEqual(windows.sort(), ['cat-tabby-nap', 'nap-cats'], 'Unknown asset channel');
  return { catalogs, photos };
}
export async function copyEdition(contents, target) {
  await mkdir(target);
  await mkdir(path.join(target, 'windows'));
  for (const channel of CHANNELS) {
    const output = path.join(target, route(channel));
    if (channel !== 'official-cats') await mkdir(output);
    await writeFile(path.join(output, 'catalog.json'), contents.catalogs[channel].bytes, { flag: 'wx' });
    for (const filename of new Set(contents.photos.filter(photo => photo.channel === channel).map(photo => photo.photo.imageFilename))) {
      const image = contents.photos.find(photo => photo.channel === channel && photo.photo.imageFilename === filename);
      await writeFile(path.join(output, filename), image.bytes, { flag: 'wx' });
    }
  }
}
export async function scheduleIndex(bundle) {
  const root = await validateDeployment(bundle, true);
  const assets = await directory(path.join(root, 'assets'));
  assert.deepEqual(await readdir(assets), ['__schedule'], 'Only internal scheduled assets are allowed');
  await directory(path.join(assets, '__schedule'));
  const index = validateSchedule(await json(path.join(assets, INDEX_PATH.slice(1))));
  assert.deepEqual((await readdir(path.join(assets, '__schedule'))).sort(), ['editions', 'index.json'], 'Unexpected schedule file');
  const editions = await directory(path.join(assets, '__schedule/editions'));
  assert.deepEqual((await readdir(editions)).sort(), index.editions.map(edition => edition.id).sort(), 'Unrecorded edition directory');
  return { root, assets, index };
}
export async function currentScheduledEdition(bundle, now = Date.now(), { allowExpired = false } = {}) {
  const { root, assets, index } = await scheduleIndex(bundle);
  const expired = now >= instant(index.through);
  const selected = selectEdition(index, now) ?? (allowExpired && expired ? index.editions.at(-1) : null);
  assert(selected, 'No currently valid scheduled edition; expired recovery requires explicit approval, never a future edition');
  const local = await json(path.join(root, 'schedule-record.json'));
  assert(local.schemaVersion === 1 && local.kind === 'planned-editions' && Array.isArray(local.editions)
    && local.editions.length === index.editions.length, 'Local planned history required');
  assert.deepEqual(local.editions.map(row => row.id), index.editions.map(row => row.id), 'Planned history and index differ');
  const record = local.editions.find(row => row.id === selected.id).record;
  assert.equal(record.generatedAt, selected.startsAt, 'Planned history time differs');
  // Expired recovery uses only an edition whose whole serving interval is over.
  // Keep historical photo deadlines unchanged; prepareUpdate removes expired photos.
  const content = await readEdition(path.join(assets, '__schedule/editions', selected.id), record, expired ? instant(selected.startsAt) : now,
    { through: instant(index.through), expectedHashes: selected.catalogs });
  for (const { catalog } of Object.values(content.catalogs)) assert(instant(catalog.validUntil) >= instant(selected.endsAt), 'Edition ends after its catalog');
  return { root, index, selected, record, content, expired };
}
