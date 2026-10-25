import test from 'node:test';
import assert from 'node:assert/strict';
import { access, mkdtemp, mkdir, readFile, readdir, writeFile, symlink } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import { activeFiles } from '../src/index.js';
import { validateProgram } from '../src/program.js';
import { prepareBlackCatDays } from '../tools/prepare_black_cat_days.mjs';
import { hash, expectedConfig, service } from '../tools/schedule_bundle.mjs';

const DAY = 86400_000;
const run = promisify(execFile);
const read = name => readFile(name, 'utf8').then(JSON.parse);
const utc = at => new Date(at).toISOString().replace('.000Z', 'Z');
const tool = fileURLToPath(new URL('../tools/prepare_black_cat_days.mjs', import.meta.url));
// A known metadata-free, thumbnail-free 1x1 grayscale JPEG. Density variations
// make distinct valid fixture files without requiring Pillow or source photos.
const JPEG = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP7//2Q==', 'base64');
function jpeg(i) {
  const bytes = Buffer.from(JPEG); bytes.writeUInt16BE(i + 1, 14); return bytes;
}
async function fixture(count = 1) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'neko-black-cat-days-'));
  const input = path.join(root, 'private-source-filenames'), output = path.join(root, 'candidate');
  await mkdir(input);
  const files = [];
  for (let i = count - 1; i >= 0; i--) {
    const filename = `source-${String(i).padStart(3, '0')}.jpg`, bytes = jpeg(i);
    await writeFile(path.join(input, filename), bytes); files.unshift({ filename, bytes, sha256: hash(bytes) });
  }
  return { root, input, output, files, options: { input, output, startDate: '2026-12-01', hourJST: 0,
    credit: 'AI生成・公開確認済み', publicationApproved: true } };
}
const editionFolder = (output, i) => path.join(output, 'assets/__program/editions', `edition-${String(i).padStart(3, '0')}`, 'windows/black-cats');

test('60 reviewed JPEGs create 60 contiguous days with seven-day history and no future images in earlier editions', async () => {
  const f = await fixture(60), result = await prepareBlackCatDays(f.options);
  const index = validateProgram(await read(path.join(f.output, 'assets/__program/index.json')));
  const start = Date.parse('2026-11-30T15:00:00Z'), through = start + 60 * DAY;
  assert.equal(result.dayCount, 60); assert.equal(index.schemaVersion, 2);
  assert.equal(index.startsAt, utc(start)); assert.equal(index.through, utc(through));
  assert.equal(index.editions.length, 60);
  assert.deepEqual(await readdir(path.join(f.output, 'assets')), ['__program']);
  assert.deepEqual((await readdir(path.join(f.output, 'assets/__program'))).sort(), ['editions', 'index.json']);
  for (const [i, edition] of index.editions.entries()) {
    const folder = editionFolder(f.output, i), catalogBytes = await readFile(path.join(folder, 'catalog.json'));
    const catalog = JSON.parse(catalogBytes);
    assert.equal(edition.startsAt, utc(start + i * DAY)); assert.equal(edition.endsAt, utc(start + (i + 1) * DAY));
    assert.deepEqual(edition.catalogs, { 'black-cats': hash(catalogBytes) });
    assert.equal(catalog.generatedAt, edition.startsAt); assert.equal(catalog.validUntil, edition.endsAt);
    assert.equal(activeFiles(catalog, start + i * DAY, 'black-cats').size, Math.min(i + 1, 7));
    const expectedDays = Array.from({ length: Math.min(i + 1, 7) }, (_, n) => i - n);
    assert.deepEqual(catalog.photos.map(photo => photo.sha256), expectedDays.map(n => f.files[n].sha256));
    assert.deepEqual((await readdir(folder)).sort(), ['catalog.json', ...catalog.photos.map(photo => photo.imageFilename)].sort());
    for (const [position, photo] of catalog.photos.entries()) {
      const day = expectedDays[position];
      const localDate = utc(Date.parse(f.options.startDate + 'T00:00:00Z') + day * DAY).slice(0, 10);
      assert.equal(photo.id, 'black-' + localDate.replaceAll('-', ''));
      assert.equal(photo.publishedAt, utc(start + day * DAY));
      assert.equal(photo.expiresAt, utc(Math.min(through, start + (day + 7) * DAY)));
      assert.equal(photo.catID, 'generated-black-cat'); assert.equal(photo.catName, '黒猫');
      assert.equal(photo.credit, f.options.credit); assert.equal(photo.width, 1); assert.equal(photo.height, 1);
      assert.equal(Object.hasOwn(photo, 'caption'), false); assert.equal(Object.hasOwn(photo, 'photographedOn'), false);
      assert.equal(catalogBytes.includes(Buffer.from(f.input)), false);
      assert.equal(catalogBytes.includes(Buffer.from(f.files[day].filename)), false);
      assert.deepEqual(await readFile(path.join(folder, photo.imageFilename)), f.files[day].bytes);
    }
  }
  await assert.rejects(access(path.join(editionFolder(f.output, 0), f.files[1].sha256 + '.jpg')));
  const review = await read(result.review);
  assert.equal(review.dayCount, 60); assert.equal(review.days[0].date, '2026-12-01');
  assert.equal(review.days.at(-1).date, '2027-01-29');
  assert.deepEqual(review.days.map(day => day.filename), f.files.map(file => file.filename));
  await assert.rejects(access(path.join(f.output, 'assets/schedule-review.json')));
  for (const name of ['index.js', 'program.js', 'scheduled.js']) {
    assert.deepEqual(await readFile(path.join(f.output, name)), await readFile(path.join(service, 'src', name)));
  }
  const config = await expectedConfig(); config.main = './program.js';
  assert.deepEqual(await read(path.join(f.output, 'wrangler.jsonc')), config);
});

