import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
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
