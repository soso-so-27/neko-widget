import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, access, unlink, symlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { prepareMaintenance } from '../tools/prepare_maintenance.mjs';

const HOUR = 3600_000, DAY = 24 * HOUR;
const now = Math.floor(Date.now() / 1000) * 1000;
const utc = value => new Date(value).toISOString().replace('.000Z', 'Z');
const read = filename => readFile(filename, 'utf8').then(JSON.parse);
const queue = (...items) => ({ schemaVersion: 1, items });
// Four known, metadata-free 1x1 grayscale JPEGs (Pillow, quality 80, optimized).
// Committed bytes keep runtime tests independent of Python/Pillow.
const JPEG = [
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP7//2Q==',
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAB//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKn//2Q==',
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP//Z',
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAB//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVX//2Q==',
].map(value => Buffer.from(value, 'base64'));
function photo(id) {
  const bytes = Buffer.from(JPEG[id === 'old-official-cats' ? 0 : id === 'old-nap-cats' ? 1 : id === 'expired' ? 3 : 2]);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  return { bytes, metadata: { id, catID: 'cat', catName: '猫', credit: '合成テスト',
    caption: '確認用', sha256, imageFilename: sha256 + '.jpg', width: 1, height: 1 } };
}
async function fixture(changes = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'neko-maintenance-'));
  const previous = path.join(root, 'previous'), imageRoot = path.join(root, 'queue-images');
  await mkdir(imageRoot);
  const channels = [], catalogs = {};
  for (const id of ['official-cats', 'nap-cats']) {
    const source = photo('old-' + id);
    const original = { ...source.metadata, publishedAt: utc(now - 2 * DAY), expiresAt: utc(now + 5 * DAY) };
    const options = changes[id] ?? {};
    const catalog = { schemaVersion: 1, channelID: id, enabled: true,
      generatedAt: utc(now - HOUR), validUntil: utc(now + 47 * HOUR), photos: [original], ...options };
    const location = id === 'official-cats' ? path.join(previous, 'assets') : path.join(previous, 'assets/windows', id);
    await mkdir(location, { recursive: true });
    if (catalog.photos.length) await writeFile(path.join(location, source.metadata.imageFilename), source.bytes);
    await writeFile(path.join(location, 'catalog.json'), JSON.stringify(catalog));
    catalogs[id] = catalog;
    channels.push({ channelID: id, enabled: catalog.enabled, history: [original] });
  }
  const record = { schemaVersion: 1, generatedAt: catalogs['official-cats'].generatedAt, channels };
  await writeFile(path.join(previous, 'update-record.json'), JSON.stringify(record));
  return { root, previous, imageRoot, record, catalogs, output: path.join(root, 'candidate') };
}
async function item(f, id = 'new-photo', options = {}) {
  const image = photo(id), imagePath = path.join(f.imageRoot, image.metadata.imageFilename);
  await writeFile(imagePath, image.bytes);
  return { id, channels: ['official-cats', 'nap-cats'], scheduledAt: utc(now - HOUR),
    approvedUntil: utc(now + 10 * DAY), imagePath, photo: image.metadata, approved: true, ...options };
}
async function replaceImage(f, entry, bytes) {
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const photo = { ...entry.photo, sha256, imageFilename: sha256 + '.jpg' };
  const imagePath = path.join(f.imageRoot, photo.imageFilename);
  await writeFile(imagePath, bytes);
  return { ...entry, imagePath, photo };
}
const catalogPath = (bundle, channel) => path.join(bundle, 'assets', channel === 'official-cats' ? '' : 'windows/' + channel, 'catalog.json');

test('future queue causes no output and reports next action and remaining supply', async () => {
  const f = await fixture(), future = await item(f, 'future', { scheduledAt: utc(now + 2 * HOUR) });
  const result = await prepareMaintenance(f.previous, queue(future), f.output, now);
  assert.equal(result.status, 'no-change');
  assert.equal(result.nextActionAt, future.scheduledAt);
  assert.equal(result.queue.remainingCount, 1);
  assert.equal(result.queue.remainingAfterCandidate, 1);
  assert.equal(result.queue.earliestApprovalExpiry, future.approvedUntil);
  await assert.rejects(access(f.output));
});

test('due photo reaches both channels with one actual publication time and keeps old identities', async () => {
  const f = await fixture(), due = await item(f, 'due', { scheduledAt: utc(now - 3 * DAY) });
  const result = await prepareMaintenance(f.previous, queue(due), f.output, now);
  assert.equal(result.status, 'candidate-prepared');
  for (const channel of due.channels) {
    const catalog = await read(catalogPath(result.bundle, channel));
    const added = catalog.photos.find(photo => photo.id === due.id);
    assert.equal(added.publishedAt, utc(now));
    assert.equal(added.expiresAt, utc(now + 7 * DAY));
    assert.deepEqual(catalog.photos.find(photo => photo.id !== due.id), f.catalogs[channel].photos[0]);
  }
  assert.equal(result.queue.remainingAfterCandidate, 0);
  assert.deepEqual(await read(path.join(f.previous, 'update-record.json')), f.record);
  await assert.rejects(access(path.join(result.bundle, 'assets', 'maintenance-report.json')));
});

