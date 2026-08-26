import {
  createDecipheriv,
  createHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  hkdfSync,
  timingSafeEqual,
} from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants as fsConstants,
  fchmodSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, parse, resolve } from "node:path";

export const MODERATION_EXPORT_SCHEMA = "jp.nekowidget.moderation-export.v1";
export const MODERATION_ENVELOPE_DOMAIN = "NW2.MODERATION-REPORT";
export const MODERATION_ALGORITHM = "X25519-HKDF-SHA256-CHACHA20POLY1305";
export const MODERATION_KEY_ID = "moderation-v1";
export const MODERATION_NEXT_KEY_ID = "moderation-v2";
export const MODERATION_KEY_IDS = Object.freeze([
  MODERATION_KEY_ID,
  MODERATION_NEXT_KEY_ID,
]);
export const MOMENT_PROTOCOL_VERSION = 2;
export const MAXIMUM_REPORT_CIPHERTEXT_BYTES = 1_024 * 1_024;
export const MAXIMUM_CANONICAL_JPEG_BYTES = (1_024 * 1_024) - (96 * 1_024) - 28;
export const MAXIMUM_METADATA_BYTES = 16 * 1_024;
export const MAXIMUM_AUDIT_LOG_BYTES = 4 * 1_024 * 1_024;
export const MAXIMUM_CANONICAL_PIXEL_DIMENSION = 2_048;
export const MODERATION_REVIEW_RECEIPT_BYTES = 107;
export const MODERATION_REPORT_CONTENT_TTL_SECONDS = 7 * 86_400;
export const MODERATION_EXPORT_CLOCK_SKEW_SECONDS = 5 * 60;

const X25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
const X25519_SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex");
const REPORT_HKDF_INFO = Buffer.from("jp.nekowidget.moment.report.v1", "utf8");
const MODERATION_REVIEW_RECEIPT_MAGIC = Buffer.from("NWMRV1\0", "ascii");
const APPLE_REFERENCE_DATE_UNIX_MILLISECONDS = 978_307_200_000;
const MAXIMUM_PLIST_OBJECTS = 64;
const MAXIMUM_PLIST_DEPTH = 8;

export class ModerationToolError extends Error {
  constructor(message) {
    super(message);
    this.name = "ModerationToolError";
  }
}

function fail(message) {
  throw new ModerationToolError(message);
}

export function validateModerationKeyId(value) {
  if (typeof value !== "string" || !MODERATION_KEY_IDS.includes(value)) {
    fail("moderation key ID is unsupported");
  }
  return value;
}

export function validateExpectedPublicKeySHA256(value) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/u.test(value)) {
    fail("expected moderation public-key SHA-256 is not canonical lowercase hex");
  }
  return value;
}

export function deriveRawModerationPublicKey(privateKeyBytes) {
  if (!Buffer.isBuffer(privateKeyBytes) || privateKeyBytes.length !== 32) {
    fail("moderation private key must be exactly 32 raw bytes");
  }
  const privateDER = Buffer.concat([X25519_PKCS8_PREFIX, privateKeyBytes]);
  let publicDER;
  try {
    const privateKey = createPrivateKey({ key: privateDER, format: "der", type: "pkcs8" });
    publicDER = createPublicKey(privateKey).export({ format: "der", type: "spki" });
    if (!Buffer.isBuffer(publicDER)
        || publicDER.length !== X25519_SPKI_PREFIX.length + 32
        || !publicDER.subarray(0, X25519_SPKI_PREFIX.length).equals(X25519_SPKI_PREFIX)) {
      fail("moderation public key could not be derived safely");
    }
    return Buffer.from(publicDER.subarray(X25519_SPKI_PREFIX.length));
  } catch (error) {
    if (error instanceof ModerationToolError) throw error;
    fail("moderation public key could not be derived safely");
  } finally {
    privateDER.fill(0);
    publicDER?.fill(0);
  }
}

export function moderationPublicKeySHA256(publicKeyBytes) {
  if (!Buffer.isBuffer(publicKeyBytes) || publicKeyBytes.length !== 32) {
    fail("moderation public key must be exactly 32 raw bytes");
  }
  return createHash("sha256").update(publicKeyBytes).digest("hex");
}

export function parseCanonicalModerationPublicKey(publicKeyBytes) {
  if (!Buffer.isBuffer(publicKeyBytes) || publicKeyBytes.length !== 43
      || publicKeyBytes.includes(0x0a) || publicKeyBytes.includes(0x0d)
      || publicKeyBytes.some((byte) => byte > 0x7f)) {
    fail("moderation public key must be exactly 43 ASCII bytes without a newline");
  }
  const text = publicKeyBytes.toString("ascii");
  if (!/^[A-Za-z0-9_-]{43}$/u.test(text)) {
    fail("moderation public key is not canonical base64url");
  }
  const decoded = Buffer.from(text, "base64url");
  if (decoded.length !== 32 || decoded.toString("base64url") !== text) {
    decoded.fill(0);
    fail("moderation public key is not canonical base64url");
  }
  return decoded;
}

