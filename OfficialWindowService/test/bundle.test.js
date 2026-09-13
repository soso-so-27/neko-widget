import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { prepareBundle, feedSetting } from '../tools/prepare_bundle.mjs';

async function input() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'official-bundle-'));
  const source = path.join(root, 'input'); await mkdir(source);
  const now = Math.floor(Date.now() / 1000) * 1000, utc = value => new Date(value).toISOString().replace('.000Z', 'Z');
  const bytes = new Uint8Array([255, 216, 255, 217]), hash = createHash('sha256').update(bytes).digest('hex'), filename = `${hash}.jpg`;
  const catalog = { schemaVersion: 1, channelID: 'official-cats', enabled: true, generatedAt: utc(now), validUntil: utc(now + 3600_000), photos: [{
    id: 'test-a', catID: 'test-cat', catName: 'テスト', credit: '合成テスト', publishedAt: utc(now), expiresAt: utc(now + 3600_000), imageFilename: filename, sha256: hash, width: 1, height: 1,
  }] };
  await writeFile(path.join(source, 'catalog.json'), JSON.stringify(catalog)); await writeFile(path.join(source, filename), bytes);
  return { root, source, filename, catalog, output: path.join(root, 'review') };
}
async function cleanup(root) {
  const target = path.resolve(root);
  assert.equal(path.dirname(target), path.resolve(os.tmpdir()));
  assert.ok(path.basename(target).startsWith('official-bundle-'));
  await rm(target, { recursive: true, force: true });
}
async function additionalInput(fixture, name, channelID, paused = false) {
  const source = path.join(fixture.root, name); await mkdir(source);
  const catalog = structuredClone(fixture.catalog); catalog.channelID = channelID;
  if (paused) { catalog.enabled = false; catalog.photos = []; }
  await writeFile(path.join(source, 'catalog.json'), JSON.stringify(catalog));
  if (!paused) await writeFile(path.join(source, fixture.filename), await readFile(path.join(fixture.source, fixture.filename)));
  return source;
}
test('prepares a local bundle whose upload directory contains only catalog and JPEGs', async () => {
  const fixture = await input();
  try {
    const result = await prepareBundle(fixture.source, fixture.output, 'https://official.example/catalog.json');
    assert.equal(result.photos, 1);
    assert.deepEqual((await readdir(path.join(fixture.output, 'assets'))).sort(), [fixture.filename, 'catalog.json'].sort());
    const config = JSON.parse(await readFile(path.join(fixture.output, 'wrangler.jsonc'), 'utf8'));
    assert.equal(config.assets.directory, './assets'); assert.equal(config.assets.run_worker_first, true);
    assert.equal(config.main, './worker.js'); assert.ok((await readFile(path.join(fixture.output, config.main))).length > 0);
    assert.equal(config.assets.not_found_handling, 'none'); assert.equal(config.preview_urls, false);
    assert.match(await readFile(path.join(fixture.output, 'OfficialWindow.xcconfig'), 'utf8'), /https:\/\$\(\)\/official\.example\/catalog\.json/);
    await assert.rejects(prepareBundle(fixture.source, fixture.output), /already exists/);
  } finally { await cleanup(fixture.root); }
});
test('rejects stray private input files and checksum errors before creating output', async () => {
  const fixture = await input();
  try {
    await writeFile(path.join(fixture.source, 'source.json'), '{"private":true}');
    await assert.rejects(prepareBundle(fixture.source, fixture.output), /only catalog/);
    assert.deepEqual((await readdir(fixture.root)).sort(), ['input']);
    await rm(path.join(fixture.source, 'source.json'));
    await writeFile(path.join(fixture.source, fixture.filename), 'wrong file');
    await assert.rejects(prepareBundle(fixture.source, fixture.output), /checksum/);
  } finally { await cleanup(fixture.root); }
});
test('stale editions and nested output cannot produce a bundle', async () => {
  const fixture = await input();
  try {
    await assert.rejects(prepareBundle(fixture.source, path.join(fixture.source, 'out')), /outside/);
    fixture.catalog.validUntil = fixture.catalog.generatedAt;
    await writeFile(path.join(fixture.source, 'catalog.json'), JSON.stringify(fixture.catalog));
    await assert.rejects(prepareBundle(fixture.source, fixture.output), /Invalid/);
  } finally { await cleanup(fixture.root); }
});
test('build configuration accepts only the native feed URL shape', () => {
  for (const value of ['http://official.example/catalog.json', 'https://user:pass@official.example/catalog.json', 'https://official.example:8443/catalog.json', 'https://official.example/catalog.json?q=1', 'https://official.example/catalog.json#x', 'https://official.example/feed.json']) assert.throws(() => feedSetting(value));
});