test('late heartbeats select one image by schedule then ID and leave the other for the next candidate', async t => {
  t.mock.method(Date, 'now', () => now + 1000);
  for (const equalSchedule of [false, true]) {
    const f = await fixture();
    const later = await item(f, 'z-later', { scheduledAt: utc(now - HOUR) });
    const earlier = await replaceImage(f, await item(f, 'a-earlier', {
      scheduledAt: utc(now - (equalSchedule ? 1 : 2) * HOUR),
    }), JPEG[3]);
    const queued = queue(later, earlier); // Input order must not select the winner.
    const first = await prepareMaintenance(f.previous, queued, f.output, now);
    assert.deepEqual([...new Set(first.queue.items.filter(row => row.status === 'selected').map(row => row.id))], [earlier.id]);
    assert.equal(first.queue.items.filter(row => row.status === 'deferred').length, 2);
    assert.equal(first.queue.remainingAfterCandidate, 1);
    for (const channel of earlier.channels) {
      assert.equal((await read(catalogPath(first.bundle, channel))).photos.some(photo => photo.id === later.id), false);
    }
    const second = await prepareMaintenance(first.bundle, queued, path.join(f.root, 'next'), now + 1000);
    assert.deepEqual([...new Set(second.queue.items.filter(row => row.status === 'selected').map(row => row.id))], [later.id]);
    assert.equal(second.queue.remainingAfterCandidate, 0);
    for (const channel of earlier.channels) {
      const photos = (await read(catalogPath(second.bundle, channel))).photos;
      assert.equal(photos.find(photo => photo.id === earlier.id).publishedAt, utc(now));
      assert.equal(photos.find(photo => photo.id === later.id).publishedAt, utc(now + 1000));
    }
  }
});

test('correctly hashed future JPEGs reject APP1 through APP15 and COM, including after a scan', async () => {
  const f = await fixture(), future = await item(f, 'future', { scheduledAt: utc(now + HOUR) });
  const original = JPEG[2], markers = [...Array.from({ length: 15 }, (_, index) => 0xe1 + index), 0xfe];
  for (const marker of markers) {
    const segment = Buffer.concat([Buffer.from([255, marker, 0, 10]), Buffer.from('Exif\0GPS', 'ascii')]);
    for (const position of [2, original.length - 2]) {
      const bytes = Buffer.concat([original.subarray(0, position), segment, original.subarray(position)]);
      const changed = await replaceImage(f, future, bytes);
      await assert.rejects(prepareMaintenance(f.previous, queue(changed), f.output, now), /metadata segment/);
    }
  }
  await assert.rejects(access(f.output));
});

test('JPEG header guard rejects non-JFIF APP0, thumbnails, broken segment lengths and dimension mismatch', async () => {
  const f = await fixture(), future = await item(f, 'future', { scheduledAt: utc(now + HOUR) });
  for (const [offset, value, error] of [[6, 88, /JFIF/], [18, 1, /JFIF/], [19, 1, /JFIF/], [5, 1, /segment length/], [4, 255, /segment length/]]) {
    const bytes = Buffer.from(JPEG[2]); bytes[offset] = value;
    await assert.rejects(prepareMaintenance(f.previous, queue(await replaceImage(f, future, bytes)), f.output, now), error);
  }
  await assert.rejects(prepareMaintenance(f.previous, queue({ ...future, photo: { ...future.photo, width: 2 } }), f.output, now), /SOF dimensions/);
  await assert.rejects(access(f.output));
});

test('photo expiry is capped by approval and expired approvals are reported without publication', async () => {
  const f = await fixture();
  const due = await item(f, 'short', { approvedUntil: utc(now + HOUR) });
  const expired = await item(f, 'expired', { scheduledAt: utc(now - 2 * HOUR), approvedUntil: utc(now) });
  const result = await prepareMaintenance(f.previous, queue(due, expired), f.output, now);
  const photos = (await read(catalogPath(result.bundle, 'nap-cats'))).photos;
  assert.equal(photos.find(photo => photo.id === due.id).expiresAt, due.approvedUntil);
  assert.equal(photos.some(photo => photo.id === expired.id), false);
  assert.equal(result.queue.expiredCount, 1);
  assert.equal(result.nextActionAt, due.approvedUntil);
});

