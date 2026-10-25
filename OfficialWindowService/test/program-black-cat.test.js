import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import worker, { validateProgram } from '../src/program.js';
import { prepareBlackCatDays } from '../tools/prepare_black_cat_days.mjs';
import { hash } from '../tools/schedule_bundle.mjs';

const DAY = 86400000;
const jpeg = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP7//2Q==', 'base64');
async function fixture(days) {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'neko-black-worker-')));
  const input = path.join(root, 'input'), output = path.join(root, 'candidate');
  await mkdir(input);
  const hashes = [];
  for (let i = 0; i < days; i++) {
    const data = Buffer.from(jpeg); data.writeUInt16BE(i + 1, 14); hashes.push(hash(data));
    await writeFile(path.join(input, `${String(i).padStart(3, '0')}.jpg`), data);
  }
  await prepareBlackCatDays({ input, output, startDate: '2026-12-01',
    credit: 'AI生成・検査用', publicationApproved: true });
  const index = JSON.parse(await readFile(path.join(output, 'assets/__program/index.json')));
  return { output, index, hashes, start: Date.parse(index.startsAt) };
}
async function request(f, route, beforeRead = () => {}, method = 'GET') {
  const calls = [];
  const response = await worker.fetch(new Request('https://official.invalid' + route, { method }), {
    OFFICIAL_ASSETS: { async fetch(input) {
      const pathname = new URL(input.url).pathname; calls.push(pathname); await beforeRead(pathname);
      try { return new Response(await readFile(path.join(f.output, 'assets', pathname))); }
      catch { return new Response(null, { status: 404 }); }
    } },
  });
  return { response, calls };
}

test('60-day real Worker switches one black cat daily and closes future, hidden and ended URLs', async t => {
  const f = await fixture(60); let now = f.start - 1;
  t.mock.method(Date, 'now', () => now);
  assert.equal((await request(f, '/windows/black-cats/catalog.json')).response.status, 503);
  for (let i = 0; i < 60; i++) {
    now = f.start + i * DAY;
    const { response } = await request(f, '/windows/black-cats/catalog.json');
    assert.equal(response.status, 200);
    const catalog = await response.json();
    assert.equal(catalog.photos[0].sha256, f.hashes[i]);
    assert.equal(Date.parse(catalog.photos[0].publishedAt), now);
    assert.equal(Date.parse(catalog.validUntil), now + DAY);
    assert.equal(catalog.photos.length, Math.min(7, i + 1));
    const current = await request(f, `/windows/black-cats/${f.hashes[i]}.jpg`);
    assert.equal(current.response.status, 200);
    assert.equal(hash(Buffer.from(await current.response.arrayBuffer())), f.hashes[i]);
    if (i < 59) assert.equal((await request(f, `/windows/black-cats/${f.hashes[i + 1]}.jpg`)).response.status, 404);
    if (i >= 7) {
      const expired = await request(f, `/windows/black-cats/${f.hashes[i - 7]}.jpg`);
      assert.equal(expired.response.status, 404, 'The eighth-day image must no longer be served');
      assert.equal(expired.calls.some(pathname => pathname.endsWith('.jpg')), false, 'Expired bytes must not be read');
    }
    now += DAY - 1;
    assert.equal((await (await request(f, '/windows/black-cats/catalog.json')).response.json()).photos[0].sha256, f.hashes[i]);
  }
  for (const route of ['/catalog.json', '/windows/weekly-theme/catalog.json', '/windows/weekly-theme/themes.json',
    '/windows/nap-cats/catalog.json', '/__program/index.json', '/__program/editions/edition-059/windows/black-cats/catalog.json',
    '/schedule-review.json', '/windows/black-cats/catalog.json?internal=1',
    '/windows/black-cats/%2e%2e%2f__program%2findex.json',
    '/windows/black-cats/%2F__program%2Feditions%2Fedition-059%2Fwindows%2Fblack-cats%2Fcatalog.json',
    '/assets/__program/index.json']) {
    assert.equal((await request(f, route)).response.status, 404, route);
  }
  now = f.start + 60 * DAY;
  assert.equal((await request(f, '/windows/black-cats/catalog.json')).response.status, 503);
  assert.equal((await request(f, `/windows/black-cats/${f.hashes[59]}.jpg`)).response.status, 503);
});

test('JST midnight switches editions and an in-flight cutover fails closed', async t => {
  const f = await fixture(2); let now = f.start + DAY - 1;
  t.mock.method(Date, 'now', () => now);
  assert.equal((await (await request(f, '/windows/black-cats/catalog.json')).response.json()).photos[0].sha256, f.hashes[0]);
  const future = await request(f, `/windows/black-cats/${f.hashes[1]}.jpg`, undefined, 'HEAD');
  assert.equal(future.response.status, 404);
  assert.equal(await future.response.text(), '');
  assert.equal(future.calls.some(pathname => pathname.endsWith('.jpg')), false);
  const before = await (await request(f, '/windows/black-cats/catalog.json')).response.json();
  const crossed = await request(f, `/windows/black-cats/${f.hashes[0]}.jpg`, pathname => {
    if (pathname.endsWith('.jpg')) now++;
  });
  assert.equal(crossed.response.status, 503);
  assert.equal(Date.parse(before.validUntil), now, 'The old catalog expires at exactly JST midnight');
  const head = await request(f, `/windows/black-cats/${f.hashes[1]}.jpg`, undefined, 'HEAD');
  assert.equal(head.response.status, 200);
  assert.equal(await head.response.text(), '');
  assert.equal((await (await request(f, '/windows/black-cats/catalog.json')).response.json()).photos[0].sha256, f.hashes[1]);
});

test('single-channel plans reject extra feeds, missing days, longer horizons and wrong switch hours', async () => {
  const f = await fixture(1);
  for (const change of [
    index => { index.editions[0].catalogs['official-cats'] = '0'.repeat(64); },
    index => { index.editions[0].themes = {}; },
    index => { index.through = '2027-03-01T15:00:00Z'; },
    index => { index.editions[0].endsAt = index.editions[0].startsAt; },
    index => { index.startsAt = '2026-11-30T16:00:00Z'; },
    index => {
      index.startsAt = index.editions[0].startsAt = '2026-12-01T09:00:00Z';
      index.through = index.editions[0].endsAt = '2026-12-02T09:00:00Z';
    },
  ]) {
    const index = structuredClone(f.index); change(index);
    assert.throws(() => validateProgram(index));
  }
});
