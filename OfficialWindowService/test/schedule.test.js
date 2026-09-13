import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, readdir, access, unlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import scheduled, { CHANNELS, INDEX_PATH, validateSchedule, selectEdition } from '../src/scheduled.js';
import { prepareSchedule } from '../tools/prepare_schedule.mjs';
import { restoreCurrentEdition } from '../tools/restore_schedule.mjs';
import { prepareUpdate } from '../tools/prepare_update.mjs';
import { verifySchedule } from '../tools/verify_schedule.mjs';
import { service, expectedConfig, stamp, hash, route, currentScheduledEdition } from '../tools/schedule_bundle.mjs';

const NOW = Date.parse('2026-09-13T12:00:00Z'), HOUR = 3600_000, DAY = 24 * HOUR;
const read = filename => readFile(filename, 'utf8').then(JSON.parse);
const JPEG = [
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP7//2Q==',
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAB//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKn//2Q==',
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP//Z',
].map(value => Buffer.from(value, 'base64'));
const metadata = (id, bytes) => ({ id, catID: 'generated-tabby-nap', catName: 'キジ白', credit: '合成テスト（AI生成）',
  caption: '確認用', imageFilename: hash(bytes) + '.jpg', sha256: hash(bytes), width: 1, height: 1 });
async function fixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'neko-schedule-')), previous = path.join(root, 'previous');
  const old = { ...metadata('old-photo', JPEG[0]), publishedAt: stamp(NOW - DAY), expiresAt: stamp(NOW + 3 * DAY) };
  const record = { schemaVersion: 1, generatedAt: stamp(NOW - HOUR), validUntil: stamp(NOW + 47 * HOUR), channels: [] };
  await mkdir(path.join(previous, 'assets/windows'), { recursive: true });
  for (const channel of CHANNELS) {
    const location = path.join(previous, 'assets', route(channel));
    if (channel !== 'official-cats') await mkdir(location);
    await writeFile(path.join(location, 'catalog.json'), JSON.stringify({ schemaVersion: 1, channelID: channel, enabled: true,
      generatedAt: record.generatedAt, validUntil: record.validUntil, photos: [old] }));
    await writeFile(path.join(location, old.imageFilename), JPEG[0]);
    record.channels.push({ channelID: channel, enabled: true, ...(channel === 'cat-tabby-nap' ? { catID: old.catID } : {}), history: [old] });
  }
  await writeFile(path.join(previous, 'update-record.json'), JSON.stringify(record));
  await writeFile(path.join(previous, 'worker.js'), await readFile(path.join(service, 'src/index.js')));
  await writeFile(path.join(previous, 'wrangler.jsonc'), JSON.stringify(await expectedConfig()));
  const queue = { schemaVersion: 1, items: [] };
  await mkdir(path.join(root, 'inputs'));
  for (const [position, when] of [NOW + 2 * HOUR, NOW + 2 * DAY].entries()) {
    const photo = metadata(`future-${position}`, JPEG[position + 1]), imagePath = path.join(root, 'inputs', photo.imageFilename);
    await writeFile(imagePath, JPEG[position + 1]);
    queue.items.push({ id: photo.id, channels: ['cat-tabby-nap'], scheduledAt: stamp(when), approvedUntil: stamp(NOW + (position ? 10 : 4) * DAY), imagePath, photo, approved: true });
  }
  return { root, previous, old, record, queue, output: path.join(root, 'compiled') };
}
const compile = f => prepareSchedule(f.previous, f.queue, f.output, stamp(NOW + 14 * DAY), NOW);
const catalogPath = (bundle, channel) => path.join(bundle, 'assets', route(channel), 'catalog.json');