test('deployed update history makes a repeated heartbeat no-change without republishing', async () => {
  const f = await fixture(), due = await item(f);
  const first = await prepareMaintenance(f.previous, queue(due), f.output, now);
  const output = path.join(f.root, 'again');
  const second = await prepareMaintenance(first.bundle, queue(due), output, now + 1000);
  assert.equal(second.status, 'no-change');
  assert.ok(second.queue.items.every(row => row.status === 'already-published'));
  assert.equal(second.queue.remainingCount, 0);
  await assert.rejects(access(output));
});

test('withdrawn and paused history never automatically becomes a new photo', async () => {
  const f = await fixture({ 'official-cats': { photos: [] }, 'nap-cats': { enabled: false, photos: [] } });
  const original = photo('old-official-cats');
  const due = await item(f, 'old-official-cats', { channels: ['official-cats'], photo: original.metadata });
  const stopped = await item(f, 'old-nap-cats', { channels: ['nap-cats'] });
  const result = await prepareMaintenance(f.previous, queue(due, stopped), f.output, now);
  assert.equal(result.status, 'no-change');
  assert.ok(result.queue.items.every(row => row.status === 'already-published'));
  await assert.rejects(access(f.output));
});

test('a renamed copy with historical bytes is not presented as new', async () => {
  const f = await fixture({ 'official-cats': { photos: [] } });
  const original = photo('old-official-cats');
  const imagePath = path.join(f.imageRoot, original.metadata.imageFilename);
  await writeFile(imagePath, original.bytes);
  const renamed = { id: 'renamed', channels: ['official-cats'], scheduledAt: utc(now - HOUR),
    approvedUntil: utc(now + DAY), imagePath, approved: true, photo: { ...original.metadata, id: 'renamed' } };
  const result = await prepareMaintenance(f.previous, queue(renamed), f.output, now);
  assert.equal(result.status, 'no-change');
  assert.equal(result.queue.items[0].status, 'already-published');
});

test('new queued photos do not resume a paused channel or prevent the other channel receiving', async () => {
  const f = await fixture({ 'nap-cats': { enabled: false, photos: [] } }), due = await item(f);
  const result = await prepareMaintenance(f.previous, queue(due), f.output, now);
  const paused = await read(catalogPath(result.bundle, 'nap-cats'));
  assert.equal(paused.enabled, false); assert.deepEqual(paused.photos, []);
  assert.equal((await read(catalogPath(result.bundle, 'official-cats'))).photos[0].id, due.id);
  assert.equal(result.queue.items.find(row => row.channelID === 'nap-cats').status, 'paused');
});

test('catalog remaining exactly 24h triggers maintenance without extending photo lifetime', async () => {
  const f = await fixture({ 'official-cats': { validUntil: utc(now + DAY) } });
  const result = await prepareMaintenance(f.previous, queue(), f.output, now);
  assert.equal(result.status, 'candidate-prepared');
  for (const id of ['official-cats', 'nap-cats']) {
    const next = await read(catalogPath(result.bundle, id));
    assert.equal(next.validUntil, utc(now + 48 * HOUR));
    assert.deepEqual(next.photos, f.catalogs[id].photos);
  }
  assert.deepEqual(result.reasons, [{ channelID: 'official-cats', reason: 'catalog-renewal' }]);
});

test('expired current photos trigger eviction while keeping their publication history', async () => {
  const f = await fixture();
  f.catalogs['official-cats'].photos[0].expiresAt = utc(now);
  await writeFile(catalogPath(f.previous, 'official-cats'), JSON.stringify(f.catalogs['official-cats']));
  const result = await prepareMaintenance(f.previous, queue(), f.output, now);
  assert.deepEqual((await read(catalogPath(result.bundle, 'official-cats'))).photos, []);
  const record = await read(path.join(result.bundle, 'update-record.json'));
  assert.equal(record.channels[0].history[0].id, 'old-official-cats');
  assert.equal((await read(catalogPath(result.bundle, 'nap-cats'))).photos.length, 1);
});

test('missing or conflicting publication history blocks even an otherwise no-change run', async () => {
  const f = await fixture(), filename = path.join(f.previous, 'update-record.json');
  await unlink(filename);
  await assert.rejects(prepareMaintenance(f.previous, queue(), f.output, now), /ENOENT/);
  f.record.channels[0].history[0].sha256 = 'a'.repeat(64);
  await writeFile(filename, JSON.stringify(f.record));
  await assert.rejects(prepareMaintenance(f.previous, queue(), f.output, now), /missing from publication history/);
  await assert.rejects(access(f.output));
});