test('18 JST and leap-day dates use the explicit local calendar with ordinal filename order', async () => {
  const f = await fixture(0);
  for (const [i, filename] of ['10.jpeg', '2.jpg', '01.JPG'].entries()) await writeFile(path.join(f.input, filename), jpeg(i));
  const result = await prepareBlackCatDays({ ...f.options, startDate: '2028-02-28', hourJST: 18 });
  assert.equal(result.startsAt, '2028-02-28T09:00:00Z'); assert.equal(result.through, '2028-03-02T09:00:00Z');
  const review = await read(result.review);
  assert.deepEqual(review.days.map(day => day.filename), ['01.JPG', '10.jpeg', '2.jpg']);
  assert.deepEqual(review.days.map(day => day.date), ['2028-02-28', '2028-02-29', '2028-03-01']);
});

test('missing decisions, invalid dates and hours, private extra fields and invalid credits fail before output', async () => {
  const f = await fixture();
  const variants = [
    { publicationApproved: false }, { publicationApproved: 'true' }, { startDate: '2026-02-30' },
    { startDate: '2026-2-01' }, { startDate: '' }, { hourJST: 9 }, { hourJST: '0' },
    { credit: '' }, { credit: '   ' }, { credit: ' credit' }, { credit: 'a'.repeat(81) },
    { credit: 'owner\nprivate' }, { privateWindowID: 'must-not-be-published' },
    { input: 'relative-input' }, { output: 'relative-output' },
  ];
  for (const changes of variants) await assert.rejects(prepareBlackCatDays({ ...f.options, ...changes }));
  for (const key of Object.keys(f.options)) {
    const missing = { ...f.options }; delete missing[key];
    await assert.rejects(prepareBlackCatDays(missing));
  }
  await assert.rejects(access(f.output));
});

test('empty or more than 60 files, unknown files and duplicate JPEG bytes fail before output', async () => {
  const empty = await fixture(0), excess = await fixture(61), unknown = await fixture(), duplicate = await fixture();
  await writeFile(path.join(unknown.input, 'private-notes.json'), '{"private":true}');
  await writeFile(path.join(duplicate.input, 'renamed.jpg'), duplicate.files[0].bytes);
  for (const [f, reason] of [[empty, /1 to 60/], [excess, /1 to 60/], [unknown, /only reviewed publisher JPEGs/], [duplicate, /Duplicate JPEG/]]) {
    await assert.rejects(prepareBlackCatDays(f.options), reason); await assert.rejects(access(f.output));
  }
});

