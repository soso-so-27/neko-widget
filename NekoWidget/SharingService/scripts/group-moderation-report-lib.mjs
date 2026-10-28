import {
  createDecipheriv, createHash, createPrivateKey, createPublicKey,
  diffieHellman, hkdfSync, timingSafeEqual,
} from 'node:crypto';
import {
  parseBinaryPlist, validateCanonicalJPEG, MODERATION_ALGORITHM,
  MAXIMUM_REPORT_CIPHERTEXT_BYTES, MODERATION_REPORT_CONTENT_TTL_SECONDS,
  MODERATION_EXPORT_CLOCK_SKEW_SECONDS,
} from './moderation-report-lib.mjs';

export const GROUP_MODERATION_EXPORT_SCHEMA = 'jp.nekowidget.group-moderation-export.v1';
export const GROUP_MODERATION_ENVELOPE_DOMAIN = 'NW3.MODERATION-REPORT';
export const GROUP_MODERATION_PROTOCOL_VERSION = 3;
export const GROUP_MODERATION_KEY_ID = 'moderation-v2';
const PRIVATE_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex');
const PUBLIC_PREFIX = Buffer.from('302a300506032b656e032100', 'hex');
// Preserve the existing report algorithm. Its NW3 AAD/salt separates this wire
// format from NW2. This is not the ordinary group's two-byte field encoding.
const HKDF_INFO = Buffer.from('jp.nekowidget.moment.report.v1', 'utf8');
const fail = () => { throw new Error('group_moderation_report_unavailable'); };

function exact(value, required, optional = []) {
  if (!value || typeof value !== 'object' || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) fail();
  const allowed = new Set([...required, ...optional]);
  const names = Reflect.ownKeys(value);
  if (names.some(name => !allowed.has(name)) || required.some(name => !Object.hasOwn(value, name))) fail();
  for (const name of names) {
    const property = Object.getOwnPropertyDescriptor(value, name);
    if (!property?.enumerable || !Object.hasOwn(property, 'value')) fail();
  }
}
function canonicalBinary(value, bytes) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/u.test(value)
      || value.length !== Math.ceil(bytes * 4 / 3)) fail();
  const decoded = Buffer.from(value, 'base64url');
  const valid = decoded.length === bytes && decoded.toString('base64url') === value;
  decoded.fill(0);
  if (!valid) fail();
}

/** Trusted D1 export metadata, never authority supplied by a browser. */
export function validateGroupModerationMetadata(value, {enforceCurrentWindow = true} = {}) {
  exact(value, ['schema', 'protocolVersion', 'envelopeDomain', 'algorithm', 'reportId', 'windowId',
    'momentId', 'reporterParticipantId', 'reasonCode', 'moderationKeyId', 'ciphertextSize',
    'ciphertextSHA256', 'committedAt', 'contentExpiresAt']);
  if (value.schema !== GROUP_MODERATION_EXPORT_SCHEMA || value.protocolVersion !== 3
      || value.envelopeDomain !== GROUP_MODERATION_ENVELOPE_DOMAIN || value.algorithm !== MODERATION_ALGORITHM
      || value.moderationKeyId !== GROUP_MODERATION_KEY_ID
      || !['objectionable', 'harassment', 'privacy', 'other'].includes(value.reasonCode)) fail();
  for (const name of ['reportId', 'windowId', 'momentId', 'reporterParticipantId']) canonicalBinary(value[name], 16);
  canonicalBinary(value.ciphertextSHA256, 32);
  if (!Number.isSafeInteger(value.ciphertextSize) || value.ciphertextSize < 29
      || value.ciphertextSize > MAXIMUM_REPORT_CIPHERTEXT_BYTES
      || !Number.isSafeInteger(value.committedAt) || value.committedAt <= 0
      || value.committedAt > Number.MAX_SAFE_INTEGER - MODERATION_REPORT_CONTENT_TTL_SECONDS
      || !Number.isSafeInteger(value.contentExpiresAt)
      || value.contentExpiresAt !== value.committedAt + MODERATION_REPORT_CONTENT_TTL_SECONDS) fail();
  if (enforceCurrentWindow) {
    const now = Math.floor(Date.now() / 1000);
    if (value.committedAt > now + MODERATION_EXPORT_CLOCK_SKEW_SECONDS || value.contentExpiresAt <= now) fail();
  }
  return Object.freeze({...value});
}

