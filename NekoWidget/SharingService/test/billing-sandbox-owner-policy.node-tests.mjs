import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseOwnerAdmission } from '../src/billing-sandbox-owner-policy.mjs';
const value = { version: 1, bootstrapClientRequestId: '5f30c0de-0000-4000-8000-000000000001', initialPublicKeySHA256: 'a'.repeat(64), startsAtMs: 1000, expiresAtMs: 2000 };
test('owner policy accepts only one bounded public enrollment and closes on malformed inputs or expiry', () => {
  assert.deepEqual(parseOwnerAdmission(JSON.stringify(value), 1000), value);
  assert.throws(() => parseOwnerAdmission(JSON.stringify(value), 999));
  assert.throws(() => parseOwnerAdmission(JSON.stringify(value), 2000));
  assert.deepEqual(parseOwnerAdmission(JSON.stringify(value), 2000, true), value, 'rollback schema validation may accept expired policy');
  for (const change of [ { bootstrapClientRequestId: [value.bootstrapClientRequestId] }, { initialPublicKeySHA256: 'A'.repeat(64) }, { extra: 'identity' }, { expiresAtMs: value.startsAtMs + 7 * 86400000 + 1 }, { startsAtMs: -1 }, { expiresAtMs: 1000 }, { version: 2 }, { expiresAtMs: 2000.5 } ]) {
    assert.throws(() => parseOwnerAdmission(JSON.stringify({ ...value, ...change }), 1500));
  }
  for (const text of [undefined, null, '{}', '[]', 'null', 'x'.repeat(513)]) assert.throws(() => parseOwnerAdmission(text, 1500));
});

test('seven-day owner admission works after day one and closes exactly at expiry', () => {
  const sevenDays = { ...value, expiresAtMs: value.startsAtMs + 7 * 86400000 };
  const text = JSON.stringify(sevenDays);
  assert.deepEqual(parseOwnerAdmission(text, value.startsAtMs + 86400000), sevenDays);
  assert.deepEqual(parseOwnerAdmission(text, sevenDays.expiresAtMs - 1), sevenDays);
  assert.throws(() => parseOwnerAdmission(text, sevenDays.expiresAtMs));
  assert.throws(() => parseOwnerAdmission(text, value.startsAtMs - 1));
});