test('JPEG metadata before or after a scan, bad formats, dimensions and trailing data are rejected before output', async () => {
  const f = await fixture(), filename = path.join(f.input, f.files[0].filename);
  for (const marker of [...Array.from({ length: 15 }, (_, i) => 0xe1 + i), 0xfe]) {
    const segment = Buffer.concat([Buffer.from([255, marker, 0, 10]), Buffer.from('Exif\0GPS', 'ascii')]);
    for (const at of [2, JPEG.length - 2]) {
      await writeFile(filename, Buffer.concat([JPEG.subarray(0, at), segment, JPEG.subarray(at)]));
      await assert.rejects(prepareBlackCatDays(f.options), /metadata segment/);
    }
  }
  const tooWide = Buffer.from(JPEG), sof = JPEG.indexOf(Buffer.from([255, 0xc0]));
  tooWide.writeUInt16BE(2049, sof + 7);
  const thumbnail = Buffer.from(JPEG); thumbnail[18] = 1;
  const badJFIF = Buffer.from(JPEG); badJFIF[6] = 88;
  for (const bytes of [Buffer.from('not a JPEG'), JPEG.subarray(0, 15), Buffer.concat([JPEG, Buffer.from('private')]), tooWide, thumbnail, badJFIF]) {
    await writeFile(filename, bytes); await assert.rejects(prepareBlackCatDays(f.options));
  }
  await assert.rejects(access(f.output));
});

test('network paths, nested outputs, existing outputs, directories and symlink ancestors are rejected', async () => {
  const f = await fixture();
  for (const input of ['\\\\server\\share\\private', '//server/share/private']) {
    await assert.rejects(prepareBlackCatDays({ ...f.options, input }), /local paths/);
  }
  for (const output of ['\\\\server\\share\\candidate', '//server/share/candidate']) {
    await assert.rejects(prepareBlackCatDays({ ...f.options, output }), /local paths/);
  }
  await assert.rejects(prepareBlackCatDays({ ...f.options, output: path.join(f.input, 'candidate') }), /outside/);
  const link = path.join(f.root, 'input-link');
  await symlink(f.input, link, process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(prepareBlackCatDays({ ...f.options, input: link }), /without symlinks/);
  const child = path.join(f.input, 'child'); await mkdir(child);
  await assert.rejects(prepareBlackCatDays({ ...f.options, input: path.join(link, 'child') }), /without symlinks/);
  const outputViaLink = path.join(link, 'child', 'candidate');
  await assert.rejects(prepareBlackCatDays({ ...f.options, output: outputViaLink }), /without symlinks/);
  await assert.rejects(prepareBlackCatDays(f.options), /only reviewed publisher JPEGs/);
  await assert.rejects(access(f.output));
  await mkdir(f.output);
  const sentinel = path.join(f.output, 'keep.txt'); await writeFile(sentinel, 'keep');
  await assert.rejects(prepareBlackCatDays(f.options), /already exists/);
  assert.equal(await readFile(sentinel, 'utf8'), 'keep');
});

test('a symlinked JPEG entry is rejected before output', async () => {
  const f = await fixture();
  // A directory junction also exercises Windows without requiring symlink privilege.
  await symlink(f.root, path.join(f.input, 'linked.jpg'), process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(prepareBlackCatDays(f.options), /Invalid local schedule file/);
  await assert.rejects(access(f.output));
});

test('CLI requires every decision and creates a local candidate only with all explicit arguments', async () => {
  const f = await fixture();
  const args = ['--input', f.input, '--output', f.output, '--start-date', '2026-12-01', '--credit', f.options.credit];
  for (const extra of [[], ['--hour-jst', '0'], ['--hour-jst', '00', '--publication-approved'], ['--hour-jst', '18', '--unknown', 'secret']]) {
    await assert.rejects(run(process.execPath, [tool, ...args, ...extra])); await assert.rejects(access(f.output));
  }
  const { stdout } = await run(process.execPath, [tool, ...args, '--hour-jst', '18', '--publication-approved']);
  assert.match(stdout, /Local candidate only/);
  assert.equal((await read(path.join(f.output, 'schedule-review.json'))).hourJST, 18);
});