test('multiple channels keep legacy files and duplicate photo IDs/hashes in separate directories', async () => {
  const fixture = await input();
  try {
    const a = await additionalInput(fixture, 'input-a', 'window-a');
    const b = await additionalInput(fixture, 'input-b', 'window-b');
    const result = await prepareBundle(fixture.source, fixture.output, undefined, [a, b]);
    assert.equal(result.photos, 1);
    assert.deepEqual(result.additionalChannels.map(value => value.channelID), ['window-a', 'window-b']);
    for (const [folder, id] of [['', 'official-cats'], ['windows/window-a', 'window-a'], ['windows/window-b', 'window-b']]) {
      const directory = path.join(fixture.output, 'assets', folder);
      assert.deepEqual(JSON.parse(await readFile(path.join(directory, 'catalog.json'))), { ...fixture.catalog, channelID: id });
      assert.deepEqual(await readFile(path.join(directory, fixture.filename)), await readFile(path.join(fixture.source, fixture.filename)));
    }
    assert.deepEqual((await readdir(path.join(fixture.output, 'assets'))).sort(), [fixture.filename, 'catalog.json', 'windows'].sort());
    assert.deepEqual((await readdir(path.join(fixture.output, 'assets/windows'))).sort(), ['window-a', 'window-b']);
  } finally { await cleanup(fixture.root); }
});

test('additional channels reject duplicate IDs, legacy overwrite and invalid path slugs before output', async () => {
  const fixture = await input();
  try {
    const a = await additionalInput(fixture, 'input-a', 'window-a');
    await assert.rejects(prepareBundle(fixture.source, fixture.output, undefined, [a, a]), /Duplicate/);
    await assert.rejects(prepareBundle(fixture.source, fixture.output, undefined, [fixture.source]), /legacy/);
    for (const channelID of ['', '../escape', 'a/b', 'a\\b', 'a%2fb', 'UPPER', 'a'.repeat(65), 'window-a\n', null]) {
      await writeFile(path.join(a, 'catalog.json'), JSON.stringify({ ...fixture.catalog, channelID }));
      await assert.rejects(prepareBundle(fixture.source, fixture.output, undefined, [a]), /Invalid/);
    }
    assert.ok(!(await readdir(fixture.root)).includes('review'));
  } finally { await cleanup(fixture.root); }
});

test('all additional inputs retain file, checksum, expiry and output boundary checks', async () => {
  const fixture = await input();
  try {
    const a = await additionalInput(fixture, 'input-a', 'window-a');
    await assert.rejects(prepareBundle(fixture.source, path.join(a, 'nested'), undefined, [a]), /outside/);
    await writeFile(path.join(a, 'source.json'), '{"private":true}');
    await assert.rejects(prepareBundle(fixture.source, fixture.output, undefined, [a]), /only catalog/);
    await rm(path.join(a, 'source.json'));
    await writeFile(path.join(a, fixture.filename), 'wrong image');
    await assert.rejects(prepareBundle(fixture.source, fixture.output, undefined, [a]), /checksum/);
    await writeFile(path.join(a, fixture.filename), await readFile(path.join(fixture.source, fixture.filename)));
    for (const changes of [{ validUntil: fixture.catalog.generatedAt }, { photos: [{ ...fixture.catalog.photos[0], imageFilename: '../secret.jpg' }] }]) {
      await writeFile(path.join(a, 'catalog.json'), JSON.stringify({ ...fixture.catalog, channelID: 'window-a', ...changes }));
      await assert.rejects(prepareBundle(fixture.source, fixture.output, undefined, [a]), /Invalid/);
    }
    assert.ok(!(await readdir(fixture.root)).includes('review'));
  } finally { await cleanup(fixture.root); }
});

test('repeated additional-assets CLI arguments can stop A while preserving B and legacy', async () => {
  const fixture = await input();
  try {
    const a = await additionalInput(fixture, 'input-a', 'window-a', true);
    const b = await additionalInput(fixture, 'input-b', 'window-b');
    execFileSync(process.execPath, [fileURLToPath(new URL('../tools/prepare_bundle.mjs', import.meta.url)),
      '--assets', fixture.source, '--output', fixture.output, '--additional-assets', a, '--additional-assets', b]);
    const stopped = path.join(fixture.output, 'assets/windows/window-a');
    assert.deepEqual(await readdir(stopped), ['catalog.json']);
    const catalog = JSON.parse(await readFile(path.join(stopped, 'catalog.json')));
    assert.equal(catalog.enabled, false); assert.deepEqual(catalog.photos, []);
    for (const folder of ['', 'windows/window-b']) {
      const directory = path.join(fixture.output, 'assets', folder);
      assert.equal(JSON.parse(await readFile(path.join(directory, 'catalog.json'))).photos.length, 1);
      assert.deepEqual(await readFile(path.join(directory, fixture.filename)), await readFile(path.join(fixture.source, fixture.filename)));
    }
  } finally { await cleanup(fixture.root); }
});
