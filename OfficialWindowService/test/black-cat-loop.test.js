import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, realpath, mkdir, writeFile, readFile, access, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { pathToFileURL } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import worker, { validateProgram } from '../src/program.js';
import { BLACK_CAT_CREDIT, blackCatDay, validateBlackCatLoop } from '../src/black-cat-loop.js';
import { prepareBlackCatLoop } from '../tools/prepare_black_cat_days.mjs';
import { activeFiles } from '../src/index.js';
import { hash } from '../tools/schedule_bundle.mjs';

const DAY = 86400000, START = Date.parse('2026-11-30T15:00:00Z');
const json = async file => JSON.parse(await readFile(file, 'utf8'));
const jpeg = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP7//2Q==', 'base64');
const run = promisify(execFile);
async function fixture(t, count = 10) {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'neko-loop-')));
  t.after(() => rm(root, { recursive: true, force: true }));
  const input = path.join(root, 'input'); await mkdir(input);
  const order = [], hashes = [];
  for (let i = 0; i < count; i++) {
    const filename = `${String(i + 1).padStart(3, '0')}.jpg`, bytes = Buffer.from(jpeg);
    bytes.writeUInt16BE(i + 1, 14); await writeFile(path.join(input, filename), bytes);
    order.push(filename); hashes.push(hash(bytes));
  }
  const config = { schemaVersion: 1, action: 'create', startDate: '2026-12-01', credit: BLACK_CAT_CREDIT, order };
  const output = path.join(root, 'first');
  await prepareBlackCatLoop({ input, output, config, publicationApproved: true }, START - DAY);
  return { root, input, output, config, hashes, index: await json(path.join(output, 'assets/__program/index.json')) };
}
async function request(f, route, { method = 'GET', beforeRead = () => {}, corruptImage = false } = {}) {
  const calls = [];
  const response = await worker.fetch(new Request('https://official.invalid' + route, { method }), {
    OFFICIAL_ASSETS: { async fetch(input) {
      const pathname = new URL(input.url).pathname; calls.push(pathname); beforeRead(pathname);
      try {
        const bytes = await readFile(path.join(f.output, 'assets', pathname));
        return new Response(corruptImage && pathname.endsWith('.jpg') ? Buffer.from('wrong image') : bytes);
      } catch { return new Response(null, { status: 404 }); }
    } },
  });
  return { response, calls };
}
const jpegRoute = digest => `/windows/black-cats/${digest}.jpg`;

test('ten images loop for years with a new one-day catalog and exact AI credit', async t => {
  const f = await fixture(t); let now = START - 1;
  t.mock.method(Date, 'now', () => now);
  assert.equal((await request(f, '/windows/black-cats/catalog.json')).response.status, 503);
  for (const day of [0, 1, 9, 10, 11, 19, 20, 59, 60, 365, 3650]) {
    now = START + day * DAY;
    const { response } = await request(f, '/windows/black-cats/catalog.json');
    assert.equal(response.status, 200);
    const catalog = await response.json(), photo = catalog.photos[0];
    assert.equal(catalog.photos.length, 1); assert.equal(photo.sha256, f.hashes[day % 10]);
    assert.equal(photo.credit, BLACK_CAT_CREDIT); assert.equal(Date.parse(catalog.generatedAt), now);
    assert.equal(Date.parse(photo.publishedAt), now); assert.equal(Date.parse(photo.expiresAt), now + DAY);
    assert.equal(Date.parse(catalog.validUntil), now + DAY);
    assert.deepEqual([...activeFiles(catalog, now, 'black-cats')], [photo.imageFilename]);
    assert.throws(() => activeFiles(catalog, now + DAY, 'black-cats'));
    const image = await request(f, jpegRoute(photo.sha256));
    assert.equal(image.response.status, 200); assert.equal(hash(Buffer.from(await image.response.arrayBuffer())), photo.sha256);
  }
  assert.notEqual(blackCatDay(f.index, START).catalog.photos[0].id, blackCatDay(f.index, START + 10 * DAY).catalog.photos[0].id);
  // The prepared bundle must include every module its entry point imports.
  const prepared = await import(pathToFileURL(path.join(f.output, 'program.js')).href);
  assert.equal(typeof prepared.default.fetch, 'function');
});