test('future entries still require approval, bounded metadata, valid times and exact local bytes', async () => {
  const f = await fixture(), future = await item(f, 'future', { scheduledAt: utc(now + HOUR) });
  const variants = [
    { ...future, approved: false }, { ...future, channels: ['unknown'] },
    { ...future, channels: ['nap-cats', 'nap-cats'] }, { ...future, imagePath: 'relative.jpg' },
    { ...future, approvedUntil: future.scheduledAt }, { ...future, scheduledAt: '2026-02-30T09:00:00Z' },
    { ...future, photo: { ...future.photo, width: 2049 } },
    { ...future, photo: { ...future.photo, publishedAt: utc(now) } },
    { ...future, extra: true }, { ...future, id: 'wrong-id' },
  ];
  for (const invalid of variants) await assert.rejects(prepareMaintenance(f.previous, queue(invalid), f.output, now));
  await writeFile(future.imagePath, Buffer.from([255, 216, 0, 255, 217]));
  await assert.rejects(prepareMaintenance(f.previous, queue(future), f.output, now), /hash mismatch/);
  await assert.rejects(access(f.output));
});

test('duplicate queue identities or JPEGs are rejected before output', async () => {
  const f = await fixture(), first = await item(f);
  await assert.rejects(prepareMaintenance(f.previous, queue(first, first), f.output, now));
  const renamed = { ...first, id: 'renamed', photo: { ...first.photo, id: 'renamed' } };
  await assert.rejects(prepareMaintenance(f.previous, queue(first, renamed), f.output, now), /duplicated/);
  await assert.rejects(access(f.output));
});

test('historical photo IDs cannot be substituted with different JPEGs', async () => {
  const f = await fixture(), altered = await item(f, 'different');
  altered.id = 'old-official-cats'; altered.photo.id = altered.id;
  await assert.rejects(prepareMaintenance(f.previous, queue(altered), f.output, now), /different bytes/);
  await assert.rejects(access(f.output));
});

test('existing output, source descendants and symlinked asset directories are rejected', async () => {
  const f = await fixture(), due = await item(f);
  await mkdir(f.output);
  await assert.rejects(prepareMaintenance(f.previous, queue(due), f.output, now), /already exists/);
  await assert.rejects(prepareMaintenance(f.previous, queue(due), path.join(f.previous, 'child'), now), /outside/);
  const link = path.join(f.root, 'image-link');
  await symlink(f.imageRoot, link, process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(prepareMaintenance(f.previous, queue({ ...due, imagePath: path.join(link, due.photo.imageFilename) }),
    path.join(f.root, 'other'), now), /regular local directory/);
});

test('same-second editions defer without creating an invalid generatedAt collision', async () => {
  const f = await fixture(), due = await item(f);
  f.record.generatedAt = utc(now);
  for (const id of ['official-cats', 'nap-cats']) {
    f.catalogs[id].generatedAt = utc(now);
    await writeFile(catalogPath(f.previous, id), JSON.stringify(f.catalogs[id]));
  }
  await writeFile(path.join(f.previous, 'update-record.json'), JSON.stringify(f.record));
  const result = await prepareMaintenance(f.previous, queue(due), f.output, now);
  assert.equal(result.status, 'no-change');
  assert.equal(result.nextActionAt, utc(now + 1000));
  assert.equal(result.deferredReason, 'edition-must-advance');
  assert.equal(result.queue.remainingAfterCandidate, 1);
  await assert.rejects(access(f.output));
});

test('scheduled boundary uses the same clock as the existing bundle validator', async t => {
  const f = await fixture(), scheduled = now + 2 * HOUR;
  const future = await item(f, 'scheduled', { scheduledAt: utc(scheduled) });
  t.mock.method(Date, 'now', () => scheduled - 1000);
  const before = await prepareMaintenance(f.previous, queue(future), f.output, scheduled - 1000);
  assert.equal(before.status, 'no-change');
  Date.now.mock.mockImplementation(() => scheduled);
  const due = await prepareMaintenance(f.previous, queue(future), f.output, scheduled);
  assert.equal(due.status, 'candidate-prepared');
  assert.equal((await read(catalogPath(due.bundle, 'nap-cats'))).photos[0].publishedAt, utc(scheduled));
});

test('downstream validation failure leaves the partial output without altering the previous record', async () => {
  const f = await fixture(), due = await item(f);
  await writeFile(path.join(f.previous, 'assets', f.catalogs['official-cats'].photos[0].imageFilename), 'broken');
  await assert.rejects(prepareMaintenance(f.previous, queue(due), f.output, now), /JPEG/);
  await access(f.output);
  assert.deepEqual(await read(path.join(f.previous, 'update-record.json')), f.record);
  await assert.rejects(access(path.join(f.output, 'maintenance-report.json')));
  await assert.rejects(prepareMaintenance(f.previous, queue(due), f.output, now), /already exists/);
});
