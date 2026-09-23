import assert from 'node:assert/strict';
import { setTimeout } from 'node:timers/promises';
import { jpeg, truncateEntropy } from './fixtures.mjs';

const origin = 'http://127.0.0.1:18080';
const secret = 'A'.repeat(43); // CI-only synthetic caller proof.

let ready = false;
for (let attempt = 0; attempt < 50; attempt++) {
  try {
    const response = await fetch(`${origin}/ping`, { signal: AbortSignal.timeout(500) });
    if (response.status === 503) { ready = true; break; }
  } catch { /* Container still starting. */ }
  await setTimeout(100);
}
assert.equal(ready, true, 'private decoder image did not start');

const photo = await jpeg();
async function validate(bytes, callerSecret = secret) {
  return fetch(`${origin}/images/validate-jpeg`, { method: 'POST',
    headers: { 'content-type': 'application/json', 'x-neko-validator-secret': callerSecret },
    body: JSON.stringify({ photoBase64: bytes.toString('base64') }),
    signal: AbortSignal.timeout(10_000),
  });
}

const accepted = await validate(photo);
assert.equal(accepted.status, 200);
assert.deepEqual(await accepted.json(), { valid: true, mediaType: 'image/jpeg', frames: 1 });
const corrupt = await validate(truncateEntropy(photo));
assert.equal(corrupt.status, 200);
assert.deepEqual(await corrupt.json(), { valid: false });
const unauthorized = await validate(photo, 'B'.repeat(43));
assert.equal(unauthorized.status, 503);
assert.equal(unauthorized.headers.get('cache-control'), 'no-store');