export function verifyReviewedModerationPrivateKey({
  reviewedKeyId,
  metadataKeyId,
  privateKeyBytes,
  companionPublicKeyBytes,
  expectedPublicKeySHA256,
} = {}) {
  const reviewed = validateModerationKeyId(reviewedKeyId);
  const metadata = validateModerationKeyId(metadataKeyId);
  if (reviewed !== metadata) {
    fail("reviewed moderation key ID does not match metadata");
  }
  const expectedFingerprint = validateExpectedPublicKeySHA256(expectedPublicKeySHA256);
  let derivedPublic;
  let companionPublic;
  let expectedDigest;
  let actualDigest;
  try {
    derivedPublic = deriveRawModerationPublicKey(privateKeyBytes);
    companionPublic = parseCanonicalModerationPublicKey(companionPublicKeyBytes);
    if (!timingSafeEqual(derivedPublic, companionPublic)) {
      fail("moderation private key does not match its companion public key");
    }
    expectedDigest = Buffer.from(expectedFingerprint, "hex");
    actualDigest = createHash("sha256").update(derivedPublic).digest();
    if (!timingSafeEqual(expectedDigest, actualDigest)) {
      fail("moderation public-key fingerprint does not match the reviewed value");
    }
    return Object.freeze({
      keyId: reviewed,
      publicKeySHA256: expectedFingerprint,
    });
  } finally {
    derivedPublic?.fill(0);
    companionPublic?.fill(0);
    expectedDigest?.fill(0);
    actualDigest?.fill(0);
  }
}

function isPlainObject(value) {
  const prototype = value !== null && typeof value === "object"
    ? Object.getPrototypeOf(value)
    : undefined;
  return value !== null
    && typeof value === "object"
    && !Array.isArray(value)
    && !Buffer.isBuffer(value)
    && !(value instanceof Date)
    && (prototype === Object.prototype || prototype === null);
}

function exactKeys(value, required, optional = []) {
  if (!isPlainObject(value)) fail("input is not a plain object");
  const allowed = new Set([...required, ...optional]);
  const keys = Object.keys(value);
  if (keys.some((key) => !allowed.has(key))) fail("input contains an unknown field");
  if (required.some((key) => !Object.hasOwn(value, key))) fail("input is missing a required field");
}

function opaqueIdentifier(value) {
  return typeof value === "string"
    && value.length >= 1
    && Buffer.byteLength(value, "utf8") <= 128
    && /^[A-Za-z0-9_-]+$/u.test(value);
}

function strictBase64url32(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/u.test(value)) {
    fail("ciphertext SHA-256 is not canonical base64url");
  }
  const decoded = Buffer.from(`${value}=`, "base64url");
  if (decoded.length !== 32 || decoded.toString("base64url") !== value) {
    decoded.fill(0);
    fail("ciphertext SHA-256 is not canonical base64url");
  }
  return decoded;
}

function parseJSONString(text, cursor) {
  if (text[cursor] !== '"') fail("metadata JSON string is malformed");
  const start = cursor;
  cursor += 1;
  let escaped = false;
  while (cursor < text.length) {
    const code = text.charCodeAt(cursor);
    if (code < 0x20) fail("metadata JSON contains a control character");
    if (escaped) {
      escaped = false;
      cursor += 1;
      continue;
    }
    if (text[cursor] === "\\") {
      escaped = true;
      cursor += 1;
      continue;
    }
    if (text[cursor] === '"') {
      const token = text.slice(start, cursor + 1);
      try {
        return { value: JSON.parse(token), cursor: cursor + 1 };
      } catch {
        fail("metadata JSON string is malformed");
      }
    }
    cursor += 1;
  }
  fail("metadata JSON string is unterminated");
}

function skipWhitespace(text, cursor) {
  while (cursor < text.length && /[\t\n\r ]/u.test(text[cursor])) cursor += 1;
  return cursor;
}

/** Parse the deliberately flat export manifest while rejecting duplicate keys. */
export function parseModerationMetadata(text, { enforceCurrentWindow = true } = {}) {
  if (typeof text !== "string" || Buffer.byteLength(text, "utf8") > MAXIMUM_METADATA_BYTES) {
    fail("metadata file exceeds its size limit");
  }
  let cursor = skipWhitespace(text, 0);
  if (text[cursor] !== "{") fail("metadata JSON must be an object");
  cursor = skipWhitespace(text, cursor + 1);
  const value = Object.create(null);
  const seen = new Set();
  if (text[cursor] === "}") cursor += 1;
  else {
    while (cursor < text.length) {
      const keyToken = parseJSONString(text, cursor);
      if (typeof keyToken.value !== "string") fail("metadata key is invalid");
      if (seen.has(keyToken.value)) fail("metadata JSON contains a duplicate key");
      seen.add(keyToken.value);
      cursor = skipWhitespace(text, keyToken.cursor);
      if (text[cursor] !== ":") fail("metadata JSON is malformed");
      cursor = skipWhitespace(text, cursor + 1);
      let parsed;
      if (text[cursor] === '"') {
        parsed = parseJSONString(text, cursor);
      } else {
        const match = text.slice(cursor).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/u);
        if (match === null) fail("metadata value must be a string or number");
        parsed = { value: Number(match[0]), cursor: cursor + match[0].length };
        if (!Number.isFinite(parsed.value)) fail("metadata number is not finite");
      }
      value[keyToken.value] = parsed.value;
      cursor = skipWhitespace(text, parsed.cursor);
      if (text[cursor] === "}") {
        cursor += 1;
        break;
      }
      if (text[cursor] !== ",") fail("metadata JSON is malformed");
      cursor = skipWhitespace(text, cursor + 1);
    }
  }
  if (skipWhitespace(text, cursor) !== text.length) fail("metadata JSON has trailing data");
  return validateModerationMetadata(value, { enforceCurrentWindow });
}

