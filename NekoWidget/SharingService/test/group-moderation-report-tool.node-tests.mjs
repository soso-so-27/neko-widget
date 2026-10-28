import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createGroupModerationFixture, syntheticID, SYNTHETIC_CANONICAL_JPEG} from './fixtures/group-moderation.mjs';
import {decryptGroupModerationReport, validateGroupModerationMetadata,
  validateGroupModerationCiphertextDescriptor} from '../scripts/group-moderation-report-lib.mjs';
import {decryptModerationReport} from '../scripts/moderation-report-lib.mjs';
const rejected = f => assert.throws(() => decryptGroupModerationReport(f.metadata, f.envelopeBytes, f.privateKeyBytes),
  {message: 'group_moderation_report_unavailable'});

test('v3 four-byte AAD encryptor round-trips selected canonical JPEG without mutating inputs', () => {
  const f = createGroupModerationFixture(), envelope = Buffer.from(f.envelopeBytes), key = Buffer.from(f.privateKeyBytes);
  assert.equal(f.aad.readUInt32BE(0), Buffer.byteLength('NW3.MODERATION-REPORT'));
  const output = decryptGroupModerationReport(f.metadata, f.envelopeBytes, f.privateKeyBytes);
  assert.deepEqual(output.canonicalJPEG, SYNTHETIC_CANONICAL_JPEG);
  assert.deepEqual(output.dimensions, {width: 1, height: 1});
  assert.deepEqual(f.envelopeBytes, envelope); assert.deepEqual(f.privateKeyBytes, key);
  output.canonicalJPEG.fill(0);
  assert.deepEqual(f.envelopeBytes, envelope);
});
test('v2 decryptor remains closed to v3, and v3 rejects NW2 or ordinary group two-byte AAD', () => {
  const f = createGroupModerationFixture();
  assert.throws(() => decryptModerationReport(f.metadata, f.envelopeBytes, f.privateKeyBytes));
  rejected(createGroupModerationFixture({aadWidth: 2}));
  rejected(createGroupModerationFixture({aadFields: ['NW2.MODERATION-REPORT', '2', f.metadata.momentId,
    f.metadata.reporterParticipantId, 'privacy', 'moderation-v2']}));
  rejected(createGroupModerationFixture({hkdfInfo: 'jp.nekowidget.group.report.v1'}));
});
for (const field of ['windowId', 'momentId', 'reporterParticipantId', 'reasonCode']) {
  test(`authenticated metadata cannot substitute ${field}`, () => {
    const f = createGroupModerationFixture(); f.metadata[field] = field === 'reasonCode' ? 'other' : syntheticID(8); rejected(f);
  });
}
for (const field of ['windowID', 'momentID', 'reporterParticipantID', 'reason', 'protocolVersion']) {
  test(`authenticated plaintext must match the same ${field}`, () => {
    rejected(createGroupModerationFixture({changePayload(p) {p[field] = field === 'reason' ? 'other' : field === 'protocolVersion' ? 2 : syntheticID(9);}}));
  });
}
test('only allowlisted plaintext/envelope attributes and valid dates are accepted', () => {
  rejected(createGroupModerationFixture({changePayload(p) {p.unsubmittedText = 'synthetic forbidden extra';}}));
  rejected(createGroupModerationFixture({changePayload(p) {p.reportedAt = 'not-a-date';}}));
  rejected(createGroupModerationFixture({changePayload(p) {p.capturedAt = 1;}}));
  rejected(createGroupModerationFixture({changePayload(p) {delete p.windowID;}}));
  rejected(createGroupModerationFixture({changeEnvelope(e) {e.windowKey = Buffer.alloc(32);}}));
  rejected(createGroupModerationFixture({changeEnvelope(e) {e.protocolVersion = 2;}}));
  rejected(createGroupModerationFixture({changeEnvelope(e) {e.moderationKeyID = 'moderation-v1';}}));
  const f = createGroupModerationFixture({changePayload(p) {p.capturedAt = new Date('2025-12-31T00:00:00Z');}});
  assert.deepEqual(decryptGroupModerationReport(f.metadata, f.envelopeBytes, f.privateKeyBytes).canonicalJPEG, SYNTHETIC_CANONICAL_JPEG);
});
test('wrong key, low-order public key, altered ciphertext, length and hash are rejected', () => {
  const wrongKey = createGroupModerationFixture(); wrongKey.privateKeyBytes.fill(0x33); rejected(wrongKey);
  rejected(createGroupModerationFixture({changeEnvelope(e) {e.ephemeralPublicKey.fill(0);}}));
  const changed = createGroupModerationFixture(); changed.envelopeBytes[100] ^= 1; rejected(changed);
  const size = createGroupModerationFixture(); size.metadata.ciphertextSize++; rejected(size);
  const hash = createGroupModerationFixture(); hash.metadata.ciphertextSHA256 = Buffer.alloc(32).toString('base64url'); rejected(hash);
  const tag = createGroupModerationFixture({changeEnvelope(e) {e.ciphertext[e.ciphertext.length - 1] ^= 1;}}); rejected(tag);
});
test('metadata is strict, canonical and bounded; retention is exactly seven days', () => {
  const f = createGroupModerationFixture(), valid = f.metadata;
  for (const mutation of [{protocolVersion: 2}, {schema: 'jp.nekowidget.moderation-export.v1'},
    {envelopeDomain: 'NW2.MODERATION-REPORT'}, {moderationKeyId: 'moderation-v1'}, {extra: 1},
    {windowId: 'bad/id'}, {reportId: 'A'.repeat(21) + 'B'}, {ciphertextSize: 1048577},
    {ciphertextSize: 28}, {ciphertextSHA256: 'A'.repeat(42) + 'B'}, {contentExpiresAt: valid.contentExpiresAt + 1},
    {committedAt: Number.MAX_SAFE_INTEGER}, {committedAt: 1.5}]) {
    assert.throws(() => validateGroupModerationMetadata({...valid, ...mutation}));
  }
  const getter = {...valid}; Object.defineProperty(getter, 'windowId', {enumerable: true, get() {assert.fail('getter executed');}});
  assert.throws(() => validateGroupModerationMetadata(getter), {message: 'group_moderation_report_unavailable'});
  const expired = {...valid, committedAt: 1, contentExpiresAt: 604801};
  assert.throws(() => validateGroupModerationMetadata(expired));
  assert.doesNotThrow(() => validateGroupModerationMetadata(expired, {enforceCurrentWindow: false}));
  assert.throws(() => validateGroupModerationCiphertextDescriptor(valid, f.envelopeBytes.subarray(1)));
});
test('canonical JPEG strips no metadata silently: APP, malformed and oversized pictures are rejected', () => {
  rejected(createGroupModerationFixture({changePayload(p) {
    p.canonicalJPEG = Buffer.concat([p.canonicalJPEG.subarray(0, 2), Buffer.from([255, 225, 0, 4, 0, 0]), p.canonicalJPEG.subarray(2)]);
  }}));
  rejected(createGroupModerationFixture({changePayload(p) {p.canonicalJPEG = Buffer.from([255, 216, 255, 217]);}}));
  rejected(createGroupModerationFixture({changePayload(p) {p.canonicalJPEG = Buffer.alloc(950273);}}));
});
test('content expiring during synchronous validation releases no JPEG', context => {
  const clock = Date.now(), f = createGroupModerationFixture({committedAt: Math.floor(clock / 1000) - 604799});
  let calls = 0;
  context.mock.method(Date, 'now', () => clock + (calls++ ? 2000 : 0));
  rejected(f);
});
test('deterministic synthetic wire is stable independent of export time', () => {
  const a = createGroupModerationFixture({committedAt: 1000}), b = createGroupModerationFixture({committedAt: 2000});
  assert.deepEqual(a.aad, b.aad); assert.deepEqual(a.envelopeBytes, b.envelopeBytes);
  assert.equal(createHash('sha256').update(a.envelopeBytes).digest('base64url'), a.metadata.ciphertextSHA256);
});
