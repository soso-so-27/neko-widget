import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { sealKeyBundle, openKeyBundle } from './key-bundle.mjs';

const wrappingKey = randomBytes(32);
const keys = new Map([['old', randomBytes(32)], ['current', randomBytes(32)]]);
const options = { keys, activeKeyId: 'current', wrappingKey, wrappingKeyId: 'synthetic-root', scope: 'test-archive' };
const jwe = await sealKeyBundle(options);
const read = (overrides = {}) => openKeyBundle({ jwe, wrappingKey, wrappingKeyId: options.wrappingKeyId,
  expectedScope: options.scope, ...overrides });
const code = (expected) => (error) => error.code === expected;

test('wrapped key bundle restores active and older data keys without containing their plaintext', async () => {
  const result = await read();
  assert.equal(result.activeKeyId, 'current');
  for (const [id, bytes] of keys) {
    assert.deepEqual(result.keys.get(id), bytes);
    assert.equal(jwe.includes(bytes.toString('base64url')), false);
  }
});
test('lost wrapping key is an explicit failure, not a newly generated replacement', async () => {
  await assert.rejects(read({ wrappingKey: undefined }), code('WRAPPING_KEY_UNAVAILABLE'));
});
test('wrong wrapping key or key identifier fails closed', async () => {
  await assert.rejects(read({ wrappingKey: randomBytes(32) }), code('KEY_BUNDLE_UNREADABLE'));
  await assert.rejects(read({ wrappingKeyId: 'different-root' }), code('KEY_BUNDLE_UNREADABLE'));
});
test('a bundle for another deployment cannot be substituted', async () => {
  await assert.rejects(read({ expectedScope: 'another-archive' }), code('KEY_BUNDLE_UNREADABLE'));
});
test('corrupted bundle is not accepted', async () => {
  const pieces = jwe.split('.');
  pieces[3] = (pieces[3][0] === 'A' ? 'B' : 'A') + pieces[3].slice(1);
  await assert.rejects(read({ jwe: pieces.join('.') }), code('KEY_BUNDLE_UNREADABLE'));
});
test('invalid or missing active data key cannot be sealed', async () => {
  await assert.rejects(sealKeyBundle({ ...options, activeKeyId: 'missing' }), code('INVALID_KEY_BUNDLE'));
  await assert.rejects(sealKeyBundle({ ...options, keys: new Map([['current', randomBytes(16)]]) }), code('INVALID_KEY_BUNDLE'));
});