export function validateModerationMetadata(value, { enforceCurrentWindow = true } = {}) {
  exactKeys(value, [
    "schema",
    "protocolVersion",
    "envelopeDomain",
    "algorithm",
    "reportId",
    "momentId",
    "reporterParticipantId",
    "reasonCode",
    "moderationKeyId",
    "ciphertextSize",
    "ciphertextSHA256",
    "committedAt",
    "contentExpiresAt",
  ]);
  if (value.schema !== MODERATION_EXPORT_SCHEMA) fail("metadata schema is unsupported");
  if (value.protocolVersion !== MOMENT_PROTOCOL_VERSION) fail("protocol version is unsupported");
  if (value.envelopeDomain !== MODERATION_ENVELOPE_DOMAIN) fail("envelope domain is unsupported");
  if (value.algorithm !== MODERATION_ALGORITHM) fail("moderation algorithm is unsupported");
  if (!opaqueIdentifier(value.reportId)) fail("report ID is invalid");
  if (!opaqueIdentifier(value.momentId)) fail("moment ID is invalid");
  if (!opaqueIdentifier(value.reporterParticipantId)) fail("reporter participant ID is invalid");
  if (!["objectionable", "harassment", "privacy", "other"].includes(value.reasonCode)) {
    fail("report reason is unsupported");
  }
  validateModerationKeyId(value.moderationKeyId);
  if (!Number.isSafeInteger(value.ciphertextSize)
      || value.ciphertextSize < 29
      || value.ciphertextSize > MAXIMUM_REPORT_CIPHERTEXT_BYTES) {
    fail("ciphertext size is outside the protocol bound");
  }
  const digest = strictBase64url32(value.ciphertextSHA256);
  digest.fill(0);
  if (!Number.isSafeInteger(value.committedAt) || value.committedAt <= 0
      || !Number.isSafeInteger(value.contentExpiresAt)
      || value.contentExpiresAt !== value.committedAt + MODERATION_REPORT_CONTENT_TTL_SECONDS) {
    fail("report export retention timestamps are invalid");
  }
  if (enforceCurrentWindow) {
    const now = Math.floor(Date.now() / 1_000);
    if (value.committedAt > now + MODERATION_EXPORT_CLOCK_SKEW_SECONDS) {
      fail("report export commit time is in the future");
    }
    if (value.contentExpiresAt <= now) {
      fail("report export content window has closed");
    }
  }
  return Object.freeze({ ...value });
}

function readUnsigned(buffer, offset, byteLength, limit = buffer.length) {
  if (!Number.isInteger(byteLength) || byteLength < 1 || byteLength > 8
      || offset < 0 || offset > limit - byteLength) {
    fail("binary plist integer is out of bounds");
  }
  let result = 0n;
  for (let index = 0; index < byteLength; index += 1) {
    result = (result << 8n) | BigInt(buffer[offset + index]);
  }
  if (result > BigInt(Number.MAX_SAFE_INTEGER)) fail("binary plist integer is too large");
  return Number(result);
}

function readSignedInteger(buffer, offset, byteLength, limit) {
  const unsigned = BigInt(readUnsigned(buffer, offset, byteLength, limit));
  const bitCount = BigInt(byteLength * 8);
  const sign = 1n << (bitCount - 1n);
  const signed = (unsigned & sign) === 0n ? unsigned : unsigned - (1n << bitCount);
  const value = Number(signed);
  if (!Number.isSafeInteger(value)) fail("binary plist integer is not safe");
  return value;
}

