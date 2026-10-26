// Prepares local, finite public assets only. Never deploys or opens a private source.
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, writeFile } from 'node:fs/promises';
import { randomInt } from 'node:crypto';
import { parseArgs } from 'node:util';
import { activeFiles } from '../src/index.js';
import { PROGRAM_PATH, validateProgram, weekStart } from '../src/program.js';
import { instant } from '../src/scheduled.js';
import { file, json, newOutput, expectedConfig, hash, stamp, route, service } from './schedule_bundle.mjs';
import { validatePublisherJPEG } from './prepare_maintenance.mjs';

const DAY = 86400000;
const exact = (v, names) => v && typeof v === 'object' && !Array.isArray(v)
  && Object.keys(v).length === names.length && names.every(k => Object.hasOwn(v, k));
export async function prepareProgram(input, output, choose = randomInt) {
  assert(exact(input, ['schemaVersion', 'startsAt', 'through', 'photos', 'blackCats', 'dailyPool', 'dailyHistory', 'themes']) && input.schemaVersion === 1, 'Invalid programme input');
  const start = instant(input.startsAt), end = instant(input.through);
  // Candidate replacement can start immediately for withdrawal. New daily
  // selections still happen only at 18:00 JST, never at preparation time.
  assert(start % 1000 === 0 && end > start && end - start <= 14 * DAY, 'Whole-second start; finite horizon at most 14 days');
  assert(Array.isArray(input.photos) && input.photos.length > 0 && input.photos.length <= 180, 'Reviewed public photos required');
  const source = new Map(), imageRoots = new Set();
  for (const row of input.photos) {
    assert(exact(row, ['photo', 'imagePath', 'publicationApproved']) && row.publicationApproved === true, 'Explicit public publication approval required');
    const photo = row.photo;
    // Use the existing strict public schema. Private fields cannot enter an asset.
    const at = instant(photo.publishedAt);
    activeFiles({ schemaVersion: 1, channelID: 'black-cats', enabled: true, generatedAt: stamp(at), validUntil: stamp(at + DAY), photos: [photo] }, at, 'black-cats');
    assert(!source.has(photo.id) && typeof row.imagePath === 'string' && path.isAbsolute(row.imagePath)
      && !row.imagePath.startsWith('\\\\') && !row.imagePath.startsWith('//'), 'Unique photos and absolute local image paths required');
    const bytes = await file(row.imagePath, 4 * 1024 * 1024);
    assert(hash(bytes) === photo.sha256, 'Public image checksum differs');
    validatePublisherJPEG(bytes, photo.width, photo.height);
    source.set(photo.id, { photo, bytes }); imageRoots.add(path.dirname(row.imagePath));
  }
  const ids = list => Array.isArray(list) && list.length <= 60 && new Set(list).size === list.length && list.every(id => source.has(id));
  assert(ids(input.blackCats) && ids(input.dailyPool) && input.dailyPool.length > 0, 'Operator-selected black cats and daily pool required');
  assert(Array.isArray(input.themes) && input.themes.length >= 1 && input.themes.length <= 5, 'At most five reviewed weeks required');
  const weeks = new Map();
  for (const theme of input.themes) {
    assert(exact(theme, ['name', 'weekStart', 'photoIDs']) && typeof theme.weekStart === 'string'
      && weekStart(instant(theme.weekStart + 'T00:00:00Z')) === theme.weekStart && !weeks.has(theme.weekStart) && ids(theme.photoIDs), 'Unique Monday themes required');
    weeks.set(theme.weekStart, theme);
  }
  const photoAt = (id, at) => {
    const p = source.get(id).photo;
    return instant(p.publishedAt) <= at && at < instant(p.expiresAt);
  };
  const index = { schemaVersion: 1, startsAt: stamp(start), through: stamp(end), editions: [] };
  const editions = [], daily = [], recentIDs = [];
  const dailyPhoto = (id, at) => {
    const original = source.get(id).photo;
    const p = { ...original, id: 'daily-' + stamp(at).slice(0, 10).replaceAll('-', '') + '-' + original.id,
      publishedAt: stamp(at), expiresAt: stamp(Math.min(instant(original.expiresAt), at + 7 * DAY)) };
    assert(p.id.length <= 64, 'Daily source IDs must leave room for the publication day');
    return p;
  };
  assert(Array.isArray(input.dailyHistory) && input.dailyHistory.length <= 7, 'At most seven previously published days');
  let last = start - 8 * DAY;
  for (const entry of input.dailyHistory) {
    assert(exact(entry, ['photoID', 'publishedAt']) && source.has(entry.photoID), 'Reviewed daily history required');
    const at = instant(entry.publishedAt);
    assert(at > last && at < start && at >= start - 7 * DAY && (at - 9 * 3600000) % DAY === 0 && photoAt(entry.photoID, at), 'Keep original daily dates and approval periods');
    daily.push(dailyPhoto(entry.photoID, at)); recentIDs.push(entry.photoID); last = at;
  }
  for (let at = start; at < end;) {
    if ((at - 9 * 3600000) % DAY === 0) {
      const eligible = input.dailyPool.filter(id => photoAt(id, at) && instant(source.get(id).photo.expiresAt) >= Math.min(end, at + DAY));
      const unused = eligible.filter(id => !recentIDs.slice(-7).includes(id));
      const pool = unused.length ? unused : eligible;
      assert(pool.length > 0, 'No approved daily photo before the planned horizon');
      const n = choose(pool.length); assert(Number.isInteger(n) && n >= 0 && n < pool.length, 'Invalid daily selection');
      const id = pool[n]; daily.push(dailyPhoto(id, at)); recentIDs.push(id);
    }
    const monday = weekStart(at), current = weeks.get(monday);
    assert(current, 'Each planned week needs an operator-selected theme');
    const midnight = instant(monday + 'T00:00:00Z') - 9 * 3600000;
    const nextDaily = (Math.floor((at - 9 * 3600000) / DAY) + 1) * DAY + 9 * 3600000;
    const until = Math.min(end, nextDaily, midnight + 7 * DAY);
    const validUntil = stamp(Math.min(end, at + 2 * DAY));
    const themes = [];
    for (let i = 0; i < 3; i++) {
      const date = stamp(instant(monday + 'T00:00:00Z') - i * 7 * DAY).slice(0, 10), row = weeks.get(date);
      if (!row) break; // No fabricated history for a newly launched programme.
      themes.push({ name: row.name, weekStart: date, channelID: i === 0 ? 'weekly-theme' : 'weekly-theme-' + date.replaceAll('-', '') });
    }
    const metadata = { schemaVersion: 1, generatedAt: stamp(at), validUntil, themes };
    const photos = new Map([['official-cats', daily.filter(p => instant(p.publishedAt) > at - 7 * DAY && at < instant(p.expiresAt))],
      ['black-cats', input.blackCats.filter(id => photoAt(id, at)).map(id => {
        const { caption, ...photo } = source.get(id).photo; return photo;
      })],
      ...themes.map(t => [t.channelID, weeks.get(t.weekStart).photoIDs.filter(id => photoAt(id, at)).map(id => source.get(id).photo)])]);
    const catalogs = new Map();
    for (const [channelID, items] of photos) {
      const catalog = { schemaVersion: 1, channelID, enabled: true, generatedAt: stamp(at), validUntil, photos: items };
      activeFiles(catalog, at, channelID);
      const bytes = Buffer.from(JSON.stringify(catalog) + '\n'); catalogs.set(channelID, { catalog, bytes });
    }
    const edition = { id: `edition-${String(index.editions.length).padStart(3, '0')}`, startsAt: stamp(at), endsAt: stamp(until),
      catalogs: Object.fromEntries([...catalogs].map(([id, v]) => [id, hash(v.bytes)])), themes: metadata };
    index.editions.push(edition); editions.push(catalogs); at = until;
  }
  validateProgram(index);
  const encoded = JSON.stringify(index) + '\n'; assert(Buffer.byteLength(encoded) <= 256 * 1024, 'Programme index too large');
  // All semantics and source bytes are checked before creating the output.
  const target = await newOutput(output, [...imageRoots]);
  await mkdir(target); await mkdir(path.join(target, 'assets/__program/editions'), { recursive: true });
  const byHash = new Map([...source.values()].map(v => [v.photo.sha256, v.bytes]));
  for (const [i, edition] of index.editions.entries()) {
    for (const [channel, { catalog, bytes }] of editions[i]) {
      const directory = path.join(target, 'assets/__program/editions', edition.id, route(channel));
      await mkdir(directory, { recursive: true }); await writeFile(path.join(directory, 'catalog.json'), bytes, { flag: 'wx' });
      for (const p of new Map(catalog.photos.map(p => [p.sha256, p])).values()) await writeFile(path.join(directory, p.imageFilename), byHash.get(p.sha256), { flag: 'wx' });
    }
  }
  await writeFile(path.join(target, 'assets' + PROGRAM_PATH), encoded, { flag: 'wx' });
  for (const name of ['index.js', 'program.js', 'scheduled.js', 'black-cat-loop.js']) await writeFile(path.join(target, name), await file(path.join(service, 'src', name)), { flag: 'wx' });
  const config = await expectedConfig(); config.main = './program.js';
  await writeFile(path.join(target, 'wrangler.jsonc'), JSON.stringify(config, null, 2) + '\n', { flag: 'wx' });
  return { directory: target, editions: index.editions.length, startsAt: index.startsAt, through: index.through };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { input: { type: 'string' }, output: { type: 'string' } } });
    assert(values.input && values.output, 'Use --input <approved-public-manifest> --output <new-local-directory>');
    console.log(JSON.stringify(await prepareProgram(await json(values.input), values.output)));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
