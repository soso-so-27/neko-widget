import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, access } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import worker, { PROGRAM_PATH, validateProgram, validateThemes } from '../src/program.js';
import { prepareProgram } from '../tools/prepare_program.mjs';

const DAY = 86400000, start = Date.parse('2026-10-19T09:00:00Z');
const utc = at => new Date(at).toISOString().replace('.000Z', 'Z');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const jpeg = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP7//2Q==', 'base64');
async function fixture(days = 8) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'neko-program-')), images = path.join(root, 'images');
  await mkdir(images);
  const photos = [];
  for (let i = 0; i < 9; i++) {
    const bytes = Buffer.from(jpeg); bytes[30] += i;
    const digest = hash(bytes), imagePath = path.join(images, digest + '.jpg');
    await writeFile(imagePath, bytes);
    photos.push({ publicationApproved: true, imagePath, photo: { id: 'public-' + i, catID: 'curated-cat-' + i,
      catName: '公開用の猫', credit: '合成テスト', caption: '説明用', publishedAt: utc(start - 6 * DAY), expiresAt: utc(start + 8 * DAY),
      imageFilename: digest + '.jpg', sha256: digest, width: 1, height: 1 } });
  }
  const input = { schemaVersion: 1, startsAt: utc(start), through: utc(start + days * DAY), photos,
    blackCats: ['public-0'], dailyPool: photos.map(v => v.photo.id), dailyHistory: [],
    themes: [
      { name: '箱', weekStart: '2026-10-26', photoIDs: ['public-3'] },
      { name: 'あくび', weekStart: '2026-10-19', photoIDs: ['public-2'] },
      { name: 'おなか', weekStart: '2026-10-12', photoIDs: ['public-1'] },
      { name: 'のび', weekStart: '2026-10-05', photoIDs: [] },
    ] };
  const output = path.join(root, 'candidate');
  return { root, input, output };
}
async function prepared(days) {
  const f = await fixture(days);
  await prepareProgram(f.input, f.output, () => 0);
  const index = JSON.parse(await readFile(path.join(f.output, 'assets' + PROGRAM_PATH)));
  return { ...f, index };
}
const catalogPath = (root, edition, channel) => path.join(root, 'assets/__program/editions', edition,
  channel === 'official-cats' ? '' : 'windows/' + channel, 'catalog.json');
async function request(root, route, hooks = {}) {
  const calls = [];
  const response = await worker.fetch(new Request('https://official.invalid' + route), {
    OFFICIAL_ASSETS: { async fetch(input) {
      const pathname = new URL(input.url).pathname; calls.push(pathname);
      if (hooks.beforeRead) await hooks.beforeRead(pathname);
      try { return new Response(await readFile(path.join(root, 'assets', pathname))); }
      catch { return new Response(null, { status: 404 }); }
    } },
  });
  return { response, calls };
}

test('real Worker serves three isolated channels, bounded weekly names and daily seven-day catalogs', async t => {
  const f = await prepared(), before = JSON.stringify(f.input);
  t.mock.method(Date, 'now', () => start + 6 * DAY);
  const daily = await request(f.output, '/catalog.json'); assert.equal(daily.response.status, 200);
  const catalog = await daily.response.json();
  assert.equal(catalog.schemaVersion, 1); assert.equal(catalog.photos.length, 7);
  assert.equal(new Set(catalog.photos.map(p => p.id)).size, 7);
  assert(catalog.photos.every(p => p.credit === '合成テスト' && !Object.hasOwn(p, 'imagePath') && !Object.hasOwn(p, 'publicationApproved')));
  assert.equal(catalog.photos.at(-1).publishedAt, utc(start + 6 * DAY));
  assert.equal(catalog.validUntil, utc(start + 8 * DAY));
  const black = await (await request(f.output, '/windows/black-cats/catalog.json')).response.json();
  assert.deepEqual(black.photos.map(p => p.id), ['public-0']);
  assert(black.photos.every(p => p.caption === undefined && p.credit === '合成テスト'));
  const meta = await (await request(f.output, '/windows/weekly-theme/themes.json')).response.json();
  assert.deepEqual(meta.themes.map(v => v.name), ['あくび', 'おなか', 'のび']);
  const old = await request(f.output, '/windows/weekly-theme-20261012/catalog.json');
  assert.equal(old.response.status, 200); assert.equal((await old.response.json()).photos[0].id, 'public-1');
  assert.equal(JSON.stringify(f.input), before);
  assert((await readFile(path.join(f.output, 'wrangler.jsonc'), 'utf8')).includes('"main": "./program.js"'));
  await assert.rejects(access(path.join(f.output, 'assets/input.json')));
});

test('18:00 JST switches one daily image and Monday 00:00 JST switches the theme', async t => {
  const f = await prepared(); let now = start + DAY - 1;
  t.mock.method(Date, 'now', () => now);
  const previous = await (await request(f.output, '/catalog.json')).response.json();
  now += 1;
  const next = await (await request(f.output, '/catalog.json')).response.json();
  assert.equal(previous.photos.length, 1); assert.equal(next.photos.length, 2);
  assert.notEqual(previous.photos[0].sha256, next.photos.at(-1).sha256);
  now = Date.parse('2026-10-25T14:59:59Z');
  assert.equal((await (await request(f.output, '/windows/weekly-theme/themes.json')).response.json()).themes[0].name, 'あくび');
  now += 1000;
  const monday = await (await request(f.output, '/windows/weekly-theme/themes.json')).response.json();
  assert.deepEqual(monday.themes.map(v => v.name), ['箱', 'あくび', 'おなか']);
  assert.equal(monday.themes[1].channelID, 'weekly-theme-20261019');
});