/** A bounded decoder for the subset emitted by Swift PropertyListEncoder. */
export function parseBinaryPlist(input) {
  if (!Buffer.isBuffer(input)
      || input.length < 40
      || input.length > MAXIMUM_REPORT_CIPHERTEXT_BYTES) {
    fail("binary plist size is invalid");
  }
  if (!input.subarray(0, 8).equals(Buffer.from("bplist00", "ascii"))) {
    fail("input is not a binary plist");
  }
  const trailer = input.length - 32;
  const offsetIntegerSize = input[trailer + 6];
  const objectReferenceSize = input[trailer + 7];
  if (![1, 2, 4, 8].includes(offsetIntegerSize)
      || ![1, 2, 4, 8].includes(objectReferenceSize)) {
    fail("binary plist reference width is invalid");
  }
  const objectCount = readUnsigned(input, trailer + 8, 8);
  const topObject = readUnsigned(input, trailer + 16, 8);
  const offsetTable = readUnsigned(input, trailer + 24, 8);
  if (objectCount < 1 || objectCount > MAXIMUM_PLIST_OBJECTS || topObject >= objectCount) {
    fail("binary plist object table is invalid");
  }
  if (offsetTable < 8
      || offsetTable + (objectCount * offsetIntegerSize) !== trailer) {
    fail("binary plist offset table is invalid");
  }
  const offsets = [];
  const uniqueOffsets = new Set();
  for (let index = 0; index < objectCount; index += 1) {
    const offset = readUnsigned(
      input,
      offsetTable + (index * offsetIntegerSize),
      offsetIntegerSize,
      trailer,
    );
    if (offset < 8 || offset >= offsetTable || uniqueOffsets.has(offset)) {
      fail("binary plist object offset is invalid");
    }
    offsets.push(offset);
    uniqueOffsets.add(offset);
  }
  const sortedOffsets = [...offsets].sort((a, b) => a - b);
  const objectLimits = new Map();
  for (let index = 0; index < sortedOffsets.length; index += 1) {
    objectLimits.set(sortedOffsets[index], sortedOffsets[index + 1] ?? offsetTable);
  }
  const cache = new Map();
  const visiting = new Set();
  const visited = new Set();

  function collectionLength(info, cursor, limit) {
    if (info < 15) return { length: info, cursor };
    if (cursor >= limit || (input[cursor] >> 4) !== 0x1) {
      fail("binary plist extended length is invalid");
    }
    const byteLength = 1 << (input[cursor] & 0x0f);
    if (![1, 2, 4, 8].includes(byteLength)) fail("binary plist length width is invalid");
    return {
      length: readUnsigned(input, cursor + 1, byteLength, limit),
      cursor: cursor + 1 + byteLength,
    };
  }

  function referenceAt(cursor, limit) {
    const reference = readUnsigned(input, cursor, objectReferenceSize, limit);
    if (reference >= objectCount) fail("binary plist reference is invalid");
    return reference;
  }

  function decode(index, depth) {
    if (depth > MAXIMUM_PLIST_DEPTH) fail("binary plist nesting is too deep");
    if (cache.has(index)) return cache.get(index);
    if (visiting.has(index)) fail("binary plist contains a reference cycle");
    visiting.add(index);
    visited.add(index);
    const offset = offsets[index];
    const limit = objectLimits.get(offset);
    if (limit === undefined || offset >= limit) fail("binary plist object bounds are invalid");
    const marker = input[offset];
    const type = marker >> 4;
    const info = marker & 0x0f;
    let cursor = offset + 1;
    let value;
    if (type === 0x1) {
      const byteLength = 1 << info;
      if (![1, 2, 4, 8].includes(byteLength)) fail("binary plist integer width is invalid");
      value = readSignedInteger(input, cursor, byteLength, limit);
    } else if (type === 0x3 && info === 0x3) {
      if (cursor > limit - 8) fail("binary plist date is out of bounds");
      const seconds = input.readDoubleBE(cursor);
      if (!Number.isFinite(seconds)) fail("binary plist date is invalid");
      value = new Date(APPLE_REFERENCE_DATE_UNIX_MILLISECONDS + (seconds * 1_000));
      if (!Number.isFinite(value.getTime())) fail("binary plist date is invalid");
    } else if (type === 0x4 || type === 0x5 || type === 0x6) {
      const measured = collectionLength(info, cursor, limit);
      cursor = measured.cursor;
      const byteLength = type === 0x6 ? measured.length * 2 : measured.length;
      if (measured.length > MAXIMUM_REPORT_CIPHERTEXT_BYTES
          || cursor > limit - byteLength) {
        fail("binary plist value is out of bounds");
      }
      const bytes = input.subarray(cursor, cursor + byteLength);
      if (type === 0x4) value = bytes;
      else if (type === 0x5) {
        if (bytes.some((byte) => byte > 0x7f)) fail("binary plist ASCII string is invalid");
        value = bytes.toString("ascii");
      } else {
        const littleEndian = Buffer.allocUnsafe(byteLength);
        for (let byte = 0; byte < byteLength; byte += 2) {
          littleEndian[byte] = bytes[byte + 1];
          littleEndian[byte + 1] = bytes[byte];
        }
        value = new TextDecoder("utf-16le", { fatal: true }).decode(littleEndian);
        littleEndian.fill(0);
      }
    } else if (type === 0xa) {
      const measured = collectionLength(info, cursor, limit);
      cursor = measured.cursor;
      if (measured.length > MAXIMUM_PLIST_OBJECTS
          || cursor > limit - (measured.length * objectReferenceSize)) {
        fail("binary plist array is out of bounds");
      }
      value = [];
      for (let item = 0; item < measured.length; item += 1) {
        value.push(decode(referenceAt(cursor + (item * objectReferenceSize), limit), depth + 1));
      }
    } else if (type === 0xd) {
      const measured = collectionLength(info, cursor, limit);
      cursor = measured.cursor;
      const referencesBytes = measured.length * objectReferenceSize * 2;
      if (measured.length > MAXIMUM_PLIST_OBJECTS || cursor > limit - referencesBytes) {
        fail("binary plist dictionary is out of bounds");
      }
      value = Object.create(null);
      for (let item = 0; item < measured.length; item += 1) {
        const keyReference = referenceAt(cursor + (item * objectReferenceSize), limit);
        const valueReference = referenceAt(
          cursor + ((measured.length + item) * objectReferenceSize),
          limit,
        );
        const key = decode(keyReference, depth + 1);
        if (typeof key !== "string" || Object.hasOwn(value, key)) {
          fail("binary plist dictionary key is invalid");
        }
        value[key] = decode(valueReference, depth + 1);
      }
    } else {
      fail("binary plist contains an unsupported object type");
    }
    visiting.delete(index);
    cache.set(index, value);
    return value;
  }

  const result = decode(topObject, 0);
  if (visited.size !== objectCount) fail("binary plist contains unreachable objects");
  return result;
}

function canonicalFields(fields) {
  const chunks = [];
  for (const field of fields) {
    const bytes = Buffer.from(field, "utf8");
    if (bytes.length > 0xffff_ffff) fail("AAD field is too large");
    const length = Buffer.alloc(4);
    length.writeUInt32BE(bytes.length);
    chunks.push(length, bytes);
  }
  return Buffer.concat(chunks);
}

