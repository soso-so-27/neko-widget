import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, realpath, mkdir, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import worker from '../src/program.js';
import { BLACK_CAT_CREDIT } from '../src/black-cat-loop.js';
import { prepareBlackCatLoop } from '../tools/prepare_black_cat_days.mjs';
import { checkBlackCatLoop, verifyBlackCatLoop, PREVIEW_ORIGIN } from '../tools/check_black_cat_loop.mjs';

const DAY = 86400000, START = Date.parse('2026-11-30T15:00:00Z');
const VERSION = '11111111-1111-4111-8111-111111111111';
const jpeg = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP7//2Q==', 'base64');
const json = async filename => JSON.parse(await readFile(filename, 'utf8'));
async function fixture(t, count = 2) {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), 'neko-loop-monitor-')));
  t.after(() => rm(root, { recursive: true, force: true }));
  const input = path.join(root, 'input'), bundle = path.join(root, 'bundle'), runtime = path.join(root, 'runtime');
  await mkdir(input); await mkdir(runtime);
  const order = Array.from({ length: count }, (_, i) => String(i + 1).padStart(3, '0') + '.jpg');
  for (const [i, name] of order.entries()) {
    const bytes = Buffer.from(jpeg); bytes.writeUInt16BE(i + 1, 14); await writeFile(path.join(input, name), bytes);
  }
  await prepareBlackCatLoop({ input, output: bundle, config: { schemaVersion: 1, action: 'create',
    startDate: '2026-12-01', credit: BLACK_CAT_CREDIT, order }, publicationApproved: true }, START - DAY);
  const current = path.join(runtime, 'current.json'), receipt = path.join(runtime, 'last-check.json');
  const pointer = { schemaVersion: 2, mode: 'loop', currentBundle: bundle, workerVersion: VERSION };
  await writeFile(current, JSON.stringify(pointer));
  let now = START + 3600000;
  t.mock.method(Date, 'now', () => now);
  const requests = [], versions = [];
  const fetcher = async (url, options) => {
    assert.equal(new URL(url).origin, PREVIEW_ORIGIN); assert.equal(options.redirect, 'error');
    assert(['GET', 'HEAD'].includes(options.method)); requests.push([url, options.method]);
    return worker.fetch(new Request(url, options), { OFFICIAL_ASSETS: { async fetch(request) {
      try { return new Response(await readFile(path.join(bundle, 'assets', new URL(request.url).pathname))); }
      catch { return new Response(null, { status: 404 }); }
    } } });
  };
  const versionReader = async config => { versions.push(config); return VERSION; };
  return { root, bundle, runtime, current, receipt, pointer, requests, versions, fetcher,
    setTime: value => { now = value; }, options: { current, receipt, fetcher, versionReader, clock: () => now } };
}

test('read-only check matches approved day, version and forbidden GET/HEAD routes; only one receipt persists', async t => {
  const f = await fixture(t, 60), before = await readFile(f.current);
  f.setTime(START + DAY + 3600000);
  const result = await checkBlackCatLoop(f.options);
  assert.equal(result.status, 'ok'); assert.equal(result.notify, false);
  assert.equal(result.validUntil, '2026-12-02T15:00:00Z'); assert.equal(result.photoID, 'black-20261202');
  assert.equal(f.versions.length, 2); assert(f.versions.every(value => value === path.join(f.bundle, 'wrangler.jsonc')));
  for (const route of ['/__program/index.json', '/loop-config.json', '/catalog.json', '/windows/black-cats/catalog.json?future=1']) {
    for (const method of ['GET', 'HEAD']) assert(f.requests.some(([url, verb]) => url === PREVIEW_ORIGIN + route && verb === method));
  }
  const index = await json(path.join(f.bundle, 'assets/__program/index.json'));
  const nextURL = PREVIEW_ORIGIN + '/windows/black-cats/' + index.epochs[0].order[2] + '.jpg';
  const nonCurrent = f.requests.filter(([url]) => url.startsWith(PREVIEW_ORIGIN + '/windows/black-cats/')
    && url.endsWith('.jpg') && !url.endsWith(result.sha256 + '.jpg'));
  assert.deepEqual(nonCurrent, [[nextURL, 'GET'], [nextURL, 'HEAD']], 'Only tomorrow, not all 59 non-current images');
  assert.equal(f.requests.length, 20, 'Fixed forbidden routes plus one representative stay bounded');
  assert.deepEqual(await readFile(f.current), before);
  assert.deepEqual((await readdir(f.runtime)).sort(), ['current.json', 'last-check.json']);
  assert.equal((await checkBlackCatLoop(f.options)).notify, false);
});

test('new daily edition notifies once, including a repeated image on a later cycle', async t => {
  const f = await fixture(t); const first = await checkBlackCatLoop(f.options);
  f.setTime(START + DAY + 1); const second = await checkBlackCatLoop(f.options);
  assert.equal(second.notify, true); assert.notEqual(second.sha256, first.sha256);
  assert.equal((await checkBlackCatLoop(f.options)).notify, false);
  f.setTime(START + DAY * 2 + 1); const third = await checkBlackCatLoop(f.options);
  assert.equal(third.sha256, first.sha256); assert.equal(third.notify, true);
});

