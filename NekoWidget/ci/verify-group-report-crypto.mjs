import assert from 'node:assert/strict';
import {createHash, createPrivateKey, createPublicKey, diffieHellman, hkdfSync, createDecipheriv} from 'node:crypto';
import {readFileSync, writeFileSync} from 'node:fs';
import {createGroupModerationFixture, SYNTHETIC_CANONICAL_JPEG} from '../SharingService/test/fixtures/group-moderation.mjs';
import {decryptGroupModerationReport} from '../SharingService/scripts/group-moderation-report-lib.mjs';
import {deriveRawModerationPublicKey, parseBinaryPlist, validateCanonicalJPEG} from '../SharingService/scripts/moderation-report-lib.mjs';

// Reuse only the existing repository's public TEST seed. No real key, image,
// identity or private-key file participates in either direction of this test.
const testSeed = Buffer.alloc(32, 0x42);
const fixtureURL = new URL('./fixtures/group-report-v3.json', import.meta.url);
const fields = fixture => ['NW3.MODERATION-REPORT', '3', fixture.windowID,
  fixture.momentID, fixture.reporterParticipantID, fixture.reasonCode, 'moderation-v2'];
function aad(values, width = 4) {
  return Buffer.concat(values.flatMap(value => {
    const bytes = Buffer.from(value, 'utf8'), length = Buffer.alloc(width);
    length.writeUIntBE(bytes.length, 0, width);
    return [length, bytes];
  }));
}
function metadata(fixture, bytes) {
  const committedAt = Math.floor(Date.now() / 1000) - 1;
  return {schema: 'jp.nekowidget.group-moderation-export.v1', protocolVersion: 3,
    envelopeDomain: 'NW3.MODERATION-REPORT', algorithm: 'X25519-HKDF-SHA256-CHACHA20POLY1305',
    reportId: Buffer.alloc(16, 1).toString('base64url'), windowId: fixture.windowID,
    momentId: fixture.momentID, reporterParticipantId: fixture.reporterParticipantID,
    reasonCode: fixture.reasonCode, moderationKeyId: 'moderation-v2',
    ciphertextSize: bytes.length, ciphertextSHA256: createHash('sha256').update(bytes).digest('base64url'),
    committedAt, contentExpiresAt: committedAt + 604800};
}
function openPlaintext(fixture, bytes, {width = 4, info = 'jp.nekowidget.moment.report.v1', domain} = {}) {
  const envelope = parseBinaryPlist(bytes), values = fields(fixture);
  if (domain) values[0] = domain;
  const authentication = aad(values, width);
  const shared = diffieHellman({
    privateKey: createPrivateKey({key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), testSeed]), format: 'der', type: 'pkcs8'}),
    publicKey: createPublicKey({key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), envelope.ephemeralPublicKey]), format: 'der', type: 'spki'}),
  });
  const key = Buffer.from(hkdfSync('sha256', shared, createHash('sha256').update(authentication).digest(), Buffer.from(info), 32));
  const combined = envelope.ciphertext;
  const decipher = createDecipheriv('chacha20-poly1305', key, combined.subarray(0, 12), {authTagLength: 16});
  decipher.setAAD(authentication, {plaintextLength: combined.length - 28});
  decipher.setAuthTag(combined.subarray(-16));
  try { return parseBinaryPlist(Buffer.concat([decipher.update(combined.subarray(12, -16)), decipher.final()])); }
  finally { shared.fill(0); key.fill(0); }
}
function makeFixture() {
  const ordinary = createGroupModerationFixture({committedAt: 1767225600});
  const captured = createGroupModerationFixture({committedAt: 1767225600,
    changePayload: payload => { payload.capturedAt = new Date('2025-12-31T23:00:00Z'); }});
  const fixture = {schema: 'jp.nekowidget.group-report-crypto-vector.v1',
    note: 'Synthetic 1px JPEG and existing public TEST seed 0x42 only; never a live moderation key.',
    windowID: ordinary.metadata.windowId, momentID: ordinary.metadata.momentId,
    reporterParticipantID: ordinary.metadata.reporterParticipantId, reasonCode: ordinary.metadata.reasonCode,
    recipientPublicKeyBase64: deriveRawModerationPublicKey(testSeed).toString('base64'),
    canonicalJPEGBase64: SYNTHETIC_CANONICAL_JPEG.toString('base64'),
    reportedAtUnixSeconds: 1767225600, capturedAtUnixSeconds: 1767222000,
    aadHex: ordinary.aad.toString('hex'),
    nodeEnvelopeBase64: ordinary.envelopeBytes.toString('base64'),
    nodeCapturedEnvelopeBase64: captured.envelopeBytes.toString('base64')};
  ordinary.privateKeyBytes.fill(0); captured.privateKeyBytes.fill(0);
  return fixture;
}

