import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, access } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { prepareUpdate } from '../tools/prepare_update.mjs';

const now = Math.floor(Date.now() / 1000) * 1000;
const utc = value => new Date(value).toISOString().replace('.000Z', 'Z');
const plan = (channels, bootstrap = true) => ({ schemaVersion: 1, channels, ...(bootstrap ? { bootstrapHistory: true } : {}) });
function photo(id, channel, extra = {}) {
  const bytes = Buffer.from([255, 216, ...Buffer.from(id), 255, 217]);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  return { bytes, row: { id, catID: 'cat', catName: '猫', credit: '合成テスト',
    publishedAt: utc(now - 86400_000), expiresAt: utc(now + 86400_000),
    sha256, imageFilename: sha256 + '.jpg', width: 20, height: 20, ...extra } };
}
async function assets(directory, channelID, photos, changes = {}) {
  await mkdir(directory, { recursive: true });
  const catalog = { schemaVersion: 1, channelID, enabled: true, generatedAt: utc(now - 3600_000),
    validUntil: utc(now + 3600_000), photos: photos.map(value => value.row), ...changes };
  for (const value of photos) await writeFile(path.join(directory, value.row.imageFilename), value.bytes);
  await writeFile(path.join(directory, 'catalog.json'), JSON.stringify(catalog));
  return catalog;
}
async function fixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'neko-edition-'));
  const previous = path.join(root, 'previous');
  const old = photo('old', 'official-cats');
  const nap = photo('nap', 'nap-cats');
  await assets(path.join(previous, 'assets'), 'official-cats', [old]);
  await assets(path.join(previous, 'assets/windows/nap-cats'), 'nap-cats', [nap]);
  return { root, previous, old, nap, output: path.join(root, 'new') };
}
const read = filename => readFile(filename, 'utf8').then(JSON.parse);
test('renew catalog preserves all channels, JPEGs and publication identities', async () => {
  const f = await fixture();
  const result = await prepareUpdate(f.previous, plan([]), f.output);
  for (const [channel, prefix, original] of [['official-cats', '', f.old], ['nap-cats', 'windows/nap-cats', f.nap]]) {
    const folder = path.join(result.bundle, 'assets', prefix);
    const catalog = await read(path.join(folder, 'catalog.json'));
    assert.deepEqual(catalog.photos, [original.row]);
    assert.deepEqual(await readFile(path.join(folder, original.row.imageFilename)), original.bytes);
    assert.deepEqual(result.channels.find(row => row.channelID === channel).added, []);
  }
  assert.equal(result.maintenanceDueAt, utc(Date.parse(f.old.row.expiresAt) - 6 * 3600_000));
});
test('adds to one channel, retains other photos and records the new ID', async () => {
  const f = await fixture(), added = photo('new', 'nap-cats', { publishedAt: utc(now - 1000) });
  const extra = path.join(f.root, 'added');
  await assets(extra, 'nap-cats', [added], { generatedAt: utc(now - 1000) });
  const result = await prepareUpdate(f.previous, plan([{ channelID: 'nap-cats', addAssets: extra }]), f.output);
  const nap = result.channels.find(row => row.channelID === 'nap-cats');
  assert.equal(nap.activeCount, 2); assert.equal(nap.newestPhotoID, 'new');
  assert.equal(result.channels[0].activeCount, 1);
  const record = await read(path.join(result.bundle, 'update-record.json'));
  assert.deepEqual(record.channels[1].history.map(row => row.id), ['nap', 'new']);
  await assert.rejects(access(path.join(result.bundle, 'assets', 'update-record.json')));
});
test('explicit photo extension changes only expiresAt and reports no additions', async () => {
  const f = await fixture(), expiresAt = utc(now + 3 * 86400_000);
  const result = await prepareUpdate(f.previous, plan([{ channelID: 'nap-cats', renewPhotos: [{ id: 'nap', expiresAt }] }]), f.output);
  const catalog = await read(path.join(result.bundle, 'assets/windows/nap-cats/catalog.json'));
  assert.deepEqual(catalog.photos, [{ ...f.nap.row, expiresAt }]);
  assert.deepEqual(result.channels[1].added, []);
});
test('withdrawal removes its JPEG; pause affects only the named channel', async () => {
  const f = await fixture();
  const result = await prepareUpdate(f.previous, plan([{ channelID: 'nap-cats', paused: true }]), f.output);
  const stopped = await read(path.join(result.bundle, 'assets/windows/nap-cats/catalog.json'));
  assert.equal(stopped.enabled, false); assert.deepEqual(stopped.photos, []);
  await assert.rejects(access(path.join(result.bundle, 'assets/windows/nap-cats', f.nap.row.imageFilename)));
  assert.equal(result.channels[0].activeCount, 1);
  assert.equal(result.channels[1].history[0].id, 'nap');
});
test('expired previous catalog can recover without reviving expired photos', async () => {
  const f = await fixture();
  await assets(path.join(f.previous, 'assets'), 'official-cats', [f.old], { generatedAt: utc(now - 2 * 86400_000), validUntil: utc(now - 1000),
    photos: [{ ...f.old.row, publishedAt: utc(now - 3 * 86400_000), expiresAt: utc(now - 1000) }] });
  const result = await prepareUpdate(f.previous, plan([]), f.output);
  assert.equal(result.channels[0].activeCount, 0); assert.deepEqual(result.channels[0].expired, ['old']);
});
test('rejects same photo bytes under a new ID instead of inventing a new arrival', async () => {
  const f = await fixture(), extra = path.join(f.root, 'extra');
  await assets(extra, 'nap-cats', [{ bytes: f.nap.bytes, row: { ...f.nap.row, id: 'renamed', publishedAt: utc(now - 1000) } }], { generatedAt: utc(now - 1000) });
  await assert.rejects(prepareUpdate(f.previous, plan([{ channelID: 'nap-cats', addAssets: extra }]), f.output), /cannot be presented as new/);
  await assert.rejects(access(f.output));
});
test('withdrawn publication remains in history and cannot reappear as a new ID', async () => {
  const f = await fixture();
  const first = await prepareUpdate(f.previous, plan([{ channelID: 'nap-cats', withdraw: ['nap'] }]), f.output);
  const extra = path.join(f.root, 'extra');
  await assets(extra, 'nap-cats', [{ bytes: f.nap.bytes, row: { ...f.nap.row, id: 'renamed', publishedAt: utc(now + 1000) } }], { generatedAt: utc(now + 1000) });
  await assert.rejects(prepareUpdate(first.bundle, plan([{ channelID: 'nap-cats', addAssets: extra }], false), path.join(f.root, 'second'), now + 2000), /cannot be presented as new/);
});
test('rejects old IDs with substituted content, even when hash is new', async () => {
  const f = await fixture(), extra = path.join(f.root, 'extra');
  const replacement = photo('different', 'nap-cats', { id: 'nap', publishedAt: utc(now - 1000) });
  await assets(extra, 'nap-cats', [replacement], { generatedAt: utc(now - 1000) });
  await assert.rejects(prepareUpdate(f.previous, plan([{ channelID: 'nap-cats', addAssets: extra }]), f.output), /cannot be presented as new/);
});
for (const [name, channels] of [
  ['unknown channel', [{ channelID: 'wrong' }]],
  ['duplicate channel', [{ channelID: 'nap-cats' }, { channelID: 'nap-cats' }]],
  ['unknown photo', [{ channelID: 'nap-cats', withdraw: ['missing'] }]],
  ['pause and add', [{ channelID: 'nap-cats', paused: true, withdraw: ['nap'] }]],
  ['over fourteen days', [{ channelID: 'nap-cats', renewPhotos: [{ id: 'nap', expiresAt: utc(now + 15 * 86400_000) }] }]],
  ['unknown key', [{ channelID: 'nap-cats', publish: true }]],
]) test(`rejects ${name} before creating output`, async () => {
  const f = await fixture();
  await assert.rejects(prepareUpdate(f.previous, plan(channels), f.output));
  await assert.rejects(access(f.output));
});
test('does not overwrite an existing candidate or put output inside source', async () => {
  const f = await fixture();
  await mkdir(f.output);
  await assert.rejects(prepareUpdate(f.previous, plan([]), f.output), /EEXIST/);
  await assert.rejects(prepareUpdate(f.previous, plan([]), path.join(f.previous, 'child')), /outside input/);
});
test('bad JPEG or unknown file stops the whole multi-channel update', async () => {
  const f = await fixture();
  await writeFile(path.join(f.previous, 'assets/windows/nap-cats', f.nap.row.imageFilename), 'broken');
  await assert.rejects(prepareUpdate(f.previous, plan([]), f.output), /JPEG/);
  await assert.rejects(access(f.output));
});
test('missing history needs explicit first migration; existing history cannot be reset', async () => {
  const f = await fixture();
  await assert.rejects(prepareUpdate(f.previous, plan([], false), f.output), /history is required/);
  const first = await prepareUpdate(f.previous, plan([]), f.output);
  await assert.rejects(prepareUpdate(first.bundle, plan([]), path.join(f.root, 'second'), now + 2000), /Cannot bootstrap/);
});
test('near photo expiry requires maintenance now instead of after the photos disappear', async () => {
  const f = await fixture();
  await assets(path.join(f.previous, 'assets/windows/nap-cats'), 'nap-cats', [f.nap], {
    photos: [{ ...f.nap.row, expiresAt: utc(now + 3600_000) }] });
  const result = await prepareUpdate(f.previous, plan([]), f.output, now);
  assert.equal(result.maintenanceDueAt, utc(now));
});
