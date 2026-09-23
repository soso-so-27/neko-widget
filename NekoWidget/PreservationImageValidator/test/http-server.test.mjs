import assert from 'node:assert/strict';
import { once } from 'node:events';
import { test } from 'node:test';
import { createValidatorHTTPServer } from '../dist/http-server.js';
import { jpeg, truncateEntropy } from './fixtures.mjs';

const secret = 'A'.repeat(43);

async function withServer(run) {
  const server = createValidatorHTTPServer(secret);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  try { await run(`http://127.0.0.1:${address.port}`); }
  finally { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
}

function request(base, bytes, headers = {}) {
  return fetch(`${base}/images/validate-jpeg`, { method: 'POST',
    headers: { 'content-type': 'application/json', 'x-neko-validator-secret': secret, ...headers },
    body: JSON.stringify({ photoBase64: bytes.toString('base64') }),
  });
}

test('private HTTP bridge validates full JPEG pixels and preserves the service contract', async () => {
  await withServer(async (base) => {
    const photo = await jpeg();
    const accepted = await request(base, photo);
    assert.equal(accepted.status, 200);
    assert.equal(accepted.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await accepted.json(), { valid: true, mediaType: 'image/jpeg', frames: 1 });
    const truncated = await request(base, truncateEntropy(photo));
    assert.equal(truncated.status, 200);
    assert.deepEqual(await truncated.json(), { valid: false });
  });
});

test('missing or incorrect private caller proof is rejected before photo processing', async () => {
  await withServer(async (base) => {
    const photo = await jpeg();
    for (const value of ['', 'B'.repeat(43)]) {
      const response = await request(base, photo, { 'x-neko-validator-secret': value });
      assert.equal(response.status, 503);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      const body = await response.text();
      assert.equal(body.includes(photo.toString('base64')), false);
      assert.equal(body.includes(secret), false);
    }
    const route = await fetch(`${base}/anything`, { method: 'POST',
      headers: { 'x-neko-validator-secret': secret }, body: 'private' });
    assert.equal(route.status, 503);
  });
});

test('invalid startup secret cannot open the listener', () => {
  assert.throws(() => createValidatorHTTPServer('short'), /configuration invalid/);
});
