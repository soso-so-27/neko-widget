// Local edition preparation. Does not upload, schedule, or change source files.
import { lstat, readdir, readFile, mkdir, writeFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { activeFiles } from '../src/index.js';
import { prepareBundle } from './prepare_bundle.mjs';

const slug = /^[a-z0-9-]{1,64}$/;
// Initial operator-owned cat window. This is not a registration or posting API.
export const CAT_WINDOWS = Object.freeze({
  'cat-tabby-nap': Object.freeze({ catID: 'generated-tabby-nap', displayName: 'キジ白のまど', sourceChannelID: 'official-cats' }),
});
const stamp = value => new Date(value).toISOString().replace('.000Z', 'Z');
function keys(value, allowed) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).some(key => !allowed.includes(key))) throw new Error('Unknown or invalid plan field');
}
function instant(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)
      || !Number.isFinite(Date.parse(value)) || stamp(Date.parse(value)) !== value) throw new Error('Use a valid UTC timestamp');
  return Date.parse(value);
}
async function localDirectory(value) {
  const resolved = path.resolve(value);
  if (resolved.startsWith('\\\\') || resolved.startsWith('//')) throw new Error('Use local directories');
  const info = await lstat(resolved);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Use a regular directory');
  return realpath(resolved);
}
async function regularFile(filename, maximum) {
  const info = await lstat(filename);
  if (!info.isFile() || info.isSymbolicLink() || info.size > maximum) throw new Error('Invalid input file');
  return readFile(filename);
}
async function jsonFile(filename) {
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await regularFile(filename, 2 * 1024 * 1024)));
}
async function edition(directory, channelID, now, legacy = false) {
  const root = await localDirectory(directory);
  const catalog = await jsonFile(path.join(root, 'catalog.json'));
  const generated = instant(catalog.generatedAt);
  if (generated > now) throw new Error('A source edition is from the future');
  // A previous edition may have expired. Validate it at its own publication time;
  // eligibility in the NEW edition is evaluated below at the actual current time.
  activeFiles(catalog, generated, channelID);
  const names = new Set(catalog.photos.map(photo => photo.imageFilename));
  const allowed = new Set(['catalog.json', ...names, ...(legacy ? ['windows'] : [])]);
  if ((await readdir(root)).some(name => !allowed.has(name))) throw new Error('Unexpected file in source assets');
  const images = new Map();
  for (const name of names) {
    const bytes = await regularFile(path.join(root, name), 4 * 1024 * 1024);
    if (bytes.length < 4 || bytes[0] !== 255 || bytes[1] !== 216 || bytes.at(-2) !== 255 || bytes.at(-1) !== 217
        || createHash('sha256').update(bytes).digest('hex') + '.jpg' !== name) throw new Error('JPEG hash or format mismatch');
    images.set(name, bytes);
  }
  return { catalog, images };
}

