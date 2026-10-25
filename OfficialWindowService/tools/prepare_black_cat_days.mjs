// A local, finite black-cat plan. This tool never uploads, deploys or activates it.
import assert from 'node:assert/strict';
import { lstat, readdir, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { activeFiles } from '../src/index.js';
import { PROGRAM_PATH, validateProgram } from '../src/program.js';
import { validatePublisherJPEG } from './prepare_maintenance.mjs';
import { directory, file, newOutput, hash, stamp, expectedConfig, service } from './schedule_bundle.mjs';

const DAY = 86400_000, HOUR = 3600_000;
const fields = ['input', 'output', 'startDate', 'credit', 'publicationApproved'];
const encoded = value => Buffer.from(JSON.stringify(value, null, 2) + '\n');
function localAbsolute(value) {
  assert(typeof value === 'string' && path.isAbsolute(value)
    && !value.startsWith('\\\\') && !value.startsWith('//'), 'Use absolute local paths, never network paths');
  return path.resolve(value);
}
async function localDirectory(value) {
  const resolved = localAbsolute(value), root = path.parse(resolved).root;
  let cursor = root;
  // Reject junctions and symlinks in ancestors as well as the selected folder.
  for (const part of path.relative(root, resolved).split(path.sep).filter(Boolean)) {
    cursor = path.join(cursor, part);
    const info = await lstat(cursor);
    assert(info.isDirectory() && !info.isSymbolicLink(), 'Use a regular local directory without symlinks');
  }
  const actual = await directory(resolved);
  localAbsolute(actual);
  return actual;
}
function startTime(startDate) {
  assert(typeof startDate === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(startDate), 'Explicit --start-date YYYY-MM-DD is required');
  const midnight = Date.parse(startDate + 'T00:00:00Z');
  assert(Number.isFinite(midnight) && stamp(midnight) === startDate + 'T00:00:00Z', 'Use a real calendar start date');
  return { midnight, start: midnight - 9 * HOUR };
}
function dimensions(bytes) {
  assert(bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216, 'Invalid publisher JPEG');
  let offset = 2;
  while (offset < bytes.length) {
    assert(bytes[offset++] === 255, 'Broken JPEG segment header');
    while (offset < bytes.length && bytes[offset] === 255) offset++;
    assert(offset + 3 <= bytes.length, 'Truncated JPEG header');
    const marker = bytes[offset++], length = bytes.readUInt16BE(offset);
    assert(length >= 2 && offset + length <= bytes.length, 'Broken JPEG segment length');
    if (marker === 0xc0 || marker === 0xc2) {
      assert(length >= 8, 'Truncated JPEG frame');
      const height = bytes.readUInt16BE(offset + 3), width = bytes.readUInt16BE(offset + 5);
      validatePublisherJPEG(bytes, width, height);
      return { width, height };
    }
    assert(marker !== 0xda && marker !== 0xd9, 'JPEG frame is missing');
    offset += length;
  }
  throw new Error('JPEG frame is missing');
}

export async function prepareBlackCatDays(options) {
  assert(options && typeof options === 'object' && !Array.isArray(options)
    && Object.keys(options).length === fields.length && fields.every(name => Object.hasOwn(options, name)),
  'Explicit input, output, startDate, credit and publicationApproved are required');
  const { input, output, startDate, credit, publicationApproved } = options;
  assert(publicationApproved === true, 'Explicit public publication approval is required');
  assert(typeof credit === 'string' && credit.trim().length > 0, 'Explicit nonempty --credit is required');
  const { midnight, start } = startTime(startDate);
  const source = await localDirectory(input);
  localAbsolute(output);
  await localDirectory(path.dirname(output));
  const target = await newOutput(output, [source]);
  const names = (await readdir(source)).sort(); // Ordinal filename order; never locale-dependent.
  assert(names.length >= 1 && names.length <= 60, 'Use 1 to 60 reviewed publisher JPEGs, one image per day');
  const through = start + names.length * DAY;
  assert(/^\d{4}-\d{2}-\d{2}T/.test(stamp(start)) && /^\d{4}-\d{2}-\d{2}T/.test(stamp(through)), 'Schedule must stay within four-digit calendar years');
  const images = [], hashes = new Set();
  for (const [i, filename] of names.entries()) {
    assert(/\.(?:jpg|jpeg)$/i.test(filename) && !/[\u0000-\u001f\u007f-\u009f]/u.test(filename),
      'Input folder may contain only reviewed publisher JPEGs; remove unknown files');
    const bytes = await file(path.join(source, filename), 4 * 1024 * 1024);
    const size = dimensions(bytes), sha256 = hash(bytes);
    assert(!hashes.has(sha256), 'Duplicate JPEG bytes are not permitted on different days');
    hashes.add(sha256);
    const date = stamp(midnight + i * DAY).slice(0, 10), published = start + i * DAY;
    const photo = { id: 'black-' + date.replaceAll('-', ''), catID: 'generated-black-cat', catName: '黒猫', credit,
      publishedAt: stamp(published), expiresAt: stamp(Math.min(through, published + 7 * DAY)),
      imageFilename: sha256 + '.jpg', sha256, ...size };
    images.push({ filename, date, photo, bytes });
  }
  const index = { schemaVersion: 2, startsAt: stamp(start), through: stamp(through), editions: [] }, catalogs = [];
  for (const [i] of images.entries()) {
    const startsAt = stamp(start + i * DAY), endsAt = stamp(start + (i + 1) * DAY);
    const catalog = { schemaVersion: 1, channelID: 'black-cats', enabled: true, generatedAt: startsAt,
      validUntil: endsAt, photos: images.slice(Math.max(0, i - 6), i + 1).reverse().map(image => image.photo) };
    activeFiles(catalog, start + i * DAY, 'black-cats');
    const bytes = encoded(catalog);
    assert(bytes.length <= 256 * 1024, 'Catalog exceeds the Worker reader limit');
    const edition = { id: `edition-${String(i).padStart(3, '0')}`, startsAt, endsAt, catalogs: { 'black-cats': hash(bytes) } };
    index.editions.push(edition); catalogs.push({ catalog, bytes });
  }
  validateProgram(index);
  const indexBytes = encoded(index);
  assert(indexBytes.length <= 256 * 1024, 'Program index exceeds the Worker reader limit');
  const review = { schemaVersion: 1, kind: 'black-cat-days', startDate, hourJST: 0, credit, publicationApproved,
    startsAt: index.startsAt, through: index.through, dayCount: images.length,
    days: images.map((image, i) => ({ date: image.date, filename: image.filename, editionID: index.editions[i].id,
      publishedAt: image.photo.publishedAt, expiresAt: image.photo.expiresAt, sha256: image.photo.sha256 })) };
  const config = await expectedConfig(); config.main = './program.js';
  const sources = new Map();
  for (const name of ['index.js', 'program.js', 'scheduled.js']) sources.set(name, await file(path.join(service, 'src', name)));
  // All inputs, configuration and Worker sources are read before output is created.
  // A write failure leaves a partial candidate for inspection; it is never reused.
  await mkdir(target);
  await mkdir(path.join(target, 'assets/__program/editions'), { recursive: true });
  for (const [i, edition] of index.editions.entries()) {
    const folder = path.join(target, 'assets/__program/editions', edition.id, 'windows/black-cats');
    await mkdir(folder, { recursive: true });
    const { catalog, bytes } = catalogs[i];
    await writeFile(path.join(folder, 'catalog.json'), bytes, { flag: 'wx' });
    for (const photo of catalog.photos) {
      const image = images.find(image => image.photo.sha256 === photo.sha256);
      await writeFile(path.join(folder, photo.imageFilename), image.bytes, { flag: 'wx' });
    }
  }
  await writeFile(path.join(target, 'assets' + PROGRAM_PATH), indexBytes, { flag: 'wx' });
  for (const [name, bytes] of sources) await writeFile(path.join(target, name), bytes, { flag: 'wx' });
  await writeFile(path.join(target, 'wrangler.jsonc'), encoded(config), { flag: 'wx' });
  await writeFile(path.join(target, 'schedule-review.json'), encoded(review), { flag: 'wx' });
  return { directory: target, review: path.join(target, 'schedule-review.json'), dayCount: images.length,
    startsAt: index.startsAt, through: index.through };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { input: { type: 'string' }, output: { type: 'string' },
      'start-date': { type: 'string' }, credit: { type: 'string' },
      'publication-approved': { type: 'boolean' } } });
    assert(values.input && values.output && values['start-date']
      && values.credit && values['publication-approved'],
    'Use --input <reviewed-JPEG-folder> --output <new-local-folder> --start-date YYYY-MM-DD --credit <approved-credit> --publication-approved');
    console.log(JSON.stringify(await prepareBlackCatDays({ input: values.input, output: values.output,
      startDate: values['start-date'], credit: values.credit,
      publicationApproved: values['publication-approved'] }), null, 2));
    console.log('Local candidate only. Review schedule-review.json and the images before owner-approved deployment.');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