/** Validate marker structure and the metadata-free canonical JPEG boundary. */
export function validateCanonicalJPEG(jpeg) {
  if (!Buffer.isBuffer(jpeg)
      || jpeg.length < 4
      || jpeg.length > MAXIMUM_CANONICAL_JPEG_BYTES
      || jpeg[0] !== 0xff
      || jpeg[1] !== 0xd8) {
    fail("decrypted image is not a bounded canonical JPEG");
  }
  const sofMarkers = new Set([
    0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
    0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
  ]);
  let cursor = 2;
  let entropy = false;
  let sawScan = false;
  let dimensions = null;
  while (cursor < jpeg.length) {
    if (entropy) {
      if (jpeg[cursor] !== 0xff) {
        cursor += 1;
        continue;
      }
      const markerStart = cursor;
      while (cursor < jpeg.length && jpeg[cursor] === 0xff) cursor += 1;
      if (cursor >= jpeg.length) fail("canonical JPEG entropy data is truncated");
      const marker = jpeg[cursor];
      if (marker === 0x00 || (marker >= 0xd0 && marker <= 0xd7)) {
        cursor += 1;
        continue;
      }
      cursor = markerStart;
      entropy = false;
      continue;
    }
    if (jpeg[cursor] !== 0xff) fail("canonical JPEG marker stream is invalid");
    while (cursor < jpeg.length && jpeg[cursor] === 0xff) cursor += 1;
    if (cursor >= jpeg.length) fail("canonical JPEG marker is truncated");
    const marker = jpeg[cursor];
    cursor += 1;
    if (marker === 0xd9) {
      if (!sawScan || dimensions === null || cursor !== jpeg.length) {
        fail("canonical JPEG end marker is invalid");
      }
      return dimensions;
    }
    if (marker === 0x00 || marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7)) {
      fail("canonical JPEG contains an invalid standalone marker");
    }
    if (marker === 0x01) continue;
    if (cursor > jpeg.length - 2) fail("canonical JPEG segment length is truncated");
    const segmentLength = jpeg.readUInt16BE(cursor);
    if (segmentLength < 2 || cursor > jpeg.length - segmentLength) {
      fail("canonical JPEG segment is out of bounds");
    }
    const segmentEnd = cursor + segmentLength;
    if ((marker >= 0xe0 && marker <= 0xef) || marker === 0xfe) {
      fail("canonical JPEG contains APP or comment metadata");
    }
    if (sofMarkers.has(marker)) {
      if (dimensions !== null || segmentLength < 8) fail("canonical JPEG frame is invalid");
      const precision = jpeg[cursor + 2];
      const height = jpeg.readUInt16BE(cursor + 3);
      const width = jpeg.readUInt16BE(cursor + 5);
      const components = jpeg[cursor + 7];
      if (segmentLength !== 8 + (components * 3)
          || precision !== 8
          || components !== 3
          || width < 1 || width > MAXIMUM_CANONICAL_PIXEL_DIMENSION
          || height < 1 || height > MAXIMUM_CANONICAL_PIXEL_DIMENSION) {
        fail("canonical JPEG frame does not match the privacy contract");
      }
      dimensions = Object.freeze({ width, height });
    }
    cursor = segmentEnd;
    if (marker === 0xda) {
      if (dimensions === null) fail("canonical JPEG scan precedes its frame");
      sawScan = true;
      entropy = true;
    }
  }
  fail("canonical JPEG has no valid end marker");
}

export function validateModerationCiphertextDescriptor(
  metadataValue,
  envelopeBytes,
  { enforceCurrentWindow = true } = {},
) {
  const metadata = validateModerationMetadata(metadataValue, { enforceCurrentWindow });
  if (!Buffer.isBuffer(envelopeBytes)
      || envelopeBytes.length !== metadata.ciphertextSize
      || envelopeBytes.length > MAXIMUM_REPORT_CIPHERTEXT_BYTES) {
    fail("ciphertext file size does not match metadata");
  }
  const expectedDigest = strictBase64url32(metadata.ciphertextSHA256);
  const actualDigest = createHash("sha256").update(envelopeBytes).digest();
  const digestMatches = timingSafeEqual(expectedDigest, actualDigest);
  expectedDigest.fill(0);
  actualDigest.fill(0);
  if (!digestMatches) fail("ciphertext SHA-256 does not match metadata");
  return metadata;
}

