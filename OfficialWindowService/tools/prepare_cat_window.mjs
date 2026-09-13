// First creation from a current public allowlist. No upload or pointer changes.
import { lstat, readFile, realpath, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { parseArgs, isDeepStrictEqual } from 'node:util';
import { activeFiles } from '../src/index.js';
import { CAT_WINDOWS, prepareUpdate } from './prepare_update.mjs';
import { prepareBundle } from './prepare_bundle.mjs';
import { validatePublisherJPEG } from './prepare_maintenance.mjs';

function require(condition, message) { if (!condition) throw new Error(message); }
function localPath(value) {
  require(typeof value === 'string' && path.isAbsolute(value)
    && !value.startsWith('\\\\') && !value.startsWith('//'), 'Use absolute local paths');
  return path.resolve(value);
}
async function directory(value) {
  const resolved = localPath(value), info = await lstat(resolved);
  require(info.isDirectory() && !info.isSymbolicLink(), 'Use a regular local directory');
  return localPath(await realpath(resolved));
}
async function file(filename, maximum = 2 * 1024 * 1024) {
  const info = await lstat(filename);
  require(info.isFile() && !info.isSymbolicLink() && info.size <= maximum, 'Invalid local source file');
  const bytes = await readFile(filename);
  require(bytes.length <= maximum, 'Source file exceeded its size limit');
  return bytes;
}
const json = async filename => JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await file(filename)));
async function absent(filename) {
  try { await lstat(filename); throw new Error('Cat window or output already exists'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
}

export async function prepareCatWindow(previous, channelID, output, now = Math.floor(Date.now() / 1000) * 1000) {
  require(typeof channelID === 'string' && Object.hasOwn(CAT_WINDOWS, channelID), 'Unknown cat window');
  require(Number.isSafeInteger(now) && now % 1000 === 0, 'Use a whole-second creation time');
  const definition = CAT_WINDOWS[channelID], root = await directory(previous);
  const destination = localPath(output), parent = await directory(path.dirname(destination));
  const target = path.join(parent, path.basename(destination)), relative = path.relative(root, target);
  require(relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative), 'Output must be outside the previous bundle');
  await absent(target);
  const record = await json(path.join(root, 'update-record.json'));
  require(record.schemaVersion === 1 && Array.isArray(record.channels), 'Publication history is required');
  require(!record.channels.some(row => row.channelID === channelID), 'Cat window already exists, including paused or withdrawn history');
  const assetRoot = await directory(path.join(root, 'assets'));
  await absent(path.join(assetRoot, 'windows', channelID));
  const source = await json(path.join(assetRoot, 'catalog.json'));
  const allowed = activeFiles(source, now, definition.sourceChannelID);
  require(source.enabled, 'Source window is paused');
  const photos = source.photos.filter(photo => photo.catID === definition.catID && allowed.has(photo.imageFilename)
    && Date.parse(photo.publishedAt) <= now && Date.parse(photo.expiresAt) > now)
    .sort((a, b) => b.publishedAt.localeCompare(a.publishedAt) || a.id.localeCompare(b.id));
  require(photos.length > 0, 'No current photos for the exact cat ID');
  const sourceHistory = record.channels.find(row => row.channelID === definition.sourceChannelID)?.history;
  require(Array.isArray(sourceHistory), 'Source publication history is required');
  const images = new Map();
  for (const photo of photos) {
    require(sourceHistory.some(old => old.id === photo.id && old.catID === definition.catID
      && old.sha256 === photo.sha256 && old.publishedAt === photo.publishedAt), 'Source cat identity differs from publication history');
    const bytes = await file(path.join(assetRoot, photo.imageFilename), 4 * 1024 * 1024);
    require(createHash('sha256').update(bytes).digest('hex') === photo.sha256, 'Source JPEG hash differs');
    validatePublisherJPEG(bytes, photo.width, photo.height);
    images.set(photo.imageFilename, bytes);
  }
  // A creation must not also roll the Worker or its target configuration.
  const service = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const config = await json(path.join(service, 'wrangler.jsonc'));
  delete config.$schema; config.main = './worker.js'; config.assets.directory = './assets';
  require(isDeepStrictEqual(await json(path.join(root, 'wrangler.jsonc')), config), 'Previous Worker configuration differs');
  require((await file(path.join(root, 'worker.js'))).equals(await file(path.join(service, 'src/index.js'))), 'Previous Worker code differs');

  // prepareUpdate validates every old channel/history and retains pause states.
  // A failed partial output stays available for review; its name is never reused.
  await mkdir(target);
  const prepared = await prepareUpdate(root, { schemaVersion: 1, channels: [] }, path.join(target, 'existing'), now);
  const catAssets = path.join(target, 'cat-assets');
  await mkdir(catAssets);
  for (const [name, bytes] of images) await writeFile(path.join(catAssets, name), bytes, { flag: 'wx' });
  const catalog = { schemaVersion: 1, channelID, enabled: true, generatedAt: prepared.generatedAt,
    validUntil: prepared.validUntil, photos };
  activeFiles(catalog, now, channelID);
  await writeFile(path.join(catAssets, 'catalog.json'), JSON.stringify(catalog, null, 2) + '\n', { flag: 'wx' });
  const baseEditions = path.join(target, 'existing', 'editions');
  const extra = prepared.channels.filter(row => row.channelID !== 'official-cats').map(row => path.join(baseEditions, row.channelID));
  const bundle = await prepareBundle(path.join(baseEditions, 'official-cats'), path.join(target, 'bundle'), undefined, [...extra, catAssets]);
  const { bundle: stagedBundle, ...nextRecord } = prepared;
  nextRecord.channels.push({ channelID, catID: definition.catID, enabled: true,
    referencedFrom: definition.sourceChannelID, referenced: photos.map(photo => photo.id), added: [],
    withdrawn: [], expired: [], renewed: [], activeCount: photos.length, newestPhotoID: photos[0].id,
    earliestPhotoExpiry: new Date(Math.min(...photos.map(photo => Date.parse(photo.expiresAt)))).toISOString().replace('.000Z', 'Z'),
    history: photos });
  await writeFile(path.join(bundle.directory, 'update-record.json'), JSON.stringify(nextRecord, null, 2) + '\n', { flag: 'wx' });
  const result = { bundle: bundle.directory, channelID, catID: definition.catID, displayName: definition.displayName,
    sourceBundle: root, generatedAt: prepared.generatedAt, validUntil: prepared.validUntil,
    referencedPhotoIDs: photos.map(photo => photo.id), maintenanceDueAt: prepared.maintenanceDueAt };
  await writeFile(path.join(target, 'creation-record.json'), JSON.stringify(result, null, 2) + '\n', { flag: 'wx' });
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { previous: { type: 'string' }, window: { type: 'string' }, output: { type: 'string' } } });
    require(values.previous && values.window && values.output, 'Usage: node tools/prepare_cat_window.mjs --previous <deployed-bundle> --window cat-tabby-nap --output <new-directory>');
    console.log(JSON.stringify(await prepareCatWindow(values.previous, values.window, values.output), null, 2));
    console.log('Local candidate only. No deployment or maintenance-pointer update was performed.');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