test('non-current, future, internal and malformed paths never read JPEG bytes, including HEAD', async t => {
  const f = await fixture(t); let now = START;
  t.mock.method(Date, 'now', () => now);
  for (const method of ['GET', 'HEAD']) {
    for (const route of [jpegRoute(f.hashes[1]), '/__program/index.json', '/__program/images/' + f.hashes[0] + '.jpg',
      '/loop-config.json', '/schedule-review.json', '/catalog.json', '/windows/weekly-theme/catalog.json',
      '/windows/black-cats/catalog.json?future=1', '/windows/black-cats/%2e%2e%2f__program/index.json']) {
      const result = await request(f, route, { method });
      assert.equal(result.response.status, 404, route);
      assert(!result.calls.some(value => value.endsWith('.jpg')));
      if (method === 'HEAD') assert.equal(await result.response.text(), '');
    }
  }
  now += DAY;
  assert.equal((await request(f, jpegRoute(f.hashes[0]))).response.status, 404, 'Yesterday is not a fallback');
  assert.equal((await request(f, jpegRoute(f.hashes[1]), { method: 'HEAD' })).response.status, 200);
  assert.equal((await request(f, '/windows/black-cats/catalog.json', { method: 'POST' })).response.status, 405);
});

test('I/O crossing midnight fails closed and corrupted image bytes fail hash verification', async t => {
  const f = await fixture(t); let now = START + DAY - 1;
  t.mock.method(Date, 'now', () => now);
  const before = await (await request(f, '/windows/black-cats/catalog.json')).response.json();
  const crossed = await request(f, jpegRoute(f.hashes[0]), { beforeRead: pathname => { if (pathname.endsWith('.jpg')) now++; } });
  assert.equal(crossed.response.status, 503);
  assert.equal(Date.parse(before.validUntil), now);
  assert.equal((await request(f, jpegRoute(f.hashes[1]), { corruptImage: true })).response.status, 503);
  assert.equal((await request(f, jpegRoute(f.hashes[1]))).response.status, 200);
});

test('append during later cycles preserves position and appends before wrapping to 001', async t => {
  const f = await fixture(t);
  const added = [];
  for (let i = 10; i < 12; i++) {
    const bytes = Buffer.from(jpeg); bytes.writeUInt16BE(i + 1, 14);
    const name = `${i + 1}.jpg`; await writeFile(path.join(f.input, name), bytes); added.push(name);
  }
  for (const startDay of [24, 30]) {
    const start = START + startDay * DAY;
    const startDate = new Date(start + 9 * 3600000).toISOString().slice(0, 10);
    const config = { ...f.config, action: 'append', startDate, order: [...f.config.order, ...added], previousBundle: f.output };
    const output = path.join(f.root, 'append-' + startDay);
    await prepareBlackCatLoop({ input: f.input, output, config, publicationApproved: true }, start - 1);
    const index = await json(path.join(output, 'assets/__program/index.json'));
    for (let i = 0; i < startDay; i++) assert.deepEqual(blackCatDay(index, START + i * DAY), blackCatDay(f.index, START + i * DAY));
    // Day 24 continues with 005; day 30 follows 010 with newly appended 011.
    const firstPosition = startDay === 24 ? 4 : 10;
    for (let i = 0; i < 30; i++) {
      assert.equal(blackCatDay(index, start + i * DAY).catalog.photos[0].sha256,
        index.epochs.at(-1).order[(firstPosition + i) % 12]);
    }
  }
});

test('reset changes only at the configured midnight and starts at first explicitly ordered image', async t => {
  const f = await fixture(t), resetAt = START + 25 * DAY;
  const config = { ...f.config, action: 'reset', startDate: '2026-12-26', order: [...f.config.order].reverse(), previousBundle: f.output };
  const output = path.join(f.root, 'reset');
  await prepareBlackCatLoop({ input: f.input, output, config, publicationApproved: true }, resetAt - 1);
  const index = await json(path.join(output, 'assets/__program/index.json'));
  assert.deepEqual(blackCatDay(index, resetAt - 1), blackCatDay(f.index, resetAt - 1));
  assert.equal(blackCatDay(index, resetAt).catalog.photos[0].sha256, f.hashes[9]);
  assert.equal(blackCatDay(index, resetAt + 10 * DAY).catalog.photos[0].sha256, f.hashes[9]);
});