test('same failure is quiet, a different failure notifies, recovery retains last successful day', async t => {
  const f = await fixture(t); await checkBlackCatLoop(f.options);
  const bad = { ...f.options, versionReader: async () => { throw new Error('DO NOT PRINT credentials or child stderr'); } };
  const first = await checkBlackCatLoop(bad), repeated = await checkBlackCatLoop(bad);
  assert.equal(first.failure, 'version'); assert.equal(first.notify, true); assert.equal(repeated.notify, false);
  assert(!JSON.stringify(first).includes('credentials'));
  await writeFile(path.join(f.runtime, 'pending.json'), '{}');
  const pending = await checkBlackCatLoop(f.options); assert.equal(pending.failure, 'pending'); assert.equal(pending.notify, true);
  assert.equal((await checkBlackCatLoop(f.options)).notify, false);
  await rm(path.join(f.runtime, 'pending.json'));
  const recovered = await checkBlackCatLoop(f.options); assert.equal(recovered.status, 'ok'); assert.equal(recovered.notify, false);
  assert.equal((await checkBlackCatLoop(bad)).notify, true, 'A failure after recovery is new');
  f.setTime(START + DAY + 1); assert.equal((await checkBlackCatLoop(f.options)).notify, true);
});

test('pending, old mode and unapproved/tampered bundles stop before any network or OAuth call', async t => {
  const f = await fixture(t), originalReview = await readFile(path.join(f.bundle, 'schedule-review.json'));
  await writeFile(path.join(f.runtime, 'pending.json'), '{}');
  assert.equal((await checkBlackCatLoop(f.options)).failure, 'pending');
  await rm(path.join(f.runtime, 'pending.json'));
  await writeFile(f.current, JSON.stringify({ ...f.pointer, mode: 'scheduled' }));
  assert.equal((await checkBlackCatLoop(f.options)).failure, 'pointer');
  await writeFile(f.current, JSON.stringify(f.pointer));
  const review = JSON.parse(originalReview); review.publicationApproved = false;
  await writeFile(path.join(f.bundle, 'schedule-review.json'), JSON.stringify(review));
  assert.equal((await checkBlackCatLoop(f.options)).failure, 'bundle');
  await writeFile(path.join(f.bundle, 'schedule-review.json'), originalReview);
  const config = await json(path.join(f.bundle, 'wrangler.jsonc')); config.name = 'production';
  await writeFile(path.join(f.bundle, 'wrangler.jsonc'), JSON.stringify(config));
  assert.equal((await checkBlackCatLoop(f.options)).failure, 'bundle');
  assert.equal(f.requests.length, 0); assert.equal(f.versions.length, 0);
});

test('wrong catalog day/deadline, JPEG bytes and exposed private route fail separately', async t => {
  const f = await fixture(t);
  for (const field of ['validUntil', 'publishedAt', 'credit']) {
    const fetcher = async (url, options) => {
      const response = await f.fetcher(url, options);
      if (url === PREVIEW_ORIGIN + '/windows/black-cats/catalog.json') {
        const catalog = await response.json();
        if (field === 'validUntil') catalog.validUntil = '2026-12-02T15:00:00Z';
        else catalog.photos[0][field] = field === 'credit' ? 'Unknown credit' : '2026-11-29T15:00:00Z';
        return Response.json(catalog);
      }
      return response;
    };
    assert.equal((await checkBlackCatLoop({ ...f.options, fetcher })).failure, 'catalog');
  }
  const corrupt = async (url, options) => url.endsWith('.jpg') ? new Response('wrong', { headers: { 'content-type': 'image/jpeg' } }) : f.fetcher(url, options);
  assert.equal((await checkBlackCatLoop({ ...f.options, fetcher: corrupt })).failure, 'image');
  const exposed = async (url, options) => url.endsWith('/__program/index.json') ? new Response('{}') : f.fetcher(url, options);
  assert.equal((await checkBlackCatLoop({ ...f.options, fetcher: exposed })).failure, 'forbidden');
});

test('version/pointer changes or JST midnight during the check cannot be accepted', async t => {
  const f = await fixture(t); let calls = 0;
  assert.equal((await checkBlackCatLoop({ ...f.options, versionReader: async () => ++calls === 1 ? VERSION : 'other' })).failure, 'version');
  calls = 0;
  const changed = async () => { if (++calls === 2) await writeFile(f.current, JSON.stringify({ ...f.pointer, changed: true })); return VERSION; };
  assert.equal((await checkBlackCatLoop({ ...f.options, versionReader: changed })).failure, 'changed');
  await writeFile(f.current, JSON.stringify(f.pointer)); calls = 0;
  const crossed = async () => { if (++calls === 2) f.setTime(START + DAY); return VERSION; };
  assert.equal((await checkBlackCatLoop({ ...f.options, versionReader: crossed })).failure, 'boundary');
});

test('CLI pending failure uses selected receipt, deduplicates, and never invokes deployment or version lookup', async t => {
  const f = await fixture(t); await writeFile(path.join(f.runtime, 'pending.json'), '{}');
  const args = [path.resolve('tools/check_black_cat_loop.mjs'), '--current', f.current, '--receipt', f.receipt];
  const invoke = async () => {
    try { await promisify(execFile)(process.execPath, args); assert.fail('Pending must exit nonzero'); }
    catch (error) { assert.equal(error.code, 1); assert.equal(error.stderr, ''); return JSON.parse(error.stdout); }
  };
  assert.equal((await invoke()).notify, true); assert.equal((await invoke()).notify, false);
  assert.deepEqual((await readdir(f.runtime)).sort(), ['current.json', 'last-check.json', 'pending.json']);
  await assert.rejects(checkBlackCatLoop({ ...f.options, receipt: f.current }));
  await assert.rejects(checkBlackCatLoop({ ...f.options, receipt: path.join(f.root, 'elsewhere.json') }));
  await assert.rejects(verifyBlackCatLoop(f.current, f.options), error => error.code === 'pending');
});