export function decryptModerationReport(metadataValue, envelopeBytes, privateKeyBytes) {
  const metadata = validateModerationCiphertextDescriptor(metadataValue, envelopeBytes);
  if (!Buffer.isBuffer(privateKeyBytes) || privateKeyBytes.length !== 32) {
    fail("moderation private key must be exactly 32 raw bytes");
  }

  const envelope = parseBinaryPlist(envelopeBytes);
  exactKeys(envelope, [
    "protocolVersion",
    "moderationKeyID",
    "ephemeralPublicKey",
    "ciphertext",
  ]);
  if (envelope.protocolVersion !== MOMENT_PROTOCOL_VERSION) fail("envelope protocol is unsupported");
  if (envelope.moderationKeyID !== metadata.moderationKeyId) fail("envelope key ID does not match metadata");
  if (!Buffer.isBuffer(envelope.ephemeralPublicKey)
      || envelope.ephemeralPublicKey.length !== 32) {
    fail("ephemeral X25519 public key is invalid");
  }
  if (!Buffer.isBuffer(envelope.ciphertext)
      || envelope.ciphertext.length < 29
      || envelope.ciphertext.length > MAXIMUM_REPORT_CIPHERTEXT_BYTES) {
    fail("inner ChaCha20-Poly1305 ciphertext is invalid");
  }

  const aad = canonicalFields([
    MODERATION_ENVELOPE_DOMAIN,
    String(MOMENT_PROTOCOL_VERSION),
    metadata.momentId,
    metadata.reporterParticipantId,
    metadata.reasonCode,
    metadata.moderationKeyId,
  ]);
  const salt = createHash("sha256").update(aad).digest();
  const privateDER = Buffer.concat([X25519_PKCS8_PREFIX, privateKeyBytes]);
  const publicDER = Buffer.concat([X25519_SPKI_PREFIX, envelope.ephemeralPublicKey]);
  let shared;
  let key;
  let plaintext;
  try {
    let recipientPrivate;
    let ephemeralPublic;
    try {
      recipientPrivate = createPrivateKey({ key: privateDER, format: "der", type: "pkcs8" });
      ephemeralPublic = createPublicKey({ key: publicDER, format: "der", type: "spki" });
      shared = diffieHellman({ privateKey: recipientPrivate, publicKey: ephemeralPublic });
      key = Buffer.from(hkdfSync("sha256", shared, salt, REPORT_HKDF_INFO, 32));
    } catch {
      fail("X25519 key agreement failed");
    }
    const combined = envelope.ciphertext;
    const nonce = combined.subarray(0, 12);
    const encrypted = combined.subarray(12, combined.length - 16);
    const tag = combined.subarray(combined.length - 16);
    try {
      const decipher = createDecipheriv(
        "chacha20-poly1305",
        key,
        nonce,
        { authTagLength: 16 },
      );
      decipher.setAAD(aad, { plaintextLength: encrypted.length });
      decipher.setAuthTag(tag);
      plaintext = Buffer.concat([decipher.update(encrypted), decipher.final()]);
    } catch {
      fail("report authentication failed; key, AAD, or ciphertext is wrong");
    }
    const report = parseBinaryPlist(plaintext);
    exactKeys(
      report,
      [
        "protocolVersion",
        "momentID",
        "reporterParticipantID",
        "reason",
        "reportedAt",
        "canonicalJPEG",
      ],
      ["capturedAt"],
    );
    if (report.protocolVersion !== MOMENT_PROTOCOL_VERSION
        || report.momentID !== metadata.momentId
        || report.reporterParticipantID !== metadata.reporterParticipantId
        || report.reason !== metadata.reasonCode) {
      fail("decrypted report identity does not match authenticated metadata");
    }
    if (!(report.reportedAt instanceof Date)
        || (Object.hasOwn(report, "capturedAt") && !(report.capturedAt instanceof Date))) {
      fail("decrypted report date is invalid");
    }
    if (!Buffer.isBuffer(report.canonicalJPEG)) fail("decrypted report image is invalid");
    const dimensions = validateCanonicalJPEG(report.canonicalJPEG);
    return {
      canonicalJPEG: Buffer.from(report.canonicalJPEG),
      dimensions,
    };
  } finally {
    aad.fill(0);
    salt.fill(0);
    privateDER.fill(0);
    publicDER.fill(0);
    shared?.fill(0);
    key?.fill(0);
    plaintext?.fill(0);
  }
}

export function createModerationReviewReceipt(metadataValue, canonicalJPEG) {
  // The receipt is a deletion binding, not new authority to review content.
  // The decrypt path has already enforced the active server content window.
  const metadata = validateModerationMetadata(metadataValue, { enforceCurrentWindow: false });
  validateCanonicalJPEG(canonicalJPEG);
  const reportReference = createHash("sha256")
    .update(Buffer.from(metadata.reportId, "utf8"))
    .digest();
  const ciphertextDigest = strictBase64url32(metadata.ciphertextSHA256);
  const imageDigest = createHash("sha256").update(canonicalJPEG).digest();
  const size = Buffer.alloc(4);
  size.writeUInt32BE(canonicalJPEG.length);
  const receipt = Buffer.concat([
    MODERATION_REVIEW_RECEIPT_MAGIC,
    reportReference,
    ciphertextDigest,
    size,
    imageDigest,
  ]);
  reportReference.fill(0);
  ciphertextDigest.fill(0);
  size.fill(0);
  imageDigest.fill(0);
  if (receipt.length !== MODERATION_REVIEW_RECEIPT_BYTES) {
    receipt.fill(0);
    fail("review receipt could not be created");
  }
  return receipt;
}

export function validateModerationReviewReceipt(
  receipt,
  metadataValue,
  canonicalJPEG,
) {
  // A valid receipt must remain usable to delete a local review artifact even
  // after the server-side seven-day content window has closed.
  const metadata = validateModerationMetadata(metadataValue, { enforceCurrentWindow: false });
  validateCanonicalJPEG(canonicalJPEG);
  if (!Buffer.isBuffer(receipt)
      || receipt.length !== MODERATION_REVIEW_RECEIPT_BYTES
      || !timingSafeEqual(
        receipt.subarray(0, MODERATION_REVIEW_RECEIPT_MAGIC.length),
        MODERATION_REVIEW_RECEIPT_MAGIC,
      )) {
    fail("review receipt is invalid");
  }
  const reportReference = createHash("sha256")
    .update(Buffer.from(metadata.reportId, "utf8"))
    .digest();
  const ciphertextDigest = strictBase64url32(metadata.ciphertextSHA256);
  const imageDigest = createHash("sha256").update(canonicalJPEG).digest();
  const reportOffset = MODERATION_REVIEW_RECEIPT_MAGIC.length;
  const ciphertextOffset = reportOffset + 32;
  const sizeOffset = ciphertextOffset + 32;
  const imageOffset = sizeOffset + 4;
  const valid = timingSafeEqual(receipt.subarray(reportOffset, ciphertextOffset), reportReference)
    && timingSafeEqual(receipt.subarray(ciphertextOffset, sizeOffset), ciphertextDigest)
    && receipt.readUInt32BE(sizeOffset) === canonicalJPEG.length
    && timingSafeEqual(receipt.subarray(imageOffset), imageDigest);
  reportReference.fill(0);
  ciphertextDigest.fill(0);
  imageDigest.fill(0);
  if (!valid) fail("review receipt does not match this report image");
}

function noFollowFlag() {
  return fsConstants.O_NOFOLLOW ?? 0;
}

