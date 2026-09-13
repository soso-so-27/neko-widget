import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, access, unlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { prepareCatWindow } from '../tools/prepare_cat_window.mjs';
import { CAT_WINDOWS, prepareUpdate } from '../tools/prepare_update.mjs';
import { previousPhotosForChannel } from '../tools/verify_preview.mjs';

const service = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const now = Math.floor(Date.now() / 1000) * 1000, DAY = 86400_000;
const utc = value => new Date(value).toISOString().replace('.000Z', 'Z');
const channel = 'cat-tabby-nap', catID = CAT_WINDOWS[channel].catID;
const read = filename => readFile(filename, 'utf8').then(JSON.parse);
// Known metadata-free 1x1 publisher JPEG. No private or externally fetched images.
const jpeg = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP7//2Q==', 'base64');
function photo(id, cat = catID, extra = {}, bytes = jpeg) {
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  return { id, catID: cat, catName: 'キジ白', credit: '合成テスト', caption: '確認用',
    publishedAt: utc(now - DAY), expiresAt: utc(now + DAY),
    imageFilename: sha256 + '.jpg', sha256, width: 1, height: 1, ...extra };
}
async function edition(directory, id, photos, changes = {}, bytes = jpeg) {
  await mkdir(directory, { recursive: true });
  const catalog = { schemaVersion: 1, channelID: id, enabled: true,
    generatedAt: utc(now - 3600_000), validUntil: utc(now + DAY), photos, ...changes };
  for (const item of photos) await writeFile(path.join(directory, item.imageFilename), bytes);
  await writeFile(path.join(directory, 'catalog.json'), JSON.stringify(catalog));
  return catalog;
}
async function fixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'neko-cat-window-')), previous = path.join(root, 'previous');
  const selected = photo('generated-20260913-tabby-nap'), other = photo('similar-tabby', 'generated-tabby-v3');
  const source = await edition(path.join(previous, 'assets'), 'official-cats', [selected, other]);
  const nap = await edition(path.join(previous, 'assets/windows/nap-cats'), 'nap-cats', [selected]);
  const history = { schemaVersion: 1, generatedAt: source.generatedAt,
    channels: [source, nap].map(catalog => ({ channelID: catalog.channelID, enabled: catalog.enabled, history: catalog.photos })) };
  await writeFile(path.join(previous, 'update-record.json'), JSON.stringify(history));
  const config = await read(path.join(service, 'wrangler.jsonc'));
  delete config.$schema; config.main = './worker.js'; config.assets.directory = './assets';
  await writeFile(path.join(previous, 'wrangler.jsonc'), JSON.stringify(config));
  await writeFile(path.join(previous, 'worker.js'), await readFile(path.join(service, 'src/index.js')));
  return { root, previous, selected, other, source, nap, history, output: path.join(root, 'created') };
}
const catalogPath = (bundle, id) => path.join(bundle, 'assets', id === 'official-cats' ? '' : 'windows/' + id, 'catalog.json');

test('first cat window references exact identity, original dates/bytes and every existing channel', async () => {
  const f = await fixture(), originalRecord = await readFile(path.join(f.previous, 'update-record.json'));
  const result = await prepareCatWindow(f.previous, channel, f.output, now);
  assert.deepEqual((await read(catalogPath(result.bundle, channel))).photos, [f.selected]);
  assert.deepEqual((await read(catalogPath(result.bundle, 'official-cats'))).photos, f.source.photos);
  assert.deepEqual((await read(catalogPath(result.bundle, 'nap-cats'))).photos, f.nap.photos);
  assert.deepEqual(await readFile(path.join(result.bundle, 'assets/windows', channel, f.selected.imageFilename)), jpeg);
  const record = await read(path.join(result.bundle, 'update-record.json'));
  assert.deepEqual(record.channels.map(row => row.channelID), ['official-cats', 'nap-cats', channel]);
  assert.deepEqual(record.channels[0].history, f.history.channels[0].history);
  assert.deepEqual(record.channels[2].history, [f.selected]);
  assert.deepEqual(record.channels[2].added, []);
  assert.deepEqual(record.channels[2].referenced, [f.selected.id]);
  assert.equal(record.channels[2].catID, catID);
  assert.deepEqual(await readFile(path.join(f.previous, 'update-record.json')), originalRecord);
  for (const filename of ['worker.js', 'wrangler.jsonc']) {
    const old = await readFile(path.join(f.previous, filename)), current = await readFile(path.join(result.bundle, filename));
    if (filename.endsWith('jsonc')) assert.deepEqual(JSON.parse(current), JSON.parse(old));
    else assert.deepEqual(current, old);
  }
  await assert.rejects(access(path.join(result.bundle, 'assets/update-record.json')));
});

test('unrelated paused window and its withdrawn history stay paused', async () => {
  const f = await fixture();
  f.nap.enabled = false; f.nap.photos = [];
  await writeFile(catalogPath(f.previous, 'nap-cats'), JSON.stringify(f.nap));
  await unlink(path.join(f.previous, 'assets/windows/nap-cats', f.selected.imageFilename));
  const result = await prepareCatWindow(f.previous, channel, f.output, now);
  const paused = await read(catalogPath(result.bundle, 'nap-cats'));
  assert.equal(paused.enabled, false); assert.deepEqual(paused.photos, []);
  assert.deepEqual((await read(path.join(result.bundle, 'update-record.json'))).channels[1].history, [f.selected]);
});