test('fourteen-day compilation preserves identities, leases, history and exact future publication times', async () => {
  const f = await fixture(), sourceRecord = await readFile(path.join(f.previous, 'update-record.json'));
  const result = await compile(f), index = await read(path.join(result.bundle, 'assets', INDEX_PATH));
  validateSchedule(index);
  assert.equal(index.through, stamp(NOW + 14 * DAY));
  assert.equal(index.editions[0].startsAt, stamp(NOW));
  assert.deepEqual(await readFile(path.join(f.previous, 'update-record.json')), sourceRecord);
  const initial = await currentScheduledEdition(result.bundle, NOW + HOUR);
  for (const channel of CHANNELS) assert.deepEqual(initial.content.catalogs[channel].catalog.photos, [f.old]);
  assert.deepEqual(initial.record.channels.map(row => row.history), f.record.channels.map(row => row.history));
  const first = await currentScheduledEdition(result.bundle, NOW + 2 * HOUR);
  const nextPhoto = first.content.catalogs['cat-tabby-nap'].catalog.photos[0];
  assert.deepEqual(nextPhoto, { ...f.queue.items[0].photo, publishedAt: stamp(NOW + 2 * HOUR), expiresAt: stamp(NOW + 4 * DAY) });
  assert.deepEqual(first.content.catalogs['official-cats'].catalog.photos, [f.old]);
  const second = await currentScheduledEdition(result.bundle, NOW + 2 * DAY);
  assert.equal(second.content.catalogs['cat-tabby-nap'].catalog.photos[0].expiresAt, stamp(NOW + 9 * DAY));
  const last = await currentScheduledEdition(result.bundle, NOW + 14 * DAY - 1);
  for (const channel of CHANNELS) {
    assert.deepEqual(last.content.catalogs[channel].catalog.photos, []);
    assert.equal(last.content.catalogs[channel].catalog.validUntil, index.through);
  }
  assert.equal(last.record.channels.find(row => row.channelID === 'cat-tabby-nap').history.length, 3);
  assert.deepEqual((await readdir(path.join(result.bundle, 'assets'))), ['__schedule']);
  await assert.rejects(access(path.join(result.bundle, 'assets/schedule-record.json')));
  assert.deepEqual(await read(path.join(result.bundle, 'wrangler.jsonc')), await expectedConfig(true));
  const plan = await readFile(path.join(result.bundle, 'assets', INDEX_PATH), 'utf8');
  assert.ok(!plan.includes(f.root) && !plan.includes('imagePath') && !plan.includes('approvedUntil'));
});

for (const mode of ['same-time', 'overdue', 'wrong-future-cat', 'unknown-channel', 'private-field', 'not-approved', 'duplicate-bytes', 'metadata', 'horizon', 'missing-history', 'worker-change']) {
  test(`schedule rejects ${mode} without a final bundle`, async () => {
    const f = await fixture();
    if (mode === 'same-time') f.queue.items[1].scheduledAt = f.queue.items[0].scheduledAt;
    if (mode === 'overdue') { f.queue.items[0].scheduledAt = stamp(NOW - 2000); f.queue.items[1].scheduledAt = stamp(NOW - 1000); }
    if (mode === 'wrong-future-cat') { f.queue.items[1].photo.catID = 'different-cat'; f.queue.items[1].scheduledAt = stamp(NOW + 20 * DAY); f.queue.items[1].approvedUntil = stamp(NOW + 21 * DAY); }
    if (mode === 'unknown-channel') f.queue.items[1].channels = ['unknown'];
    if (mode === 'private-field') f.queue.items[1].photo.internal = { private: 'never-public' };
    if (mode === 'not-approved') f.queue.items[1].approved = false;
    if (mode === 'duplicate-bytes') { f.queue.items[1].photo = { ...f.queue.items[0].photo, id: f.queue.items[1].id }; f.queue.items[1].imagePath = f.queue.items[0].imagePath; }
    if (mode === 'metadata') {
      const item = f.queue.items[1], bytes = Buffer.concat([JPEG[2].subarray(0, 2), Buffer.from([255, 225, 0, 8]), Buffer.from('Exif\0\0'), JPEG[2].subarray(2)]);
      item.photo.sha256 = hash(bytes); item.photo.imageFilename = hash(bytes) + '.jpg'; item.imagePath = path.join(f.root, 'inputs', item.photo.imageFilename);
      await writeFile(item.imagePath, bytes);
    }
    if (mode === 'missing-history') await unlink(path.join(f.previous, 'update-record.json'));
    if (mode === 'worker-change') await writeFile(path.join(f.previous, 'worker.js'), 'changed');
    await assert.rejects(prepareSchedule(f.previous, f.queue, f.output, stamp(NOW + (mode === 'horizon' ? 15 : 14) * DAY), NOW));
    await assert.rejects(access(path.join(f.output, 'bundle')));
  });
}