test('fifty approved appended slots follow 010; prefix reorder or replacement is rejected', async t => {
  const f = await fixture(t), order = [...f.config.order];
  for (let i = 10; i < 60; i++) {
    const bytes = Buffer.from(jpeg); bytes.writeUInt16BE(i + 1, 14);
    const name = `${String(i + 1).padStart(3, '0')}.jpg`;
    await writeFile(path.join(f.input, name), bytes); order.push(name);
  }
  const config = { ...f.config, action: 'append', startDate: '2026-12-31', order, previousBundle: f.output };
  const output = path.join(f.root, 'sixty');
  await prepareBlackCatLoop({ input: f.input, output, config, publicationApproved: true }, START + 29 * DAY);
  const index = await json(path.join(output, 'assets/__program/index.json'));
  assert.equal(index.images.length, 60);
  const expected = index.epochs.at(-1).order;
  assert.equal(blackCatDay(index, START + 30 * DAY).catalog.photos[0].sha256, expected[10]);
  assert.equal(blackCatDay(index, START + 79 * DAY).catalog.photos[0].sha256, expected[59]);
  assert.equal(blackCatDay(index, START + 80 * DAY).catalog.photos[0].sha256, expected[0]);
  const reordered = { ...config, order: [order[1], order[0], ...order.slice(2)] };
  await assert.rejects(prepareBlackCatLoop({ input: f.input, output: path.join(f.root, 'reordered'), config: reordered, publicationApproved: true }, START));
  const changed = Buffer.from(jpeg); changed.writeUInt16BE(99, 14);
  await writeFile(path.join(f.input, order[0]), changed);
  await assert.rejects(prepareBlackCatLoop({ input: f.input, output: path.join(f.root, 'changed'), config, publicationApproved: true }, START));
  await assert.rejects(access(path.join(f.root, 'changed')));
});

test('invalid append, expired cutover, unapproved inputs and modified schedules leave no output', async t => {
  const f = await fixture(t);
  const cases = [
    { ...f.config, credit: 'ねこのまど' },
    { ...f.config, order: [...f.config.order, f.config.order[0]] },
    { ...f.config, order: ['../001.jpg', ...f.config.order.slice(1)] },
    { ...f.config, action: 'append', startDate: '2026-12-02', previousBundle: f.output },
    { ...f.config, action: 'reset', startDate: '2026-12-01', previousBundle: f.output },
  ];
  for (const [i, config] of cases.entries()) {
    const output = path.join(f.root, 'invalid-' + i);
    await assert.rejects(prepareBlackCatLoop({ input: f.input, output, config, publicationApproved: true }, START));
    await assert.rejects(access(output));
  }
  await assert.rejects(prepareBlackCatLoop({ input: f.input, output: path.join(f.root, 'unapproved'), config: f.config, publicationApproved: false }));
  const wrongPhase = structuredClone(f.index);
  wrongPhase.epochs.push({ action: 'append', startsAt: '2026-12-24T15:00:00Z', cycleStartsAt: '2026-12-24T15:00:00Z', order: [...f.index.epochs[0].order] });
  assert.throws(() => validateProgram(wrongPhase));
  for (const change of [v => { v.epochs[0].cycleStartsAt = '2026-12-01T00:00:00Z'; },
    v => { v.images[0].sourcePath = 'private'; }, v => { v.epochs[0].order[0] = '0'.repeat(64); },
    v => { v.epochs[0].order.push(v.epochs[0].order[0]); }]) {
    const bad = structuredClone(f.index); change(bad); assert.throws(() => validateBlackCatLoop(bad));
  }
});

test('single config CLI is explicit and public assets omit input names and local paths', async t => {
  const f = await fixture(t), configPath = path.join(f.root, 'operator.json'), output = path.join(f.root, 'cli');
  await writeFile(configPath, JSON.stringify(f.config));
  const tool = path.resolve('tools/prepare_black_cat_days.mjs');
  const args = [tool, '--loop-config', configPath, '--input', f.input, '--output', output];
  await assert.rejects(run(process.execPath, args));
  await run(process.execPath, [...args, '--publication-approved']);
  const raw = await readFile(path.join(output, 'assets/__program/index.json'), 'utf8');
  assert(!raw.includes(f.input)); assert(!raw.includes('001.jpg'));
  const review = await json(path.join(output, 'schedule-review.json'));
  assert.equal(review.nextDays[0].filename, '001.jpg'); assert.equal(review.nextDays[10].filename, '001.jpg');
});