for (const mode of ['unknown', 'collision', 'no-exact-cat', 'withdrawn', 'expired-photo', 'expired-catalog', 'paused-source', 'missing-history', 'wrong-history-cat', 'worker-change']) {
  test(`creation rejects ${mode} without a final candidate`, async () => {
    const f = await fixture();
    if (mode === 'collision') f.history.channels.push({ channelID: channel, enabled: false, history: [f.selected] });
    if (mode === 'no-exact-cat') f.source.photos = [f.other];
    if (mode === 'withdrawn') f.source.photos = [];
    if (mode === 'expired-photo') f.source.photos = [{ ...f.selected, expiresAt: utc(now) }];
    if (mode === 'expired-catalog') f.source.validUntil = utc(now);
    if (mode === 'paused-source') { f.source.enabled = false; f.source.photos = []; }
    if (mode === 'wrong-history-cat') f.history.channels[0].history = [{ ...f.selected, catID: 'different-cat' }, f.other];
    await writeFile(catalogPath(f.previous, 'official-cats'), JSON.stringify(f.source));
    await writeFile(path.join(f.previous, 'update-record.json'), JSON.stringify(f.history));
    if (mode === 'missing-history') await unlink(path.join(f.previous, 'update-record.json'));
    if (mode === 'worker-change') await writeFile(path.join(f.previous, 'worker.js'), 'different worker');
    await assert.rejects(prepareCatWindow(f.previous, mode === 'unknown' ? '../other' : channel, f.output, now));
    await assert.rejects(access(path.join(f.output, 'bundle')));
  });
}

test('creation does not overwrite output or nest output inside its source', async () => {
  const f = await fixture();
  await mkdir(f.output);
  await assert.rejects(prepareCatWindow(f.previous, channel, f.output, now), /already exists/);
  await assert.rejects(prepareCatWindow(f.previous, channel, path.join(f.previous, 'child'), now), /outside/);
});

test('updates retain the cat constraint, including pause, and recreation cannot bypass it', async () => {
  const f = await fixture(), created = await prepareCatWindow(f.previous, channel, f.output, now);
  const updated = await prepareUpdate(created.bundle, { schemaVersion: 1, channels: [{ channelID: channel, paused: true }] }, path.join(f.root, 'pause'), now + 2000);
  const own = updated.channels.find(row => row.channelID === channel);
  assert.equal(own.catID, catID); assert.equal(own.enabled, false); assert.deepEqual(own.history, [f.selected]);
  assert.deepEqual((await read(catalogPath(updated.bundle, channel))).photos, []);
  await assert.rejects(prepareCatWindow(updated.bundle, channel, path.join(f.root, 'recreate'), now + 3000), /already exists/);
});

test('a later photo of the same exact cat is accepted without relabeling its first publication', async () => {
  const f = await fixture(), created = await prepareCatWindow(f.previous, channel, f.output, now);
  const nextBytes = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAB//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKn//2Q==', 'base64');
  const next = photo('later-photo', catID, { publishedAt: utc(now + 1000) }, nextBytes), extra = path.join(f.root, 'extra');
  await edition(extra, channel, [next], { generatedAt: utc(now + 1000) }, nextBytes);
  const result = await prepareUpdate(created.bundle, { schemaVersion: 1, channels: [{ channelID: channel, addAssets: extra }] }, path.join(f.root, 'update'), now + 2000);
  assert.deepEqual((await read(catalogPath(result.bundle, channel))).photos, [next, f.selected]);
  const own = result.channels.find(row => row.channelID === channel);
  assert.equal(own.catID, catID);
  assert.deepEqual(own.added, [next.id]);
});

for (const mode of ['missing-constraint', 'wrong-constraint', 'wrong-history-cat', 'wrong-current-cat', 'wrong-addition-cat']) {
  test(`ordinary update rejects ${mode}`, async () => {
    const f = await fixture(), created = await prepareCatWindow(f.previous, channel, f.output, now);
    const filename = path.join(created.bundle, 'update-record.json'), record = await read(filename);
    const own = record.channels.find(row => row.channelID === channel);
    if (mode === 'missing-constraint') delete own.catID;
    if (mode === 'wrong-constraint') own.catID = 'different-cat';
    if (mode === 'wrong-history-cat') own.history[0].catID = 'different-cat';
    if (mode === 'wrong-current-cat') {
      const catalog = await read(catalogPath(created.bundle, channel));
      catalog.photos[0].catID = 'different-cat';
      await writeFile(catalogPath(created.bundle, channel), JSON.stringify(catalog));
    }
    await writeFile(filename, JSON.stringify(record));
    const channels = [];
    if (mode === 'wrong-addition-cat') {
      const extra = path.join(f.root, 'extra');
      await edition(extra, channel, [photo('different-photo', 'different-cat', { publishedAt: utc(now + 1000) })], { generatedAt: utc(now + 1000) });
      channels.push({ channelID: channel, addAssets: extra });
    }
    await assert.rejects(prepareUpdate(created.bundle, { schemaVersion: 1, channels }, path.join(f.root, 'update'), now + 2000), /cat-window/);
    await assert.rejects(access(path.join(f.root, 'update')));
  });
}

test('post-deploy former-URL lookup permits only a truly new known cat channel', async () => {
  const f = await fixture();
  assert.deepEqual(await previousPhotosForChannel(f.previous, channel), []);
  assert.deepEqual(await previousPhotosForChannel(f.previous, 'nap-cats'), [f.selected]);
  await assert.rejects(previousPhotosForChannel(f.previous, 'unknown-cats'), /Unknown new channel/);
  await edition(path.join(f.previous, 'assets/windows', channel), channel, [f.selected]);
  await assert.rejects(previousPhotosForChannel(f.previous, channel), /missing from history/);
  await unlink(catalogPath(f.previous, 'nap-cats'));
  await assert.rejects(previousPhotosForChannel(f.previous, 'nap-cats'), /ENOENT/);
});