test('no overwrite, nested source output or future restoration is allowed', async () => {
  const f = await fixture(), result = await compile(f);
  await assert.rejects(compile(f), /already exists/);
  await assert.rejects(prepareSchedule(f.previous, f.queue, path.join(f.previous, 'nested'), stamp(NOW + DAY), NOW), /outside/);
  await assert.rejects(restoreCurrentEdition(result.bundle, path.join(f.root, 'too-early'), NOW - 1, { allowExpired: true }), /currently valid/);
  await assert.rejects(restoreCurrentEdition(result.bundle, path.join(f.root, 'too-late'), NOW + 14 * DAY), /currently valid/);
});

test('restoring and recompiling before a future publication does not mark it already published', async () => {
  const f = await fixture(), result = await compile(f);
  const restored = await restoreCurrentEdition(result.bundle, path.join(f.root, 'restored'), NOW + HOUR);
  const record = await read(path.join(restored.bundle, 'update-record.json'));
  assert(record.channels.every(row => row.history.every(photo => photo.id === f.old.id)));
  const next = await prepareSchedule(restored.bundle, f.queue, path.join(f.root, 'recompiled'), stamp(NOW + 14 * DAY), NOW + HOUR);
  const published = await currentScheduledEdition(next.bundle, NOW + 2 * HOUR);
  assert.equal(published.content.catalogs['cat-tabby-nap'].catalog.photos[0].publishedAt, f.queue.items[0].scheduledAt);
});

test('withdrawn photos never reappear and pausing survives every future edition', async () => {
  const f = await fixture(), result = await compile(f), at = NOW + 2 * HOUR + 1000;
  const restored = await restoreCurrentEdition(result.bundle, path.join(f.root, 'current'), at);
  for (const action of [{ withdraw: [f.queue.items[0].id] }, { paused: true }]) {
    const label = action.paused ? 'pause' : 'withdraw';
    const update = await prepareUpdate(restored.bundle, { schemaVersion: 1, channels: [{ channelID: 'cat-tabby-nap', ...action }] }, path.join(f.root, label), at + 1000);
    const next = await prepareSchedule(update.bundle, f.queue, path.join(f.root, label + '-schedule'), stamp(NOW + 14 * DAY), at + 2000);
    const index = await read(path.join(next.bundle, 'assets', INDEX_PATH));
    for (const edition of index.editions) {
      const current = await currentScheduledEdition(next.bundle, Date.parse(edition.startsAt));
      const own = current.content.catalogs['cat-tabby-nap'].catalog;
      assert(!own.photos.some(photo => photo.id === f.queue.items[0].id));
      if (action.paused) { assert.equal(own.enabled, false); assert.deepEqual(own.photos, []); }
      assert.equal(current.record.channels.find(row => row.channelID === 'cat-tabby-nap').catID, 'generated-tabby-nap');
    }
  }
});

async function environment(bundle, hook = () => {}) {
  const assets = new Map(), calls = [];
  async function walk(directory, prefix = '') {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const name = `${prefix}/${entry.name}`;
      if (entry.isDirectory()) await walk(path.join(directory, entry.name), name);
      else assets.set(name, await readFile(path.join(directory, entry.name)));
    }
  }
  await walk(path.join(bundle, 'assets'));
  return { assets, calls, OFFICIAL_ASSETS: { async fetch(request) {
    calls.push(request); await hook(request);
    const body = assets.get(new URL(request.url).pathname);
    return body instanceof Response ? body.clone() : new Response(body ?? 'missing', { status: body ? 200 : 404 });
  } } };
}
const fetchWorker = (url, env, init) => scheduled.fetch(new Request(`https://preview.invalid${url}`, init), env);