function fsyncParentDirectory(path) {
  // Node/Win32 cannot open directory handles with the POSIX fsync contract.
  // File handles are still flushed; the runbook requires local NTFS and no
  // synced/snapshotted working directory for the remaining platform boundary.
  if (process.platform === "win32") return;
  let descriptor;
  try {
    descriptor = openSync(
      dirname(resolve(path)),
      fsConstants.O_RDONLY | (fsConstants.O_DIRECTORY ?? 0),
    );
    fsyncSync(descriptor);
  } catch {
    fail("parent directory could not be synchronized");
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

export function requireSafeLocalPath(path) {
  if (typeof path !== "string" || path.length === 0 || path.includes("\0")) {
    fail("file path is invalid");
  }
  const absolute = resolve(path);
  if (process.platform !== "win32") return absolute;

  // Refuse UNC, device, and extended-length namespaces. Moderation artifacts
  // must live on the reviewed local encrypted volume, never a network share.
  if (absolute.startsWith("\\\\")) {
    fail("Windows network and device paths are not allowed");
  }
  const root = parse(absolute).root;
  if (!/^[A-Za-z]:[\\/]$/u.test(root)
      || absolute.slice(root.length).includes(":")) {
    fail("Windows alternate data stream paths are not allowed");
  }
  const reserved = /^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$/iu;
  const components = absolute.slice(root.length).split(/[\\/]+/u);
  if (components.some((component) => reserved.test(component.replace(/[ .]+$/u, "")))) {
    fail("Windows reserved device names are not allowed");
  }
  return absolute;
}

export function readBoundedRegularFile(
  path,
  maximumBytes,
  description,
  {
    requireOwnerOnly = false,
    readFileFromDescriptor = readFileSync,
  } = {},
) {
  requireSafeLocalPath(path);
  let before;
  try {
    before = lstatSync(path, { bigint: true });
  } catch {
    fail(`${description} cannot be opened`);
  }
  const maximum = BigInt(maximumBytes);
  if (before.isSymbolicLink() || !before.isFile()
      || before.size < 1n || before.size > maximum || before.nlink !== 1n) {
    fail(`${description} is not a bounded regular file`);
  }
  if (requireOwnerOnly && process.platform !== "win32" && (before.mode & 0o077n) !== 0n) {
    fail(`${description} permissions are not owner-only`);
  }
  let descriptor;
  let value;
  let ownershipTransferred = false;
  try {
    descriptor = openSync(path, fsConstants.O_RDONLY | noFollowFlag());
    const opened = fstatSync(descriptor, { bigint: true });
    if (!opened.isFile()
        || opened.dev !== before.dev
        || opened.ino !== before.ino
        || opened.size !== before.size
        || opened.nlink !== 1n
        || (requireOwnerOnly && process.platform !== "win32" && (opened.mode & 0o077n) !== 0n)) {
      fail(`${description} changed while opening`);
    }
    const readValue = readFileFromDescriptor(descriptor);
    if (!Buffer.isBuffer(readValue)) fail(`${description} cannot be read safely`);
    value = readValue;
    if (BigInt(value.length) !== opened.size) fail(`${description} changed while reading`);
    // Complete descriptor cleanup before transferring Buffer ownership. If
    // close itself fails, the catch/finally path still clears the read bytes.
    closeSync(descriptor);
    descriptor = undefined;
    ownershipTransferred = true;
    return value;
  } catch (error) {
    if (error instanceof ModerationToolError) throw error;
    fail(`${description} cannot be read safely`);
  } finally {
    if (!ownershipTransferred) value?.fill(0);
    if (descriptor !== undefined) {
      try { closeSync(descriptor); } catch { /* retain the first safe failure */ }
    }
  }
}

function requireSafeParent(path) {
  requireSafeLocalPath(path);
  let parent;
  try {
    parent = lstatSync(dirname(resolve(path)));
  } catch {
    fail("output parent directory does not exist");
  }
  if (!parent.isDirectory() || parent.isSymbolicLink()) {
    fail("output parent must be a real directory");
  }
}

export function writeOwnerOnlyFile(path, bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 1) fail("output bytes are invalid");
  requireSafeParent(path);
  let descriptor;
  let created = false;
  try {
    descriptor = openSync(
      path,
      fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL | noFollowFlag(),
      0o600,
    );
    created = true;
    fchmodSync(descriptor, 0o600);
    writeFileSync(descriptor, bytes);
    fsyncSync(descriptor);
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    descriptor = undefined;
    if (created) {
      try {
        unlinkSync(path);
        fsyncParentDirectory(path);
      } catch { /* best effort cleanup */ }
    }
    if (error instanceof ModerationToolError) throw error;
    fail("output file could not be created safely");
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
  try {
    chmodSync(path, 0o600);
    if (process.platform !== "win32" && (lstatSync(path).mode & 0o077) !== 0) {
      unlinkSync(path);
      fsyncParentDirectory(path);
      fail("output permissions are not owner-only");
    }
    fsyncParentDirectory(path);
  } catch (error) {
    if (error instanceof ModerationToolError) throw error;
    try {
      unlinkSync(path);
      fsyncParentDirectory(path);
    } catch { /* best effort cleanup */ }
    fail("output permissions could not be verified");
  }
}

export function reportReferenceSHA256(reportID) {
  return createHash("sha256").update(Buffer.from(reportID, "utf8")).digest("base64url");
}

const AUDIT_EVENT_NAMES = new Set([
  "decrypt_succeeded",
  "local_plaintext_deletion_started",
  "local_ciphertext_deletion_started",
  "local_plaintext_deleted",
  "local_ciphertext_deleted",
  "local_deletion_failed",
]);

function canonicalAuditEventLine(event) {
  exactKeys(event, [
    "event",
    "at",
    "reportReferenceSHA256",
    "moderationKeyId",
    "ciphertextSHA256",
  ]);
  if (!AUDIT_EVENT_NAMES.has(event.event)) fail("audit event is invalid");
  if (!MODERATION_KEY_IDS.includes(event.moderationKeyId)
      || typeof event.at !== "string"
      || Number.isNaN(Date.parse(event.at))
      || new Date(event.at).toISOString() !== event.at) {
    fail("audit event fields are invalid");
  }
  const reportReference = strictBase64url32(event.reportReferenceSHA256);
  const ciphertextDigest = strictBase64url32(event.ciphertextSHA256);
  reportReference.fill(0);
  ciphertextDigest.fill(0);
  return JSON.stringify({
    event: event.event,
    at: event.at,
    reportReferenceSHA256: event.reportReferenceSHA256,
    moderationKeyId: event.moderationKeyId,
    ciphertextSHA256: event.ciphertextSHA256,
  });
}

function validateExistingAuditLog(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 1
      || bytes.length > MAXIMUM_AUDIT_LOG_BYTES
      || bytes[bytes.length - 1] !== 0x0a) {
    fail("audit log is not a bounded complete JSONL file");
  }
  const text = bytes.toString("utf8");
  if (!Buffer.from(text, "utf8").equals(bytes)) fail("audit log is not valid UTF-8");
  const lines = text.slice(0, -1).split("\n");
  if (lines.some((line) => line.length === 0)) fail("audit log contains an empty record");
  for (const line of lines) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      fail("audit log contains malformed JSON");
    }
    if (canonicalAuditEventLine(event) !== line) {
      fail("audit log contains a non-canonical event");
    }
  }
}