if (process.argv[2] === '--write-fixture') {
  writeFileSync(fixtureURL, `${JSON.stringify(makeFixture(), null, 2)}\n`, {flag: 'wx'});
  console.log('Wrote public synthetic group report interoperability vector.');
} else {
  const fixture = JSON.parse(readFileSync(fixtureURL, 'utf8'));
  assert.deepEqual(fixture, makeFixture(), 'Checked-in vector must match the independent Node encoder');
  assert.equal(aad(fields(fixture)).toString('hex'), fixture.aadHex);
  assert.deepEqual(validateCanonicalJPEG(Buffer.from(fixture.canonicalJPEGBase64, 'base64')), {width: 1, height: 1});
  for (const property of ['nodeEnvelopeBase64', 'nodeCapturedEnvelopeBase64']) {
    const bytes = Buffer.from(fixture[property], 'base64');
    const decoded = decryptGroupModerationReport(metadata(fixture, bytes), bytes, testSeed);
    assert.deepEqual(decoded.canonicalJPEG, SYNTHETIC_CANONICAL_JPEG);
    const plain = openPlaintext(fixture, bytes);
    assert.equal(plain.reportedAt.getTime(), fixture.reportedAtUnixSeconds * 1000);
    assert.equal(Object.hasOwn(plain, 'capturedAt'), property === 'nodeCapturedEnvelopeBase64');
    if (plain.capturedAt) assert.equal(plain.capturedAt.getTime(), fixture.capturedAtUnixSeconds * 1000);
    for (const changed of ['windowId', 'momentId', 'reporterParticipantId']) {
      assert.throws(() => decryptGroupModerationReport({...metadata(fixture, bytes), [changed]: Buffer.alloc(16, 9).toString('base64url')}, bytes, testSeed));
    }
    assert.throws(() => openPlaintext(fixture, bytes, {width: 2}));
    assert.throws(() => openPlaintext(fixture, bytes, {domain: 'NW2.MODERATION-REPORT'}));
    assert.throws(() => openPlaintext(fixture, bytes, {info: 'jp.nekowidget.group.report.v3'}));
  }
  if (process.argv[2] === '--swift-stdin') {
    const native = JSON.parse(readFileSync(0, 'utf8'));
    assert.equal(native.schema, 'jp.nekowidget.group-report-swift-interop.v1');
    assert.equal(native.envelopes.length, 4);
    for (const [index, reasonCode] of ['objectionable', 'harassment', 'privacy', 'other'].entries()) {
      assert.equal(native.envelopes[index].reasonCode, reasonCode);
      const context = {...fixture, reasonCode};
      const bytes = Buffer.from(native.envelopes[index].envelopeBase64, 'base64');
      assert.equal(bytes.subarray(0, 8).toString(), 'bplist00');
      assert.deepEqual(Object.keys(parseBinaryPlist(bytes)).sort(),
        ['protocolVersion', 'moderationKeyID', 'ephemeralPublicKey', 'ciphertext'].sort());
      const result = decryptGroupModerationReport(metadata(context, bytes), bytes, testSeed);
      assert.deepEqual(result.canonicalJPEG, SYNTHETIC_CANONICAL_JPEG);
      const plain = openPlaintext(context, bytes);
      assert.deepEqual(Object.keys(plain).sort(), ['protocolVersion', 'windowID', 'momentID',
        'reporterParticipantID', 'reason', 'reportedAt', 'canonicalJPEG'].sort());
      assert.equal(plain.reportedAt.getTime(), fixture.reportedAtUnixSeconds * 1000);
      assert.equal(plain.reason, reasonCode);
      const changed = Buffer.from(bytes); changed[changed.length >> 1] ^= 1;
      assert.throws(() => decryptGroupModerationReport(metadata(context, changed), changed, testSeed));
    }
    console.log('Group report crypto: Node → Swift and Swift → operator Node passed; 4 reasons, date/data plist types, NW3 binding and validation.');
  } else {
    assert.ok(process.argv[2] === undefined || process.argv[2] === '--fixture-only');
    console.log('Group report crypto: Node vector and receiver contract passed. Native Swift interoperability has not run.');
  }
}
testSeed.fill(0);
