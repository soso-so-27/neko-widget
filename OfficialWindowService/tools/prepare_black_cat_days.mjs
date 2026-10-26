// A local, finite black-cat plan. This tool never uploads, deploys or activates it.
import assert from 'node:assert/strict';
import { lstat, readdir, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { activeFiles } from '../src/index.js';
import { PROGRAM_PATH, validateProgram } from '../src/program.js';
import { BLACK_CAT_CREDIT, LOOP_IMAGES_PATH, validateBlackCatLoop, loopPosition, blackCatDay } from '../src/black-cat-loop.js';
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
  for (const name of ['index.js', 'program.js', 'scheduled.js', 'black-cat-loop.js']) sources.set(name, await file(path.join(service, 'src', name)));
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

// The only operator-authored schedule is config: start date and ordered input
// filenames together. Derived cycle anchors are never operator counters.
export async function prepareBlackCatLoop(options, now = Date.now()) {
  const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
  assert(exact(options, ['input', 'output', 'config', 'publicationApproved']) && options.publicationApproved === true,
    'Explicit input, output, loop config and publication approval are required');
  const { input, output, config } = options;
  const creates = config?.action === 'create';
  assert(exact(config, ['schemaVersion', 'action', 'startDate', 'credit', 'order', ...(creates ? [] : ['previousBundle'])])
    && config.schemaVersion === 1 && ['create', 'append', 'reset'].includes(config.action)
    && config.credit === BLACK_CAT_CREDIT, 'Invalid loop config or AI credit');
  assert(Array.isArray(config.order) && config.order.length >= 1 && config.order.length <= 60
    && new Set(config.order).size === config.order.length && config.order.every(name => typeof name === 'string'
      && name === path.basename(name) && !/[\\/\u0000-\u001f\u007f-\u009f]/u.test(name) && /\.(jpg|jpeg)$/i.test(name)),
  'Order must explicitly name 1 to 60 unique JPEG files');
  const { start } = startTime(config.startDate);
  assert(Number.isFinite(now), 'A valid preparation time is required');
  if (!creates) assert(start > now, 'Append/reset must be prepared and deployed before their future JST midnight');
  const source = await localDirectory(input);
  localAbsolute(output); await localDirectory(path.dirname(output));
  const previousRoot = creates ? null : await localDirectory(config.previousBundle);
  const target = await newOutput(output, [source, ...(previousRoot ? [previousRoot] : [])]);
  assert.deepEqual((await readdir(source)).sort(), [...config.order].sort(), 'Input folder must match config order exactly');
  const pool = new Map(), images = [], order = [];
  let epochs = [];
  const deployment = await expectedConfig(); deployment.main = './program.js';
  // Keep this candidate on the existing staging/preview service; the tool
  // neither changes account/bindings nor chooses a production destination.
  assert(deployment.name === 'neko-widget-official-cats-preview'
    && deployment.assets?.run_worker_first === true && deployment.preview_urls === false,
  'The reviewed staging Worker boundary must remain enabled');
  if (previousRoot) {
    const previousConfig = JSON.parse((await file(path.join(previousRoot, 'wrangler.jsonc'))).toString('utf8'));
    assert.deepEqual(previousConfig, deployment, 'Previous bundle uses another deployment configuration');
    const previous = validateBlackCatLoop(JSON.parse((await file(path.join(previousRoot, 'assets' + PROGRAM_PATH), 256 * 1024)).toString('utf8')));
    epochs = structuredClone(previous.epochs);
    assert(start > Date.parse(epochs.at(-1).startsAt), 'New action must follow every existing scheduled action');
    const folder = await localDirectory(path.join(previousRoot, 'assets' + LOOP_IMAGES_PATH));
    assert.deepEqual((await readdir(folder)).sort(), previous.images.map(image => image.sha256 + '.jpg').sort(),
      'Previous pool contains unknown or missing images');
    for (const image of previous.images) {
      const bytes = await file(path.join(folder, image.sha256 + '.jpg'), 4 * 1024 * 1024);
      assert(hash(bytes) === image.sha256, 'Previous image checksum differs');
      validatePublisherJPEG(bytes, image.width, image.height);
      images.push(image); pool.set(image.sha256, bytes);
    }
  }
  const reviewed = [];
  for (const name of config.order) {
    const bytes = await file(path.join(source, name), 4 * 1024 * 1024);
    const size = dimensions(bytes), digest = hash(bytes);
    assert(!order.includes(digest), 'Duplicate JPEG bytes are not permitted within a loop');
    order.push(digest); reviewed.push({ filename: name, sha256: digest, ...size });
    if (!pool.has(digest)) { images.push({ sha256: digest, ...size }); pool.set(digest, bytes); }
  }
  let cycle = start;
  if (config.action === 'append') {
    const previous = epochs.at(-1);
    assert(order.length > previous.order.length && previous.order.every((digest, i) => order[i] === digest),
      'Append must preserve all prior images and their order, and add only at the end');
    cycle = start - (loopPosition(previous, start - DAY) + 1) * DAY;
  }
  epochs.push({ action: config.action, startsAt: stamp(start), cycleStartsAt: stamp(cycle), order });
  const index = validateBlackCatLoop({ schemaVersion: 3, credit: BLACK_CAT_CREDIT, images, epochs });
  const indexBytes = encoded(index);
  assert(indexBytes.length <= 256 * 1024, 'Loop config exceeds the Worker reader limit');
  const review = { schemaVersion: 1, kind: 'black-cat-loop', action: config.action,
    startDate: config.startDate, credit: BLACK_CAT_CREDIT, hourJST: 0, publicationApproved: true,
    imageCount: order.length, order: reviewed,
    nextDays: Array.from({ length: order.length * 2 }, (_, i) => {
      const photo = blackCatDay(index, start + i * DAY).catalog.photos[0];
      return { date: stamp(start + i * DAY + 9 * HOUR).slice(0, 10), sha256: photo.sha256,
        filename: reviewed.find(row => row.sha256 === photo.sha256).filename };
    }) };
  const sources = new Map();
  for (const name of ['index.js', 'program.js', 'scheduled.js', 'black-cat-loop.js']) {
    sources.set(name, await file(path.join(service, 'src', name)));
  }
  // Validate everything before creating output. Unknown/failed output is not
  // overwritten, and original source names stay outside all served assets.
  await mkdir(target);
  const imageFolder = path.join(target, 'assets' + LOOP_IMAGES_PATH);
  await mkdir(imageFolder, { recursive: true });
  for (const [digest, bytes] of pool) await writeFile(path.join(imageFolder, digest + '.jpg'), bytes, { flag: 'wx' });
  await writeFile(path.join(target, 'assets' + PROGRAM_PATH), indexBytes, { flag: 'wx' });
  for (const [name, bytes] of sources) await writeFile(path.join(target, name), bytes, { flag: 'wx' });
  await writeFile(path.join(target, 'wrangler.jsonc'), encoded(deployment), { flag: 'wx' });
  await writeFile(path.join(target, 'loop-config.json'), encoded(config), { flag: 'wx' });
  await writeFile(path.join(target, 'schedule-review.json'), encoded(review), { flag: 'wx' });
  return { directory: target, review: path.join(target, 'schedule-review.json'), imageCount: order.length,
    action: config.action, startsAt: stamp(start), mode: 'loop' };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { input: { type: 'string' }, output: { type: 'string' },
      'start-date': { type: 'string' }, credit: { type: 'string' },
      'publication-approved': { type: 'boolean' }, 'loop-config': { type: 'string' } } });
    if (values['loop-config']) {
      assert(values.input && values.output && values['publication-approved'] && !values['start-date'] && !values.credit,
        'Loop start date, credit and order must come from --loop-config only');
      const configPath = localAbsolute(values['loop-config']); await localDirectory(path.dirname(configPath));
      const config = JSON.parse((await file(configPath)).toString('utf8'));
      console.log(JSON.stringify(await prepareBlackCatLoop({ input: values.input, output: values.output,
        config, publicationApproved: values['publication-approved'] }), null, 2));
    } else {
    assert(values.input && values.output && values['start-date']
      && values.credit && values['publication-approved'],
    'Use --input <reviewed-JPEG-folder> --output <new-local-folder> --start-date YYYY-MM-DD --credit <approved-credit> --publication-approved');
    console.log(JSON.stringify(await prepareBlackCatDays({ input: values.input, output: values.output,
      startDate: values['start-date'], credit: values.credit,
      publicationApproved: values['publication-approved'] }), null, 2));
    }
    console.log('Local candidate only. Review schedule-review.json and the images before owner-approved deployment.');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