export function appendAuditEvent(path, event) {
  requireSafeLocalPath(path);
  const nextLine = `${canonicalAuditEventLine(event)}\n`;
  requireSafeParent(path);
  try {
    const existing = (() => {
      try {
        return lstatSync(path, { bigint: true });
      } catch (error) {
        if (error?.code === "ENOENT") return null;
        fail("audit log cannot be inspected safely");
      }
    })();
    if (existing !== null
        && (existing.isSymbolicLink() || !existing.isFile() || existing.nlink !== 1n
          || existing.size < 1n || existing.size > BigInt(MAXIMUM_AUDIT_LOG_BYTES)
          || (process.platform !== "win32" && (existing.mode & 0o077n) !== 0n))) {
      fail("audit log must be a regular file");
    }
    if (existing !== null) {
      const existingBytes = readBoundedRegularFile(
        path,
        MAXIMUM_AUDIT_LOG_BYTES,
        "audit log",
        { requireOwnerOnly: true },
      );
      try {
        if (BigInt(existingBytes.length) !== existing.size) {
          fail("audit log changed while validating");
        }
        validateExistingAuditLog(existingBytes);
      } finally {
        existingBytes.fill(0);
      }
    }
    if ((existing?.size ?? 0n) + BigInt(Buffer.byteLength(nextLine, "utf8"))
        > BigInt(MAXIMUM_AUDIT_LOG_BYTES)) {
      fail("audit log exceeds its size limit");
    }
    const flags = existing === null
      ? fsConstants.O_WRONLY | fsConstants.O_APPEND | fsConstants.O_CREAT
        | fsConstants.O_EXCL | noFollowFlag()
      : fsConstants.O_WRONLY | fsConstants.O_APPEND | noFollowFlag();
    const descriptor = openSync(
      path,
      flags,
      0o600,
    );
    try {
      const opened = fstatSync(descriptor, { bigint: true });
      if (!opened.isFile() || opened.nlink !== 1n
          || (process.platform !== "win32" && (opened.mode & 0o077n) !== 0n)
          || (existing !== null
            && (opened.dev !== existing.dev
              || opened.ino !== existing.ino
              || opened.size !== existing.size))) {
        fail("audit log changed while opening");
      }
      fchmodSync(descriptor, 0o600);
      writeFileSync(descriptor, nextLine, "utf8");
      fsyncSync(descriptor);
    } finally {
      closeSync(descriptor);
    }
    if (existing === null) fsyncParentDirectory(path);
  } catch (error) {
    if (error instanceof ModerationToolError) throw error;
    fail("audit log could not be written safely");
  }
}

export function deleteBoundedRegularFile(path, maximumBytes, expectedSHA256 = null) {
  requireSafeLocalPath(path);
  let entry;
  let identity;
  try {
    entry = lstatSync(path);
    identity = lstatSync(path, { bigint: true });
  } catch {
    fail("deletion target cannot be opened");
  }
  if (entry.isSymbolicLink() || !entry.isFile() || entry.size > maximumBytes) {
    fail("deletion target is not a bounded regular file");
  }
  if (identity.nlink !== 1n) {
    fail("deletion target must not have another hard link");
  }
  if (expectedSHA256 !== null) {
    if (!Buffer.isBuffer(expectedSHA256) || expectedSHA256.length !== 32) {
      fail("deletion descriptor is invalid");
    }
    const bytes = readBoundedRegularFile(path, maximumBytes, "deletion target");
    const actualSHA256 = createHash("sha256").update(bytes).digest();
    bytes.fill(0);
    const matches = timingSafeEqual(expectedSHA256, actualSHA256);
    actualSHA256.fill(0);
    if (!matches) fail("deletion target does not match its validated descriptor");
  }
  try {
    const current = lstatSync(path, { bigint: true });
    if (current.dev !== identity.dev
        || current.ino !== identity.ino
        || current.size !== identity.size
        || current.nlink !== 1n) {
      fail("deletion target changed after validation");
    }
    unlinkSync(path);
    fsyncParentDirectory(path);
  } catch (error) {
    if (error instanceof ModerationToolError) throw error;
    fail("deletion target could not be removed");
  }
}