test('unpublished files, private paths, aliases, unknown archive weeks and ended programmes stay closed', async t => {
  const f = await prepared(); let now = start - 1;
  t.mock.method(Date, 'now', () => now);
  assert.equal((await request(f.output, '/catalog.json')).response.status, 503);
  now = start;
  for (const url of ['/__program/index.json', '/windows/unknown/catalog.json', '/windows/official-cats/catalog.json',
    '/windows/weekly-theme-20200101/catalog.json', '/windows/black-cats/themes.json', '/catalog.json?token=secret', '/connection.json']) {
    assert.equal((await request(f.output, url)).response.status, 404);
  }
  assert.equal((await request(f.output, '/' + f.input.photos[1].photo.imageFilename)).response.status, 404);
  now = start + 8 * DAY;
  assert.equal((await request(f.output, '/catalog.json')).response.status, 503);
});

test('catalog tampering and image I/O that crosses a cutover fail closed', async t => {
  const f = await prepared(2); let now = start;
  t.mock.method(Date, 'now', () => now);
  const item = (await (await request(f.output, '/catalog.json')).response.json()).photos[0];
  const crossed = await request(f.output, '/' + item.imageFilename, { beforeRead(p) { if (p.endsWith('.jpg')) now = start + DAY; } });
  assert.equal(crossed.response.status, 503);
  now = start;
  const p = catalogPath(f.output, 'edition-000', 'official-cats');
  const catalog = JSON.parse(await readFile(p)); catalog.photos[0].credit = '改変';
  await writeFile(p, JSON.stringify(catalog));
  assert.equal((await request(f.output, '/catalog.json')).response.status, 503);
});

test('carry reviewed daily history without shifting dates or extending expiry', async t => {
  const f = await fixture(1);
  f.input.dailyHistory = [{ photoID: 'public-1', publishedAt: utc(start - DAY) }];
  await prepareProgram(f.input, f.output, () => 0);
  t.mock.method(Date, 'now', () => start);
  const catalog = await (await request(f.output, '/catalog.json')).response.json();
  assert.equal(catalog.photos.length, 2);
  assert.equal(catalog.photos[0].publishedAt, utc(start - DAY));
  assert.equal(catalog.photos[0].expiresAt, utc(start + 6 * DAY));
});

test('an immediate replacement can withdraw a photo without inventing a new daily publication', async t => {
  const f = await fixture(1);
  f.input.startsAt = utc(start + 1800000);
  f.input.blackCats = [];
  await prepareProgram(f.input, f.output, () => 0);
  t.mock.method(Date, 'now', () => start + 1800000);
  const catalog = await (await request(f.output, '/catalog.json')).response.json();
  assert.equal(catalog.generatedAt, f.input.startsAt);
  assert.deepEqual(catalog.photos, []);
  assert.equal((await request(f.output, '/' + f.input.photos[0].photo.imageFilename)).response.status, 404);
});

for (const mode of ['unapproved', 'private-field', 'missing-credit', 'wrong-hash', 'bad-theme', 'expired-pool', 'wrong-time', 'history-redated']) {
  test(`reject ${mode} before writing a candidate`, async () => {
    const f = await fixture(1);
    if (mode === 'unapproved') f.input.photos[0].publicationApproved = false;
    if (mode === 'private-field') f.input.photos[0].photo.localIdentifier = 'private-photo-id';
    if (mode === 'missing-credit') f.input.photos[0].photo.credit = '';
    if (mode === 'wrong-hash') f.input.photos[0].photo.sha256 = '0'.repeat(64);
    if (mode === 'bad-theme') f.input.themes[1].name = 'bad\nname';
    if (mode === 'expired-pool') f.input.photos.forEach(v => { v.photo.expiresAt = utc(start - 1); });
    if (mode === 'wrong-time') f.input.startsAt = utc(start + 1);
    if (mode === 'history-redated') f.input.dailyHistory = [{ photoID: 'public-1', publishedAt: utc(start - DAY + 1) }];
    await assert.rejects(prepareProgram(f.input, f.output, () => 0));
    await assert.rejects(access(f.output));
  });
}

test('weekly metadata rejects remote paths, stale weeks, unknown fields and long leases', async () => {
  const f = await prepared(1), original = f.index.editions[0].themes;
  for (const change of [v => { v.themes[0].channelID = 'https://private.invalid'; }, v => { v.themes[1].weekStart = '2026-10-11'; },
    v => { v.secret = 'not-public'; }, v => { v.validUntil = utc(start + 3 * DAY); }]) {
    const value = structuredClone(original); change(value); assert.throws(() => validateThemes(value, start));
  }
  const invalid = structuredClone(f.index); invalid.editions[0].catalogs.private = '0'.repeat(64);
  assert.throws(() => validateProgram(invalid));
});