test('scheduled Worker exposes only active public URLs, with identical legacy routes and no-store', async t => {
  const f = await fixture(), result = await compile(f), env = await environment(result.bundle);
  let clock = NOW;
  t.mock.method(Date, 'now', () => clock);
  for (const channel of CHANNELS) {
    assert.equal((await fetchWorker('/' + [route(channel), 'catalog.json'].filter(Boolean).join('/'), env)).status, 200);
  }
  for (const name of [INDEX_PATH, '/__schedule/editions/edition-000/catalog.json', '/schedule-record.json', '/wrangler.jsonc',
    '/windows/unknown/catalog.json', '/windows/official-cats/catalog.json', '/%63atalog.json', '/catalog.json?x=1', '/']) {
    const before = env.calls.length;
    assert.equal((await fetchWorker(name, env)).status, 404);
    assert.equal(env.calls.length, before);
  }
  const item = f.queue.items[0];
  assert.equal((await fetchWorker(`/windows/cat-tabby-nap/${item.photo.imageFilename}`, env)).status, 404);
  clock = NOW + 2 * HOUR;
  const response = await fetchWorker(`/windows/cat-tabby-nap/${item.photo.imageFilename}`, env, { headers: { Cookie: 'private', Authorization: 'Bearer private', Range: 'bytes=0-2' } });
  assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), JPEG[1]);
  assert(env.calls.every(request => !request.headers.has('cookie') && !request.headers.has('authorization') && !request.headers.has('range')));
  assert.equal((await fetchWorker('/' + item.photo.imageFilename, env)).status, 404);
  assert.equal((await fetchWorker(`/windows/nap-cats/${item.photo.imageFilename}`, env)).status, 404);
  const head = await fetchWorker('/catalog.json', env, { method: 'HEAD' });
  assert.equal(head.status, 200); assert.equal(await head.text(), '');
  assert.equal((await fetchWorker('/catalog.json', env, { method: 'POST' })).status, 405);
  clock = NOW + 3 * DAY;
  assert.equal((await fetchWorker('/' + f.old.imageFilename, env)).status, 404);
  clock = NOW + 14 * DAY;
  assert.equal((await fetchWorker('/catalog.json', env)).status, 503);
  assert.equal((await fetchWorker(`/windows/cat-tabby-nap/${item.photo.imageFilename}`, env)).status, 503);
  assert.equal((await fetchWorker(INDEX_PATH, env)).status, 404);
});

test('catalog and JPEG reads crossing an edition boundary cannot return the older edition', async t => {
  const f = await fixture(), result = await compile(f);
  let clock = NOW + 2 * HOUR - 1;
  t.mock.method(Date, 'now', () => clock);
  for (const target of ['/catalog.json', '/' + f.old.imageFilename]) {
    clock = NOW + 2 * HOUR - 1;
    const env = await environment(result.bundle, request => {
      if (new URL(request.url).pathname.endsWith(target)) clock = NOW + 2 * HOUR;
    });
    assert.equal((await fetchWorker(target, env)).status, 503);
  }
});

test('invalid index, cross-channel catalog, corrupt JPEG and redirect assets fail closed', async t => {
  const f = await fixture(), result = await compile(f);
  t.mock.method(Date, 'now', () => NOW);
  for (const mutate of [
    env => { const index = JSON.parse(env.assets.get(INDEX_PATH)); index.editions[1].startsAt = stamp(NOW + 5000); env.assets.set(INDEX_PATH, JSON.stringify(index)); },
    env => { const index = JSON.parse(env.assets.get(INDEX_PATH)); index.editions[0].id = '../future'; env.assets.set(INDEX_PATH, JSON.stringify(index)); },
    env => { const index = JSON.parse(env.assets.get(INDEX_PATH)); index.editions[0].catalogs.unknown = '0'.repeat(64); env.assets.set(INDEX_PATH, JSON.stringify(index)); },
    env => env.assets.set('/__schedule/editions/edition-000/catalog.json', env.assets.get('/__schedule/editions/edition-000/windows/nap-cats/catalog.json')),
    env => env.assets.set('/__schedule/editions/edition-000/' + f.old.imageFilename, JPEG[1]),
    env => env.assets.set(INDEX_PATH, new Response(null, { status: 302, headers: { Location: '/catalog.json' } })),
  ]) {
    const env = await environment(result.bundle); mutate(env);
    assert.equal((await fetchWorker('/' + f.old.imageFilename, env)).status, 503);
  }
  const env = await environment(result.bundle);
  const internal = '/__schedule/editions/edition-000/windows/cat-tabby-nap/catalog.json';
  const wrong = JSON.parse(env.assets.get(internal)); wrong.photos[0].catID = 'another-cat';
  const changed = Buffer.from(JSON.stringify(wrong)); env.assets.set(internal, changed);
  const index = JSON.parse(env.assets.get(INDEX_PATH)); index.editions[0].catalogs['cat-tabby-nap'] = hash(changed);
  env.assets.set(INDEX_PATH, JSON.stringify(index));
  assert.equal((await fetchWorker('/windows/cat-tabby-nap/catalog.json', env)).status, 503);
});

