import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker, { activeFiles } from '../src/index.js';

const utc = value => new Date(value).toISOString().replace('.000Z', 'Z');
const now = Math.floor(Date.now() / 1000) * 1000;
const bytes = new Uint8Array([255, 216, 255, 217]);
const hash = createHash('sha256').update(bytes).digest('hex');
const filename = `${hash}.jpg`;
function catalog() {
  return { schemaVersion: 1, channelID: 'official-cats', enabled: true, generatedAt: utc(now - 1000), validUntil: utc(now + 3600_000), photos: [{
    id: 'test-a', catID: 'test-cat', catName: 'テスト猫', credit: '合成テスト用', caption: 'テスト\n画像',
    publishedAt: utc(now - 1000), expiresAt: utc(now + 3600_000), imageFilename: filename, sha256: hash, width: 1, height: 1,
  }] };
}
function environment(value = catalog(), extra = {}) {
  const assets = new Map([['/catalog.json', JSON.stringify(value)], [`/${filename}`, bytes], ...Object.entries(extra)]);
  const calls = [];
  return { calls, assets, OFFICIAL_ASSETS: { async fetch(request) {
    calls.push(request);
    const body = assets.get(new URL(request.url).pathname);
    return new Response(body ?? 'missing', { status: body === undefined ? 404 : 200 });
  } } };
}
const fetch = (pathname, env, init) => worker.fetch(new Request(`https://official.example${pathname}`, init), env);

function addChannel(env, id, value = catalog()) {
  value.channelID = id;
  env.assets.set(`/windows/${id}/catalog.json`, JSON.stringify(value));
  env.assets.set(`/windows/${id}/${filename}`, bytes);
  return value;
}

test('serves the current catalog and matching JPEG without caching', async () => {
  const env = environment();
  assert.equal((await fetch('/catalog.json', env)).status, 200);
  const response = await fetch(`/${filename}`, env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'image/jpeg');
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes);
});
test('withdrawal blocks an old JPEG even if the asset binding still has it', async () => {
  const value = catalog(); value.photos = [];
  const env = environment(value);
  assert.equal((await fetch(`/${filename}`, env)).status, 404);
  assert.equal(env.calls.length, 1);
});
test('a paused catalog remains readable but all old pictures stop', async () => {
  const value = catalog(); value.enabled = false; value.photos = [];
  const env = environment(value);
  assert.equal((await (await fetch('/catalog.json', env)).json()).enabled, false);
  assert.equal((await fetch(`/${filename}`, env)).status, 404);
});
test('expired or future photos cannot be fetched directly', async () => {
  const expired = catalog(); expired.photos[0].expiresAt = utc(now);
  assert.equal((await fetch(`/${filename}`, environment(expired))).status, 404);
  const future = catalog(); future.generatedAt = utc(now + 120_000); future.photos[0].publishedAt = future.generatedAt;
  assert.equal((await fetch(`/${filename}`, environment(future))).status, 404);
});
test('stale, invalid and conflicting catalog data fail without serving images', async () => {
  for (const change of [
    value => { value.validUntil = utc(now); },
    value => { value.generatedAt = utc(now + 301_000); },
    value => { value.photos.push(value.photos[0]); },
    value => { value.photos[0].internal = { private: 'not-for-publication' }; },
    value => { value.photos[0].photographedOn = '2026-02-30'; },
    value => { value.photos[0].expiresAt = utc(now + 15 * 86400_000); },
  ]) {
    const value = catalog(); change(value);
    const response = await fetch(`/${filename}`, environment(value));
    assert.equal(response.status, 503);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.ok(!(await response.text()).includes('not-for-publication'));
  }
});
test('unknown paths, alternate spellings and query strings never reach assets', async () => {
  const env = environment();
  for (const pathname of ['/source.json', '/_headers', '/catalog.json?x=1', '/%63atalog.json', '/CATALOG.JSON', '/']) assert.equal((await fetch(pathname, env)).status, 404);
  assert.equal(env.calls.length, 0);
});
test('write methods are refused, HEAD has no body, input headers are not forwarded', async () => {
  const env = environment();
  assert.equal((await fetch('/catalog.json', env, { method: 'POST' })).status, 405);
  const response = await fetch('/catalog.json', env, { method: 'HEAD', headers: { Cookie: 'private=1', Authorization: 'Bearer example', Range: 'bytes=0-1' } });
  assert.equal(response.status, 200); assert.equal(await response.text(), '');
  assert.equal([...env.calls[0].headers].length, 0);
});
test('an unavailable, oversized or corrupt asset is never substituted', async () => {
  for (const replacement of [undefined, 'wrong image', new Uint8Array(4 * 1024 * 1024 + 1)]) {
    const env = environment();
    if (replacement === undefined) env.assets.delete(`/${filename}`); else env.assets.set(`/${filename}`, replacement);
    assert.equal((await fetch(`/${filename}`, env)).status, 503);
  }
  const env = environment(); env.assets.set('/catalog.json', new Uint8Array(256 * 1024 + 1));
  assert.equal((await fetch('/catalog.json', env)).status, 503);
});
test('catalog upper limits and astral Unicode follow the publisher contract', () => {
  const value = catalog(); value.photos[0].catName = 'ねこ🐈';
  assert.deepEqual([...activeFiles(value, now)], [filename]);
  value.validUntil = utc(now - 1000 + 48 * 3600_000 + 1000);
  assert.throws(() => activeFiles(value, now));
});
test('a deadline crossed during image I/O prevents the final image response', async t => {
  let clock = now;
  t.mock.method(Date, 'now', () => clock);
  for (const catalogExpires of [false, true]) {
    clock = now;
    const value = catalog();
    if (catalogExpires) value.validUntil = utc(now + 1000); else value.photos[0].expiresAt = utc(now + 1000);
    const env = environment(value), underlying = env.OFFICIAL_ASSETS.fetch;
    env.OFFICIAL_ASSETS.fetch = async request => {
      const result = await underlying(request);
      if (new URL(request.url).pathname === `/${filename}`) clock = now + 2000;
      return result;
    };
    assert.equal((await fetch(`/${filename}`, env)).status, catalogExpires ? 503 : 404);
  }
});

