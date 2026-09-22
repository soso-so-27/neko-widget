import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createImageValidator } from '../dist/provider.js';
import { BODY_TIMEOUT_MS, MAX_BODY_CHUNKS, MAX_REQUEST_BYTES } from '../dist/limits.js';
import { jpeg, request, truncateEntropy } from './fixtures.mjs';

test('disabled by default; no body is consumed before activation', async () => {
  const req = request(await jpeg());
  assert.equal((await createImageValidator().fetch(req)).status, 503);
  assert.equal(req.bodyUsed, false);
});

test('returns exact binding contract and no photo or metadata; invalid pixels are false', async () => {
  const provider = createImageValidator({ enabled: true });
  const photo = await jpeg();
  const response = await provider.fetch(request(photo));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { valid: true, mediaType: 'image/jpeg', frames: 1 });
  const bad = await provider.fetch(request(truncateEntropy(photo)));
  assert.equal(bad.status, 200);
  assert.deepEqual(await bad.json(), { valid: false });
});

test('only the fixed POST JSON route is accepted', async () => {
  const provider = createImageValidator({ enabled: true });
  assert.equal((await provider.fetch(new Request('https://preservation-internal/images/validate-jpeg'))).status, 405);
  for (const path of ['/anything', '/images/validate-jpeg?source=https://example.com']) {
    assert.equal((await provider.fetch(new Request(`https://preservation-internal${path}`, { method: 'POST' }))).status, 404);
  }
  for (const headers of [{ 'content-type': 'image/jpeg' }, { 'content-type': 'application/json', 'content-encoding': 'gzip' }]) {
    assert.equal((await provider.fetch(request(await jpeg(), { headers }))).status, 400);
  }
});

test('rejects malformed JSON, noncanonical base64, extra fields and URLs', async () => {
  const provider = createImageValidator({ enabled: true });
  const photo = await jpeg();
  for (const value of [null, [], {}, { photoBase64: null }, { photoBase64: 'https://example.com/photo.jpg' },
    { photoBase64: 'AB==' }, { photoBase64: ' AA==' }, { photoBase64: 'AA=' },
    { photoBase64: photo.toString('base64'), ownerId: 'other-person' }]) {
    const response = await provider.fetch(request(photo, { body: JSON.stringify(value) }));
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: { code: 'INVALID_REQUEST' } });
  }
  for (const body of ['{', Buffer.from([0xff, 0xfe])]) {
    assert.equal((await provider.fetch(request(photo, { body }))).status, 400);
  }
});

test('does not trust Content-Length; bounds a chunked body and cancels it', async () => {
  const provider = createImageValidator({ enabled: true });
  let cancelled = false;
  const body = new ReadableStream({ pull(controller) { controller.enqueue(new Uint8Array(1024 * 1024)); },
    cancel() { cancelled = true; } });
  const response = await provider.fetch(new Request('https://preservation-internal/images/validate-jpeg', {
    method: 'POST', headers: { 'content-type': 'application/json', 'content-length': '1' }, body, duplex: 'half',
  }));
  assert.equal(response.status, 400); assert.equal(cancelled, true);
  const largeHeader = request(await jpeg(), { headers: {
    'content-type': 'application/json', 'content-length': String(MAX_REQUEST_BYTES + 1),
  } });
  assert.equal((await provider.fetch(largeHeader)).status, 400);
  assert.equal(largeHeader.bodyUsed, false);
});

test('one in-flight request including body read; cancellation releases capacity', async () => {
  const provider = createImageValidator({ enabled: true });
  const photo = await jpeg();
  const controller = new AbortController();
  const body = new ReadableStream({ start() {} });
  const held = provider.fetch(new Request('https://preservation-internal/images/validate-jpeg', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body, duplex: 'half', signal: controller.signal,
  }));
  const denied = request(photo);
  assert.equal((await provider.fetch(denied)).status, 503);
  assert.equal(denied.bodyUsed, false);
  controller.abort();
  assert.equal((await held).status, 503);
  assert.equal((await provider.fetch(request(photo))).status, 200);
});

test('body deadline cancels a stalled upload and releases capacity', async (t) => {
  const photo = await jpeg();
  const provider = createImageValidator({ enabled: true });
  let cancelled = false;
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const held = provider.fetch(new Request('https://preservation-internal/images/validate-jpeg', {
    method: 'POST', headers: { 'content-type': 'application/json' }, duplex: 'half',
    body: new ReadableStream({ start() {}, cancel() { cancelled = true; } }),
  }));
  t.mock.timers.tick(BODY_TIMEOUT_MS);
  assert.equal((await held).status, 503); assert.equal(cancelled, true);
  t.mock.timers.reset();
  assert.equal((await provider.fetch(request(photo))).status, 200);
});

test('bounds empty and tiny ready chunks even when total bytes stay below the limit', async () => {
  const provider = createImageValidator({ enabled: true });
  for (const size of [0, 1]) {
    let reads = 0, cancelled = false;
    const chunk = new Uint8Array(size);
    const response = await provider.fetch(new Request('https://preservation-internal/images/validate-jpeg', {
      method: 'POST', headers: { 'content-type': 'application/json' }, duplex: 'half',
      body: new ReadableStream({
        pull(controller) { reads++; controller.enqueue(chunk); },
        cancel() { cancelled = true; },
      }),
    }));
    assert.equal(response.status, 400); assert.equal(cancelled, true);
    assert.ok(reads <= MAX_BODY_CHUNKS + 2, 'one read-ahead chunk is allowed; unbounded loops are not');
  }
});