export function validateGroupModerationCiphertextDescriptor(metadata, envelopeBytes, options = {}) {
  const value = validateGroupModerationMetadata(metadata, options);
  if (!Buffer.isBuffer(envelopeBytes) || envelopeBytes.length !== value.ciphertextSize) fail();
  const expected = Buffer.from(value.ciphertextSHA256, 'base64url');
  const actual = createHash('sha256').update(envelopeBytes).digest();
  const valid = timingSafeEqual(expected, actual);
  expected.fill(0); actual.fill(0);
  if (!valid) fail();
  return value;
}

function aadFor(metadata) {
  const fields = [GROUP_MODERATION_ENVELOPE_DOMAIN, '3', metadata.windowId, metadata.momentId,
    metadata.reporterParticipantId, metadata.reasonCode, metadata.moderationKeyId];
  return Buffer.concat(fields.flatMap(field => {
    const bytes = Buffer.from(field, 'utf8'), length = Buffer.alloc(4);
    length.writeUInt32BE(bytes.length);
    return [length, bytes];
  }));
}

/** Decode ONLY the submitted canonical JPEG. No group key or ordinary media
 * reader exists here. Metadata binding authenticates what the reporter sent;
 * it does not prove that the reporter's picture is an unmodified original. */
export function decryptGroupModerationReport(metadataValue, envelopeBytes, privateKeyBytes) {
  let aad, salt, privateDER, publicDER, shared, key, plaintext, partialPlaintext, output;
  try {
    const metadata = validateGroupModerationCiphertextDescriptor(metadataValue, envelopeBytes);
    if (!Buffer.isBuffer(privateKeyBytes) || privateKeyBytes.length !== 32) fail();
    const envelope = parseBinaryPlist(envelopeBytes);
    exact(envelope, ['protocolVersion', 'moderationKeyID', 'ephemeralPublicKey', 'ciphertext']);
    if (envelope.protocolVersion !== 3 || envelope.moderationKeyID !== GROUP_MODERATION_KEY_ID
        || !Buffer.isBuffer(envelope.ephemeralPublicKey) || envelope.ephemeralPublicKey.length !== 32
        || !Buffer.isBuffer(envelope.ciphertext) || envelope.ciphertext.length < 29
        || envelope.ciphertext.length > MAXIMUM_REPORT_CIPHERTEXT_BYTES) fail();
    aad = aadFor(metadata);
    salt = createHash('sha256').update(aad).digest();
    privateDER = Buffer.concat([PRIVATE_PREFIX, privateKeyBytes]);
    publicDER = Buffer.concat([PUBLIC_PREFIX, envelope.ephemeralPublicKey]);
    const privateKey = createPrivateKey({key: privateDER, format: 'der', type: 'pkcs8'});
    const publicKey = createPublicKey({key: publicDER, format: 'der', type: 'spki'});
    shared = diffieHellman({privateKey, publicKey});
    key = Buffer.from(hkdfSync('sha256', shared, salt, HKDF_INFO, 32));
    const combined = envelope.ciphertext;
    const decipher = createDecipheriv('chacha20-poly1305', key, combined.subarray(0, 12), {authTagLength: 16});
    decipher.setAAD(aad, {plaintextLength: combined.length - 28});
    decipher.setAuthTag(combined.subarray(combined.length - 16));
    // Keep the unauthenticated update output owned so a failed final() also wipes it.
    partialPlaintext = decipher.update(combined.subarray(12, combined.length - 16));
    plaintext = Buffer.concat([partialPlaintext, decipher.final()]);
    const report = parseBinaryPlist(plaintext);
    exact(report, ['protocolVersion', 'windowID', 'momentID', 'reporterParticipantID', 'reason',
      'reportedAt', 'canonicalJPEG'], ['capturedAt']);
    if (report.protocolVersion !== 3 || report.windowID !== metadata.windowId || report.momentID !== metadata.momentId
        || report.reporterParticipantID !== metadata.reporterParticipantId || report.reason !== metadata.reasonCode
        || !(report.reportedAt instanceof Date) || !Number.isFinite(report.reportedAt.getTime())
        || (Object.hasOwn(report, 'capturedAt') && (!(report.capturedAt instanceof Date) || !Number.isFinite(report.capturedAt.getTime())))) fail();
    const dimensions = validateCanonicalJPEG(report.canonicalJPEG);
    // Parsing/JPEG validation must not release a result after its content expires.
    validateGroupModerationMetadata(metadata);
    output = Buffer.from(report.canonicalJPEG);
    return {canonicalJPEG: output, dimensions};
  } catch {
    output?.fill(0);
    fail();
  } finally {
    for (const bytes of [aad, salt, privateDER, publicDER, shared, key, partialPlaintext, plaintext]) bytes?.fill(0);
  }
}