export async function prepareUpdate(previous, plan, output, now = Math.floor(Date.now() / 1000) * 1000) {
  keys(plan, ['schemaVersion', 'validForHours', 'channels', 'bootstrapHistory']);
  const hours = plan.validForHours ?? 48;
  if (plan.schemaVersion !== 1 || !Array.isArray(plan.channels) || !Number.isInteger(hours) || hours < 1 || hours > 48
      || (plan.bootstrapHistory !== undefined && plan.bootstrapHistory !== true)) throw new Error('Invalid update plan');
  const root = await localDirectory(previous);
  const assetRoot = await localDirectory(path.join(root, 'assets'));
  const channelIDs = ['official-cats'];
  try {
    const windows = await localDirectory(path.join(assetRoot, 'windows'));
    for (const name of await readdir(windows)) {
      if (!slug.test(name) || name === 'official-cats') throw new Error('Invalid existing channel');
      channelIDs.push(name);
    }
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const actions = new Map();
  for (const action of plan.channels) {
    keys(action, ['channelID', 'addAssets', 'withdraw', 'renewPhotos', 'paused']);
    if (!channelIDs.includes(action.channelID) || actions.has(action.channelID)
        || (action.paused !== undefined && typeof action.paused !== 'boolean')
        || (action.addAssets !== undefined && (typeof action.addAssets !== 'string' || !path.isAbsolute(action.addAssets)))) throw new Error('Invalid or duplicate channel action');
    actions.set(action.channelID, action);
  }
  let previousRecord;
  try { previousRecord = await jsonFile(path.join(root, 'update-record.json')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (!previousRecord && plan.bootstrapHistory !== true) throw new Error('Publication history is required; bootstrapHistory is only for the reviewed first migration');
  if (previousRecord && plan.bootstrapHistory === true) throw new Error('Cannot bootstrap an edition that already has publication history');
  if (previousRecord && (previousRecord.schemaVersion !== 1 || !Array.isArray(previousRecord.channels)
      || previousRecord.channels.length !== channelIDs.length
      || new Set(previousRecord.channels.map(row => row.channelID)).size !== channelIDs.length
      || previousRecord.channels.some(row => !channelIDs.includes(row.channelID) || !Array.isArray(row.history)))) throw new Error('Invalid previous publication record');
  const updates = [];
  for (const channelID of channelIDs) {
    const source = await edition(channelID === 'official-cats' ? assetRoot : path.join(assetRoot, 'windows', channelID), channelID, now, channelID === 'official-cats');
    const action = actions.get(channelID) ?? {};
    const old = source.catalog;
    if (Date.parse(old.generatedAt) >= now) throw new Error('New edition must be newer than the previous edition');
    const withdrawals = action.withdraw ?? [], renewals = action.renewPhotos ?? [];
    if (!Array.isArray(withdrawals) || !Array.isArray(renewals) || new Set(withdrawals).size !== withdrawals.length) throw new Error('Invalid withdrawals or renewals');
    const known = new Map(old.photos.map(photo => [photo.id, photo]));
    for (const id of withdrawals) if (!known.has(id)) throw new Error('Withdrawal must name a currently listed photo');
    const renewed = new Map();
    for (const renewal of renewals) {
      keys(renewal, ['id', 'expiresAt']);
      const photo = known.get(renewal.id);
      const until = instant(renewal.expiresAt);
      if (!photo || renewed.has(photo.id) || withdrawals.includes(photo.id)
          || Date.parse(photo.expiresAt) <= now || until <= Date.parse(photo.expiresAt)
          || until - Date.parse(photo.publishedAt) > 14 * 86400_000) throw new Error('Cannot renew an unknown, withdrawn, expired, or over-age photo');
      renewed.set(photo.id, renewal.expiresAt);
    }
    if (action.paused === true && (action.addAssets || withdrawals.length || renewals.length)) throw new Error('Pause is a separate operation');
    const previousChannel = previousRecord?.channels.find(row => row.channelID === channelID);
    const catID = previousChannel?.catID;
    if ((catID !== undefined && (typeof catID !== 'string' || !slug.test(catID)))
        || (Object.hasOwn(CAT_WINDOWS, channelID) && catID !== CAT_WINDOWS[channelID].catID)) throw new Error('Missing or invalid cat-window constraint');
    const history = previousChannel?.history ?? old.photos;
    if (catID !== undefined && [...history, ...old.photos].some(photo => photo.catID !== catID)) throw new Error('Different cat in cat-window history or catalog');
    const historyIDs = new Set(), historyHashes = new Set();
    for (const photo of history) {
      if (!slug.test(photo.id) || !/^[a-f0-9]{64}$/.test(photo.sha256) || historyIDs.has(photo.id)) throw new Error('Invalid publication history');
      instant(photo.publishedAt);
      historyIDs.add(photo.id); historyHashes.add(photo.sha256);
    }
    for (const photo of old.photos) {
      const record = history.find(row => row.id === photo.id);
      if (!record || record.sha256 !== photo.sha256 || record.publishedAt !== photo.publishedAt) throw new Error('Previous publication history does not match the assets');
    }
    let photos = action.paused === true ? [] : old.photos
      .filter(photo => !withdrawals.includes(photo.id) && Date.parse(photo.expiresAt) > now)
      .map(photo => ({ ...photo, expiresAt: renewed.get(photo.id) ?? photo.expiresAt }));
    const additions = [];
    if (action.addAssets) {
      const extra = await edition(action.addAssets, channelID, now);
      activeFiles(extra.catalog, now, channelID);
      if (!extra.catalog.enabled || !extra.catalog.photos.length) throw new Error('Additions must contain active photos');
      for (const photo of extra.catalog.photos) {
        if (catID !== undefined && photo.catID !== catID) throw new Error('Different cat in cat-window addition');
        if (historyIDs.has(photo.id) || historyHashes.has(photo.sha256)) throw new Error('Previously published photos cannot be presented as new');
        if (Date.parse(photo.publishedAt) <= Date.parse(old.generatedAt) || Date.parse(photo.expiresAt) <= now) throw new Error('Addition must be newly published and active');
        additions.push(photo);
        historyIDs.add(photo.id); historyHashes.add(photo.sha256);
        source.images.set(photo.imageFilename, extra.images.get(photo.imageFilename));
      }
      photos.push(...additions);
    }
    photos.sort((a, b) => b.publishedAt.localeCompare(a.publishedAt) || a.id.localeCompare(b.id));
    const catalog = { ...old, generatedAt: stamp(now), validUntil: stamp(now + hours * 3600_000),
      enabled: action.paused === undefined ? old.enabled : !action.paused, photos };
    activeFiles(catalog, now, channelID);
    const deadlines = photos.map(photo => Date.parse(photo.expiresAt));
    updates.push({ catalog, images: source.images, record: {
      channelID, ...(catID === undefined ? {} : { catID }), enabled: catalog.enabled, added: additions.map(photo => photo.id),
      withdrawn: action.paused === true ? old.photos.map(photo => photo.id) : withdrawals,
      expired: old.photos.filter(photo => Date.parse(photo.expiresAt) <= now).map(photo => photo.id),
      renewed: renewals, activeCount: photos.length, newestPhotoID: photos[0]?.id ?? null,
      earliestPhotoExpiry: deadlines.length ? stamp(Math.min(...deadlines)) : null,
      history: [...history, ...additions],
    } });
  }
  const destination = path.resolve(output);
  const parent = await localDirectory(path.dirname(destination));
  const target = path.join(parent, path.basename(destination));
  for (const input of [root, ...[...actions.values()].flatMap(action => action.addAssets ? [action.addAssets] : [])]) {
    const relative = path.relative(await realpath(input), target);
    if (!relative || relative === '..' || (!relative.startsWith('..' + path.sep) && !path.isAbsolute(relative))) throw new Error('Output must be outside input directories');
  }
  const photoDeadlines = updates.flatMap(update => update.record.earliestPhotoExpiry ? [Date.parse(update.record.earliestPhotoExpiry)] : []);
  const catalogMaintenance = now + Math.min(24, hours / 2) * 3600_000;
  const record = { schemaVersion: 1, generatedAt: stamp(now), validUntil: stamp(now + hours * 3600_000),
    maintenanceDueAt: stamp(Math.min(catalogMaintenance, ...photoDeadlines.map(deadline => Math.max(now, deadline - 6 * 3600_000)))),
    sourceBundle: root, channels: updates.map(update => update.record) };
  // All validation happens before creating a new output. Never overwrite history.
  await mkdir(target);
  await mkdir(path.join(target, 'editions'));
  const directories = [];
  for (const { catalog, images } of updates) {
    const directory = path.join(target, 'editions', catalog.channelID);
    await mkdir(directory);
    for (const name of new Set(catalog.photos.map(photo => photo.imageFilename))) await writeFile(path.join(directory, name), images.get(name), { flag: 'wx' });
    await writeFile(path.join(directory, 'catalog.json'), JSON.stringify(catalog, null, 2) + '\n', { flag: 'wx' });
    directories.push(directory);
  }
  const bundle = await prepareBundle(directories[0], path.join(target, 'bundle'), undefined, directories.slice(1), now);
  await writeFile(path.join(bundle.directory, 'update-record.json'), JSON.stringify(record, null, 2) + '\n', { flag: 'wx' });
  await writeFile(path.join(target, 'plan.json'), JSON.stringify(plan, null, 2) + '\n', { flag: 'wx' });
  return { bundle: bundle.directory, ...record };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { previous: { type: 'string' }, plan: { type: 'string' }, output: { type: 'string' } } });
    if (!values.previous || !values.plan || !values.output) throw new Error('Usage: node tools/prepare_update.mjs --previous <last-bundle> --plan <local-json> --output <new-directory>');
    const result = await prepareUpdate(values.previous, await jsonFile(values.plan), values.output);
    console.log(JSON.stringify(result, null, 2));
    console.log('Local candidate only. No upload, deployment, or scheduled task was started.');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