test('channels isolate matching photo IDs and hashes, including a stopped channel', async () => {
  const env = environment();
  const a = addChannel(env, 'window-a'), b = addChannel(env, 'window-b');
  for (const [prefix, id] of [['', 'official-cats'], ['/windows/window-a', 'window-a'], ['/windows/window-b', 'window-b']]) {
    assert.equal((await (await fetch(`${prefix}/catalog.json`, env)).json()).channelID, id);
    const response = await fetch(`${prefix}/${filename}`, env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes);
  }
  a.enabled = false; a.photos = [];
  addChannel(env, 'window-a', a);
  assert.equal((await (await fetch('/windows/window-a/catalog.json', env)).json()).enabled, false);
  assert.equal((await fetch(`/windows/window-a/${filename}`, env)).status, 404);
  assert.deepEqual(await (await fetch('/windows/window-b/catalog.json', env)).json(), b);
  assert.equal((await fetch(`/windows/window-b/${filename}`, env)).status, 200);
  assert.equal((await fetch(`/${filename}`, env)).status, 200);
});

test('missing, withdrawn or mismatched channel data never falls back to another channel', async () => {
  const env = environment();
  addChannel(env, 'window-a'); addChannel(env, 'window-b');
  env.assets.delete(`/windows/window-a/${filename}`);
  assert.equal((await fetch(`/windows/window-a/${filename}`, env)).status, 503);
  const withdrawn = catalog(); withdrawn.photos = [];
  addChannel(env, 'window-a', withdrawn);
  assert.equal((await fetch(`/windows/window-a/${filename}`, env)).status, 404);
  env.assets.set('/windows/window-a/catalog.json', env.assets.get('/windows/window-b/catalog.json'));
  for (const suffix of ['catalog.json', filename]) assert.equal((await fetch(`/windows/window-a/${suffix}`, env)).status, 503);
  env.assets.set('/catalog.json', env.assets.get('/windows/window-b/catalog.json'));
  assert.equal((await fetch('/catalog.json', env)).status, 503);
  assert.equal((await fetch('/windows/unknown/catalog.json', env)).status, 503);
  assert.equal((await fetch(`/windows/window-b/${filename}`, env)).status, 200);
});

test('channel paths reject aliases, traversal spellings and private files before asset access', async () => {
  const env = environment();
  for (const pathname of [
    '/windows/official-cats/catalog.json', '/windows/UPPER/catalog.json', `/windows/${'a'.repeat(65)}/catalog.json`,
    '/windows/a%2fb/catalog.json', '/windows/%2e%2e%2f/catalog.json', '/windows/window-a/source.json',
    '/windows/window-a/catalog.json?x=1', '/windows/window-a/%63atalog.json', '/windows/window-a/',
  ]) assert.equal((await fetch(pathname, env)).status, 404, pathname);
  assert.equal(env.calls.length, 0);
});

test('channel asset redirects are rejected without forwarding input headers', async () => {
  for (const redirectCatalog of [true, false]) {
    const env = environment(); addChannel(env, 'window-a');
    const underlying = env.OFFICIAL_ASSETS.fetch;
    env.OFFICIAL_ASSETS.fetch = async request => {
      assert.equal(request.redirect, 'manual');
      assert.equal([...request.headers].length, 0);
      if (new URL(request.url).pathname.endsWith(redirectCatalog ? '/catalog.json' : `/${filename}`)) {
        return new Response(null, { status: 302, headers: { Location: `https://other.example/${filename}` } });
      }
      return underlying(request);
    };
    assert.equal((await fetch(`/windows/window-a/${filename}`, env, { headers: { Cookie: 'private=1' } })).status, 503);
  }
});

test('channel image reply rechecks photo and catalog deadlines independently', async t => {
  let clock = now;
  t.mock.method(Date, 'now', () => clock);
  for (const catalogExpires of [false, true]) {
    clock = now;
    const env = environment(), a = catalog();
    if (catalogExpires) a.validUntil = utc(now + 1000); else a.photos[0].expiresAt = utc(now + 1000);
    addChannel(env, 'window-a', a); addChannel(env, 'window-b');
    const underlying = env.OFFICIAL_ASSETS.fetch;
    env.OFFICIAL_ASSETS.fetch = async request => {
      const result = await underlying(request);
      if (new URL(request.url).pathname === `/windows/window-a/${filename}`) clock = now + 2000;
      return result;
    };
    assert.equal((await fetch(`/windows/window-a/${filename}`, env)).status, catalogExpires ? 503 : 404);
    assert.equal((await fetch(`/windows/window-b/${filename}`, env)).status, 200);
  }
});
