import {createCipheriv, createHash, createPrivateKey, createPublicKey, diffieHellman, hkdfSync} from 'node:crypto';
import {deriveRawModerationPublicKey} from '../../scripts/moderation-report-lib.mjs';
import {encodeSyntheticBinaryPlist, SYNTHETIC_CANONICAL_JPEG} from '../../scripts/moderation-staging-drill-lib.mjs';

export {SYNTHETIC_CANONICAL_JPEG};
export const syntheticID = byte => Buffer.alloc(16, byte).toString('base64url');
const privatePrefix = Buffer.from('302e020100300506032b656e04220420', 'hex');
const publicPrefix = Buffer.from('302a300506032b656e032100', 'hex');
const sha = (bytes, encoding = 'hex') => createHash('sha256').update(bytes).digest(encoding);

/** Public deterministic TEST seeds and a 1px synthetic JPEG, never real keys or
 * evidence. Independent encryptor for the receiver's explicit four-byte AAD. */
export function createGroupModerationFixture(options = {}) {
  const privateKeyBytes = Buffer.alloc(32, 0x42), ephemeralPrivate = Buffer.alloc(32, 0x73);
  const rawPublic = deriveRawModerationPublicKey(privateKeyBytes);
  const ephemeralPublic = deriveRawModerationPublicKey(ephemeralPrivate);
  const committedAt = options.committedAt ?? Math.floor(Date.now() / 1000) - 1;
  const metadata = {schema: 'jp.nekowidget.group-moderation-export.v1', protocolVersion: 3,
    envelopeDomain: 'NW3.MODERATION-REPORT', algorithm: 'X25519-HKDF-SHA256-CHACHA20POLY1305',
    reportId: syntheticID(1), windowId: syntheticID(2), momentId: syntheticID(3), reporterParticipantId: syntheticID(4),
    reasonCode: 'privacy', moderationKeyId: 'moderation-v2', committedAt, contentExpiresAt: committedAt + 604800};
  const fields = options.aadFields ?? ['NW3.MODERATION-REPORT', '3', metadata.windowId,
    metadata.momentId, metadata.reporterParticipantId, metadata.reasonCode, metadata.moderationKeyId];
  const aad = Buffer.concat(fields.map(field => {
    const value = Buffer.from(field), size = Buffer.alloc(options.aadWidth ?? 4);
    size.writeUIntBE(value.length, 0, size.length);
    return Buffer.concat([size, value]);
  }));
  const payload = {protocolVersion: 3, windowID: metadata.windowId, momentID: metadata.momentId,
    reporterParticipantID: metadata.reporterParticipantId, reason: metadata.reasonCode,
    reportedAt: new Date('2026-01-01T00:00:00Z'), canonicalJPEG: Buffer.from(SYNTHETIC_CANONICAL_JPEG)};
  options.changePayload?.(payload);
  const plaintext = encodeSyntheticBinaryPlist(payload);
  const shared = diffieHellman({
    privateKey: createPrivateKey({key: Buffer.concat([privatePrefix, ephemeralPrivate]), format: 'der', type: 'pkcs8'}),
    publicKey: createPublicKey({key: Buffer.concat([publicPrefix, rawPublic]), format: 'der', type: 'spki'}),
  });
  const key = Buffer.from(hkdfSync('sha256', shared, createHash('sha256').update(aad).digest(),
    Buffer.from(options.hkdfInfo ?? 'jp.nekowidget.moment.report.v1'), 32));
  const nonce = Buffer.alloc(12, 0x17);
  const cipher = createCipheriv('chacha20-poly1305', key, nonce, {authTagLength: 16});
  cipher.setAAD(aad, {plaintextLength: plaintext.length});
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const envelope = {protocolVersion: 3, moderationKeyID: 'moderation-v2', ephemeralPublicKey: ephemeralPublic,
    ciphertext: Buffer.concat([nonce, encrypted, cipher.getAuthTag()])};
  options.changeEnvelope?.(envelope);
  const envelopeBytes = encodeSyntheticBinaryPlist(envelope);
  Object.assign(metadata, {ciphertextSize: envelopeBytes.length, ciphertextSHA256: sha(envelopeBytes, 'base64url')});
  const ref = {caseReferenceHmac: 'a'.repeat(64), caseReferenceHmacKeyVersion: 1};
  const source = {schema: 'jp.nekowidget.group-moderation-review-source.v1', ...ref,
    objectKey: `groups/reports/v3/${metadata.reportId}/${Buffer.alloc(24, 5).toString('base64url')}`, metadata};
  const reviewed = {privateKeyBytes, companionPublicKeyBytes: Buffer.from(rawPublic.toString('base64url')),
    reviewedKeyId: 'moderation-v2', expectedPublicKeySHA256: sha(rawPublic)};
  for (const bytes of [ephemeralPrivate, shared, key, plaintext]) bytes.fill(0);
  return {metadata, envelopeBytes, privateKeyBytes, source, ref, reviewed, aad};
}