test('expired recovery verifies the same version and all 503s, preserves deadlines and accepts new supply', async t => {
  const f = await fixture();
  // Short horizon deliberately leaves an old JPEG in the final historical edition.
  const result = await prepareSchedule(f.previous, { schemaVersion: 1, items: [] }, f.output, stamp(NOW + DAY), NOW);
  let clock = NOW + DAY;
  t.mock.method(Date, 'now', () => clock);
  const env = await environment(result.bundle);
  t.mock.method(globalThis, 'fetch', (url, init) => scheduled.fetch(new Request(url, init), env));
  const version = '11111111-2222-3333-4444-555555555555';
  let versionCalls = 0;
  const versionReader = async () => { versionCalls++; return version; };
  await assert.rejects(verifySchedule(result.bundle, version, path.join(f.root, 'default'), { versionReader }), /currently valid/);
  const verified = await verifySchedule(result.bundle, version, path.join(f.root, 'verified'), { allowExpired: true, versionReader });
  assert.equal(verified.expired, true); assert.equal(versionCalls, 3);
  assert(verified.channels.every(channel => channel.state === 'expired-known-version'));
  await assert.rejects(verifySchedule(result.bundle, version, path.join(f.root, 'wrong-version'), { allowExpired: true, versionReader: async () => '99999999-2222-3333-4444-555555555555' }), /recorded edition/);
  clock = NOW + 4 * DAY;
  const restored = await restoreCurrentEdition(result.bundle, path.join(f.root, 'expired-history'), clock, { allowExpired: true });
  const oldCatalog = await read(catalogPath(restored.bundle, 'official-cats'));
  assert.equal(oldCatalog.photos[0].expiresAt, f.old.expiresAt);
  const newItem = { ...f.queue.items[1], scheduledAt: stamp(clock + HOUR), approvedUntil: stamp(clock + 10 * DAY) };
  const next = await prepareSchedule(restored.bundle, { schemaVersion: 1, items: [newItem] }, path.join(f.root, 'recovery'), stamp(clock + 7 * DAY), clock);
  const empty = await currentScheduledEdition(next.bundle, clock);
  assert(CHANNELS.every(channel => empty.content.catalogs[channel].catalog.photos.length === 0));
  const replenished = await currentScheduledEdition(next.bundle, clock + HOUR);
  assert.equal(replenished.content.catalogs['cat-tabby-nap'].catalog.photos[0].id, newItem.id);
  assert(replenished.record.channels[0].history.some(photo => photo.id === f.old.id));
  await unlink(path.join(result.bundle, 'schedule-record.json'));
  await assert.rejects(restoreCurrentEdition(result.bundle, path.join(f.root, 'missing'), clock, { allowExpired: true }));
});

test('verification rechecks the Worker version after internal and future URL probes', async t => {
  const f = await fixture(), result = await compile(f), env = await environment(result.bundle);
  t.mock.method(Date, 'now', () => NOW);
  t.mock.method(globalThis, 'fetch', (url, init) => scheduled.fetch(new Request(url, init), env));
  const version = '11111111-2222-3333-4444-555555555555';
  let calls = 0;
  await assert.rejects(verifySchedule(result.bundle, version, path.join(f.root, 'inspect'), {
    versionReader: async () => ++calls < 3 ? version : '99999999-2222-3333-4444-555555555555',
  }), /changed during schedule verification/);
  assert.equal(calls, 3);
});
