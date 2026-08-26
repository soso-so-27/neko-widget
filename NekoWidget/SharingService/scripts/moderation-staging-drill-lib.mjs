import {
  createCipheriv,
  createHash,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";
import {
  closeSync,
  constants as fsConstants,
  fchmodSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  rmdirSync,
  unlinkSync,
  writeSync,
} from "node:fs";
import { join } from "node:path";
import {
  MAXIMUM_METADATA_BYTES,
  MAXIMUM_AUDIT_LOG_BYTES,
  MODERATION_REVIEW_RECEIPT_BYTES,
  MAXIMUM_REPORT_CIPHERTEXT_BYTES,
  MODERATION_ALGORITHM,
  MODERATION_ENVELOPE_DOMAIN,
  MODERATION_EXPORT_SCHEMA,
  MODERATION_KEY_ID,
  MODERATION_REPORT_CONTENT_TTL_SECONDS,
  MOMENT_PROTOCOL_VERSION,
  parseModerationMetadata,
  moderationPublicKeySHA256,
  readBoundedRegularFile,
  reportReferenceSHA256,
  validateModerationReviewReceipt,
  validateCanonicalJPEG,
  validateModerationCiphertextDescriptor,
  validateExpectedPublicKeySHA256,
  validateModerationKeyId,
} from "./moderation-report-lib.mjs";
import {
  X25519_SPKI_PREFIX,
  extractRawX25519PublicKey,
  pathIsWithin,
  requireNode22,
  runWindowsSecurityPhase,
  validateExistingRestrictedFile,
  validateNewOutputDirectory,
} from "./moderation-staging-keygen-lib.mjs";

export const MODERATION_STAGING_DRILL_METADATA_FILENAME = "synthetic-export.json";
export const MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME = "synthetic-report.ciphertext";
export const MODERATION_STAGING_DRILL_REVIEW_FILENAME = "synthetic-review.jpg";
export const MODERATION_STAGING_DRILL_AUDIT_FILENAME = "synthetic-audit.jsonl";

export const SYNTHETIC_REPORT_ID = "staging_drill_report_v1";
export const SYNTHETIC_MOMENT_ID = "staging_drill_moment_v1";
export const SYNTHETIC_REPORTER_ID = "staging_drill_reporter_v1";
export const SYNTHETIC_REASON = "privacy";

const REPORT_HKDF_INFO = Buffer.from("jp.nekowidget.moment.report.v1", "utf8");
const APPLE_REFERENCE_DATE_UNIX_MILLISECONDS = 978_307_200_000;

// Fully decodable 1x1 baseline JPEG with no APPn or COM segment. It is
// fixed synthetic content; no user image, EXIF, GPS, thumbnail, or identifier
// can enter the drill bundle.
export const SYNTHETIC_CANONICAL_JPEG = Buffer.from(
  "/9j/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAb/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAABv/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AIsAuGX/2Q==",
  "base64",
);

export class ModerationStagingDrillError extends Error {
  constructor(message) {
    super(message);
    this.name = "ModerationStagingDrillError";
  }
}

function fail(message) {
  throw new ModerationStagingDrillError(message);
}

function byteWidth(value) {
  if (value <= 0xff) return 1;
  if (value <= 0xffff) return 2;
  if (value <= 0xffff_ffff) return 4;
  return 8;
}

function unsigned(value, width) {
  const output = Buffer.alloc(width);
  let remaining = BigInt(value);
  for (let index = width - 1; index >= 0; index -= 1) {
    output[index] = Number(remaining & 0xffn);
    remaining >>= 8n;
  }
  return output;
}

function countedMarker(type, length) {
  if (!Number.isSafeInteger(length) || length < 0) fail("binary plist length is invalid");
  if (length < 15) return Buffer.from([(type << 4) | length]);
  const width = byteWidth(length);
  const power = Math.log2(width);
  return Buffer.concat([
    Buffer.from([(type << 4) | 0x0f, 0x10 | power]),
    unsigned(length, width),
  ]);
}

/** Exact subset emitted by Foundation PropertyListEncoder(.binary). */
export function encodeSyntheticBinaryPlist(root) {
  const nodes = [];
  function add(value, depth = 0) {
    if (depth > 8 || nodes.length >= 64) fail("synthetic binary plist is out of bounds");
    if (Buffer.isBuffer(value)) {
      nodes.push({ type: "data", value });
    } else if (value instanceof Date && Number.isFinite(value.getTime())) {
      nodes.push({ type: "date", value });
    } else if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) {
      nodes.push({ type: "integer", value });
    } else if (typeof value === "string" && /^[\x20-\x7e]*$/u.test(value)) {
      nodes.push({ type: "string", value });
    } else if (value !== null && typeof value === "object" && !Array.isArray(value)) {
      const entries = Object.entries(value);
      const keys = entries.map(([key]) => add(key, depth + 1));
      const values = entries.map(([, item]) => add(item, depth + 1));
      nodes.push({ type: "dictionary", keys, values });
    } else {
      fail("synthetic binary plist contains an unsupported value");
    }
    return nodes.length - 1;
  }
  const topObject = add(root);
  const referenceWidth = byteWidth(nodes.length - 1);
  const encodeNode = (node) => {
    if (node.type === "data") {
      return Buffer.concat([countedMarker(0x4, node.value.length), node.value]);
    }
    if (node.type === "string") {
      const bytes = Buffer.from(node.value, "ascii");
      return Buffer.concat([countedMarker(0x5, bytes.length), bytes]);
    }
    if (node.type === "integer") {
      const output = Buffer.alloc(9);
      output[0] = 0x13;
      output.writeBigInt64BE(BigInt(node.value), 1);
      return output;
    }
    if (node.type === "date") {
      const output = Buffer.alloc(9);
      output[0] = 0x33;
      output.writeDoubleBE(
        (node.value.getTime() - APPLE_REFERENCE_DATE_UNIX_MILLISECONDS) / 1_000,
        1,
      );
      return output;
    }
    return Buffer.concat([
      countedMarker(0xd, node.keys.length),
      ...node.keys.map((item) => unsigned(item, referenceWidth)),
      ...node.values.map((item) => unsigned(item, referenceWidth)),
    ]);
  };
  const encoded = nodes.map(encodeNode);
  const header = Buffer.from("bplist00", "ascii");
  const offsets = [];
  let nextOffset = header.length;
  for (const object of encoded) {
    offsets.push(nextOffset);
    nextOffset += object.length;
  }
  const offsetWidth = byteWidth(nextOffset);
  const offsetTable = Buffer.concat(offsets.map((offset) => unsigned(offset, offsetWidth)));
  const trailer = Buffer.alloc(32);
  trailer[6] = offsetWidth;
  trailer[7] = referenceWidth;
  unsigned(nodes.length, 8).copy(trailer, 8);
  unsigned(topObject, 8).copy(trailer, 16);
  unsigned(nextOffset, 8).copy(trailer, 24);
  return Buffer.concat([header, ...encoded, offsetTable, trailer]);
}

export function canonicalFields(fields) {
  if (!Array.isArray(fields) || fields.length !== 6
      || fields.some((field) => typeof field !== "string")) {
    fail("synthetic AAD fields are invalid");
  }
  return Buffer.concat(fields.flatMap((field) => {
    const value = Buffer.from(field, "utf8");
    const length = Buffer.alloc(4);
    length.writeUInt32BE(value.length);
    return [length, value];
  }));
}

export function parseCanonicalModerationPublicKey(publicKeyBytes) {
  if (!Buffer.isBuffer(publicKeyBytes) || publicKeyBytes.length !== 43
      || publicKeyBytes.includes(0x0a) || publicKeyBytes.includes(0x0d)
      || publicKeyBytes.some((byte) => byte > 0x7f)) {
    fail("staging moderation public key must be exactly 43 ASCII bytes without a newline");
  }
  const text = publicKeyBytes.toString("ascii");
  if (!/^[A-Za-z0-9_-]{43}$/u.test(text)) {
    fail("staging moderation public key is not canonical base64url");
  }
  const decoded = Buffer.from(text, "base64url");
  if (decoded.length !== 32 || decoded.toString("base64url") !== text) {
    decoded.fill(0);
    fail("staging moderation public key is not canonical base64url");
  }
  return decoded;
}

export function createSyntheticModerationBundle(
  recipientPublicRaw,
  {
    nowMilliseconds = Date.now(),
    moderationKeyId = MODERATION_KEY_ID,
    keyPairFactory = () => generateKeyPairSync("x25519"),
    nonceFactory = () => randomBytes(12),
  } = {},
) {
  requireNode22();
  validateModerationKeyId(moderationKeyId);
  if (!Buffer.isBuffer(recipientPublicRaw) || recipientPublicRaw.length !== 32) {
    fail("recipient public key must be exactly 32 raw bytes");
  }
  if (!Number.isSafeInteger(nowMilliseconds) || nowMilliseconds <= 0) {
    fail("synthetic drill clock is invalid");
  }
  validateCanonicalJPEG(SYNTHETIC_CANONICAL_JPEG);

  const committedAt = Math.floor(nowMilliseconds / 1_000) - 1;
  const reportedAt = new Date(committedAt * 1_000);
  const capturedAt = new Date((committedAt - 1) * 1_000);
  let recipientDER;
  let ephemeralPublicRaw;
  let shared;
  let aad;
  let salt;
  let key;
  let nonce;
  let plaintext;
  let encrypted;
  let tag;
  let combined;
  let envelopeBytes;
  let metadataBytes;
  try {
    recipientDER = Buffer.concat([X25519_SPKI_PREFIX, recipientPublicRaw]);
    const recipientPublic = createPublicKey({ key: recipientDER, format: "der", type: "spki" });
    const ephemeral = keyPairFactory();
    if (ephemeral === null || typeof ephemeral !== "object"
        || ephemeral.privateKey === undefined || ephemeral.publicKey === undefined) {
      fail("ephemeral X25519 key generation failed");
    }
    ephemeralPublicRaw = extractRawX25519PublicKey(ephemeral.publicKey);
    try {
      shared = diffieHellman({ privateKey: ephemeral.privateKey, publicKey: recipientPublic });
    } catch {
      fail("ephemeral X25519 key agreement failed");
    }
    if (!Buffer.isBuffer(shared) || shared.length !== 32
        || shared.every((byte) => byte === 0)) {
      fail("ephemeral X25519 key agreement returned an invalid secret");
    }

    aad = canonicalFields([
      MODERATION_ENVELOPE_DOMAIN,
      String(MOMENT_PROTOCOL_VERSION),
      SYNTHETIC_MOMENT_ID,
      SYNTHETIC_REPORTER_ID,
      SYNTHETIC_REASON,
      moderationKeyId,
    ]);
    salt = createHash("sha256").update(aad).digest();
    key = Buffer.from(hkdfSync("sha256", shared, salt, REPORT_HKDF_INFO, 32));
    nonce = nonceFactory();
    if (!Buffer.isBuffer(nonce) || nonce.length !== 12) {
      fail("synthetic ChaCha20-Poly1305 nonce is invalid");
    }
    plaintext = encodeSyntheticBinaryPlist({
      protocolVersion: MOMENT_PROTOCOL_VERSION,
      momentID: SYNTHETIC_MOMENT_ID,
      reporterParticipantID: SYNTHETIC_REPORTER_ID,
      reason: SYNTHETIC_REASON,
      capturedAt,
      reportedAt,
      canonicalJPEG: SYNTHETIC_CANONICAL_JPEG,
    });
    const cipher = createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
    cipher.setAAD(aad, { plaintextLength: plaintext.length });
    encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    tag = cipher.getAuthTag();
    combined = Buffer.concat([nonce, encrypted, tag]);
    envelopeBytes = encodeSyntheticBinaryPlist({
      protocolVersion: MOMENT_PROTOCOL_VERSION,
      moderationKeyID: moderationKeyId,
      ephemeralPublicKey: ephemeralPublicRaw,
      ciphertext: combined,
    });
    if (envelopeBytes.length < 29
        || envelopeBytes.length > MAXIMUM_REPORT_CIPHERTEXT_BYTES) {
      fail("synthetic ciphertext envelope is outside the protocol bound");
    }
    const metadata = {
      schema: MODERATION_EXPORT_SCHEMA,
      protocolVersion: MOMENT_PROTOCOL_VERSION,
      envelopeDomain: MODERATION_ENVELOPE_DOMAIN,
      algorithm: MODERATION_ALGORITHM,
      reportId: SYNTHETIC_REPORT_ID,
      momentId: SYNTHETIC_MOMENT_ID,
      reporterParticipantId: SYNTHETIC_REPORTER_ID,
      reasonCode: SYNTHETIC_REASON,
      moderationKeyId,
      ciphertextSize: envelopeBytes.length,
      ciphertextSHA256: createHash("sha256").update(envelopeBytes).digest("base64url"),
      committedAt,
      contentExpiresAt: committedAt + MODERATION_REPORT_CONTENT_TTL_SECONDS,
    };
    metadataBytes = Buffer.from(`${JSON.stringify(metadata)}\n`, "utf8");
    if (metadataBytes.length < 1 || metadataBytes.length > MAXIMUM_METADATA_BYTES) {
      fail("synthetic metadata is outside the protocol bound");
    }
    const parsed = parseModerationMetadata(metadataBytes.toString("utf8"));
    validateModerationCiphertextDescriptor(parsed, envelopeBytes);
    return {
      metadataBytes: Buffer.from(metadataBytes),
      envelopeBytes: Buffer.from(envelopeBytes),
      metadata: parsed,
    };
  } catch (error) {
    if (error instanceof ModerationStagingDrillError) throw error;
    fail("synthetic moderation bundle could not be generated safely");
  } finally {
    recipientDER?.fill(0);
    ephemeralPublicRaw?.fill(0);
    shared?.fill(0);
    aad?.fill(0);
    salt?.fill(0);
    key?.fill(0);
    nonce?.fill(0);
    plaintext?.fill(0);
    encrypted?.fill(0);
    tag?.fill(0);
    combined?.fill(0);
    envelopeBytes?.fill(0);
    metadataBytes?.fill(0);
  }
}

function noFollowFlag() {
  return fsConstants.O_NOFOLLOW ?? 0;
}

function reserveOutput(path, platform) {
  let descriptor;
  let identity;
  try {
    descriptor = openSync(
      path,
      fsConstants.O_RDWR | fsConstants.O_CREAT | fsConstants.O_EXCL | noFollowFlag(),
      0o600,
    );
    if (platform !== "win32") fchmodSync(descriptor, 0o600);
    identity = fstatSync(descriptor, { bigint: true });
    if (!identity.isFile() || identity.isSymbolicLink?.() || identity.nlink !== 1n
        || identity.size !== 0n
        || (platform !== "win32" && (identity.mode & 0o077n) !== 0n)) {
      fail("a drill output could not be reserved safely");
    }
    return { descriptor, identity };
  } catch (error) {
    if (descriptor !== undefined) {
      try { closeSync(descriptor); } catch { /* cleanup continues */ }
    }
    throw error;
  }
}

function sameIdentity(entry, identity) {
  return entry.isFile() && !entry.isSymbolicLink()
    && entry.nlink === 1n && entry.dev === identity.dev && entry.ino === identity.ino;
}

function safelyRemove(path, identity) {
  if (identity === undefined) return false;
  try {
    const entry = lstatSync(path, { bigint: true });
    if (!sameIdentity(entry, identity)) return false;
    unlinkSync(path);
    return true;
  } catch (error) {
    return error?.code === "ENOENT";
  }
}

function verifyOutputPath(path, file, expectedBytes, platform) {
  const opened = fstatSync(file.descriptor, { bigint: true });
  const named = lstatSync(path, { bigint: true });
  if (!sameIdentity(opened, file.identity) || !sameIdentity(named, file.identity)
      || opened.size !== BigInt(expectedBytes)
      || (platform !== "win32" && (opened.mode & 0o077n) !== 0n)) {
    fail("a drill output failed its final identity, size, link, or permission check");
  }
}

function readExactFromDescriptor(descriptor, expectedBytes) {
  const output = Buffer.alloc(expectedBytes);
  if (readSync(descriptor, output, 0, expectedBytes, 0) !== expectedBytes) {
    output.fill(0);
    fail("a drill output could not be read back completely");
  }
  return output;
}

export function readValidatedModerationPublicKey(validated) {
  if (validated === null || typeof validated !== "object"
      || typeof validated.path !== "string" || validated.bytes !== 43) {
    fail("validated public key descriptor is invalid");
  }
  let descriptor;
  let bytes;
  try {
    const before = lstatSync(validated.path, { bigint: true });
    if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1n
        || before.size !== 43n || before.dev !== validated.device
        || before.ino !== validated.inode) {
      fail("staging moderation public key identity changed before reading");
    }
    descriptor = openSync(validated.path, fsConstants.O_RDONLY | noFollowFlag());
    const opened = fstatSync(descriptor, { bigint: true });
    if (!opened.isFile() || opened.nlink !== 1n || opened.size !== 43n
        || opened.dev !== before.dev || opened.ino !== before.ino) {
      fail("staging moderation public key changed while opening");
    }
    bytes = readFileSync(descriptor);
    if (bytes.length !== 43) fail("staging moderation public key changed while reading");
    return parseCanonicalModerationPublicKey(bytes);
  } catch (error) {
    if (error instanceof ModerationStagingDrillError) throw error;
    fail("staging moderation public key could not be read safely");
  } finally {
    bytes?.fill(0);
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

export function createDrillFilesInValidatedDirectory(
  validatedDirectory,
  validatedPublicKey,
  {
    platform = process.platform,
    moderationKeyId = MODERATION_KEY_ID,
    expectedPublicKeySHA256,
    bundleFactory = createSyntheticModerationBundle,
    postWriteVerifier = () => {},
  } = {},
) {
  if (validatedDirectory === null || typeof validatedDirectory !== "object"
      || typeof validatedDirectory.path !== "string"
      || validatedDirectory.prepared !== true) {
    fail("validated drill directory descriptor is invalid");
  }
  validateModerationKeyId(moderationKeyId);
  validateExpectedPublicKeySHA256(expectedPublicKeySHA256);
  if (pathIsWithin(validatedDirectory.path, validatedPublicKey?.directory ?? "", platform)
      || pathIsWithin(validatedPublicKey?.directory ?? "", validatedDirectory.path, platform)) {
    fail("the drill and key directories must be canonically disjoint");
  }
  const outputDirectory = validatedDirectory.path;
  const metadataPath = join(outputDirectory, MODERATION_STAGING_DRILL_METADATA_FILENAME);
  const ciphertextPath = join(outputDirectory, MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME);
  let directoryIdentity;
  let metadataFile;
  let ciphertextFile;
  let recipientPublicRaw;
  let bundle;
  let ciphertextReadback;
  let metadataReadback;
  let success = false;
  try {
    directoryIdentity = lstatSync(outputDirectory, { bigint: true });
    if (!directoryIdentity.isDirectory() || directoryIdentity.isSymbolicLink()
        || readdirSync(outputDirectory).length !== 0) {
      fail("drill directory must be a prepared empty real directory");
    }
    // Reserve every fixed output before key agreement. Collisions therefore
    // fail before any ephemeral secret or plaintext plist exists.
    ciphertextFile = reserveOutput(ciphertextPath, platform);
    metadataFile = reserveOutput(metadataPath, platform);
    recipientPublicRaw = readValidatedModerationPublicKey(validatedPublicKey);
    if (moderationPublicKeySHA256(recipientPublicRaw) !== expectedPublicKeySHA256) {
      fail("staging moderation public-key fingerprint does not match the reviewed value");
    }
    bundle = bundleFactory(recipientPublicRaw, { moderationKeyId });
    if (!Buffer.isBuffer(bundle?.envelopeBytes)
        || bundle.envelopeBytes.length < 29
        || bundle.envelopeBytes.length > MAXIMUM_REPORT_CIPHERTEXT_BYTES
        || !Buffer.isBuffer(bundle?.metadataBytes)
        || bundle.metadataBytes.length < 1
        || bundle.metadataBytes.length > MAXIMUM_METADATA_BYTES) {
      fail("synthetic bundle factory returned invalid bounded outputs");
    }

    // Ciphertext first, descriptor last. A crash cannot leave a descriptor
    // that appears complete without the ciphertext data write having flushed.
    if (writeSync(ciphertextFile.descriptor, bundle.envelopeBytes, 0,
      bundle.envelopeBytes.length, 0) !== bundle.envelopeBytes.length) {
      fail("synthetic ciphertext could not be written completely");
    }
    fsyncSync(ciphertextFile.descriptor);
    if (writeSync(metadataFile.descriptor, bundle.metadataBytes, 0,
      bundle.metadataBytes.length, 0) !== bundle.metadataBytes.length) {
      fail("synthetic metadata could not be written completely");
    }
    fsyncSync(metadataFile.descriptor);
    verifyOutputPath(ciphertextPath, ciphertextFile, bundle.envelopeBytes.length, platform);
    verifyOutputPath(metadataPath, metadataFile, bundle.metadataBytes.length, platform);

    ciphertextReadback = readExactFromDescriptor(
      ciphertextFile.descriptor,
      bundle.envelopeBytes.length,
    );
    metadataReadback = readExactFromDescriptor(metadataFile.descriptor, bundle.metadataBytes.length);
    const ciphertextMatches = timingSafeEqual(ciphertextReadback, bundle.envelopeBytes);
    const metadataMatches = timingSafeEqual(metadataReadback, bundle.metadataBytes);
    if (!ciphertextMatches || !metadataMatches) {
      fail("synthetic drill output readback does not match generated bytes");
    }
    const parsed = parseModerationMetadata(metadataReadback.toString("utf8"));
    if (parsed.moderationKeyId !== moderationKeyId) {
      fail("synthetic bundle key ID does not match the reviewed value");
    }
    validateModerationCiphertextDescriptor(parsed, ciphertextReadback);

    postWriteVerifier(Object.freeze({ directory: outputDirectory }));
    verifyOutputPath(ciphertextPath, ciphertextFile, bundle.envelopeBytes.length, platform);
    verifyOutputPath(metadataPath, metadataFile, bundle.metadataBytes.length, platform);
    const finalDirectory = lstatSync(outputDirectory, { bigint: true });
    if (!finalDirectory.isDirectory() || finalDirectory.isSymbolicLink()
        || finalDirectory.dev !== directoryIdentity.dev
        || finalDirectory.ino !== directoryIdentity.ino
        || readdirSync(outputDirectory).sort().join("\0") !== [
          MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME,
          MODERATION_STAGING_DRILL_METADATA_FILENAME,
        ].sort().join("\0")) {
      fail("synthetic drill directory identity or fixed file set changed");
    }
    success = true;
    return Object.freeze({
      directory: outputDirectory,
      metadataFilename: MODERATION_STAGING_DRILL_METADATA_FILENAME,
      ciphertextFilename: MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME,
    });
  } catch (error) {
    if (error instanceof ModerationStagingDrillError) throw error;
    fail("synthetic moderation drill files could not be created safely");
  } finally {
    recipientPublicRaw?.fill(0);
    bundle?.metadataBytes?.fill(0);
    bundle?.envelopeBytes?.fill(0);
    ciphertextReadback?.fill(0);
    metadataReadback?.fill(0);
    if (metadataFile?.descriptor !== undefined) {
      try { closeSync(metadataFile.descriptor); } catch { /* cleanup continues */ }
    }
    if (ciphertextFile?.descriptor !== undefined) {
      try { closeSync(ciphertextFile.descriptor); } catch { /* cleanup continues */ }
    }
    if (!success) {
      const metadataRemoved = safelyRemove(metadataPath, metadataFile?.identity);
      const ciphertextRemoved = safelyRemove(ciphertextPath, ciphertextFile?.identity);
      if (metadataRemoved && ciphertextRemoved) {
        try {
          const current = lstatSync(outputDirectory, { bigint: true });
          if (current.isDirectory() && !current.isSymbolicLink()
              && current.dev === directoryIdentity?.dev && current.ino === directoryIdentity?.ino
              && readdirSync(outputDirectory).length === 0) {
            rmdirSync(outputDirectory);
          }
        } catch { /* restricted partial output must be quarantined */ }
      }
    }
  }
}

function verifyFixedSyntheticMetadata(metadata, expectedModerationKeyId) {
  if (expectedModerationKeyId !== undefined) {
    validateModerationKeyId(expectedModerationKeyId);
  }
  if (metadata.reportId !== SYNTHETIC_REPORT_ID
      || metadata.momentId !== SYNTHETIC_MOMENT_ID
      || metadata.reporterParticipantId !== SYNTHETIC_REPORTER_ID
      || metadata.reasonCode !== SYNTHETIC_REASON
      || (expectedModerationKeyId !== undefined
        && metadata.moderationKeyId !== expectedModerationKeyId)) {
    fail("drill metadata is not the fixed synthetic fixture");
  }
}

function verifySyntheticDrillAuditTransitions(metadataBytes, auditBytes, expectedNames) {
  if (!Buffer.isBuffer(metadataBytes) || metadataBytes.length < 1
      || metadataBytes.length > MAXIMUM_METADATA_BYTES
      || !Buffer.isBuffer(auditBytes) || auditBytes.length < 1
      || auditBytes.length > MAXIMUM_AUDIT_LOG_BYTES
      || auditBytes[auditBytes.length - 1] !== 0x0a) {
    fail("completed synthetic drill evidence is not bounded and complete");
  }
  const metadata = parseModerationMetadata(metadataBytes.toString("utf8"), {
    enforceCurrentWindow: false,
  });
  verifyFixedSyntheticMetadata(metadata);
  const text = auditBytes.toString("utf8");
  if (!Buffer.from(text, "utf8").equals(auditBytes)) {
    fail("completed drill audit is not valid UTF-8");
  }
  const lines = text.slice(0, -1).split("\n");
  if (lines.length !== expectedNames.length || lines.some((line) => line.length === 0)) {
    fail("drill audit does not contain the exact transition set");
  }
  const reportReference = reportReferenceSHA256(metadata.reportId);
  for (let index = 0; index < lines.length; index += 1) {
    let event;
    try {
      event = JSON.parse(lines[index]);
    } catch {
      fail("drill audit contains malformed JSON");
    }
    if (event === null || typeof event !== "object" || Array.isArray(event)
        || Object.keys(event).sort().join("\0") !== [
          "event",
          "at",
          "reportReferenceSHA256",
          "moderationKeyId",
          "ciphertextSHA256",
        ].sort().join("\0")
        || event.event !== expectedNames[index]
        || event.reportReferenceSHA256 !== reportReference
        || event.moderationKeyId !== metadata.moderationKeyId
        || event.ciphertextSHA256 !== metadata.ciphertextSHA256
        || typeof event.at !== "string" || Number.isNaN(Date.parse(event.at))
        || new Date(event.at).toISOString() !== event.at
        || JSON.stringify({
          event: event.event,
          at: event.at,
          reportReferenceSHA256: event.reportReferenceSHA256,
          moderationKeyId: event.moderationKeyId,
          ciphertextSHA256: event.ciphertextSHA256,
        }) !== lines[index]) {
      fail("drill audit contains a non-canonical or mismatched transition");
    }
  }
  return Object.freeze({ complete: true });
}

export function verifyCompletedSyntheticDrillAudit(metadataBytes, auditBytes) {
  return verifySyntheticDrillAuditTransitions(metadataBytes, auditBytes, [
    "decrypt_succeeded",
    "local_plaintext_deletion_started",
    "local_plaintext_deleted",
    "local_ciphertext_deletion_started",
    "local_ciphertext_deleted",
  ]);
}

function requireExactDirectoryFiles(directory, expected) {
  let entry;
  let items;
  try {
    entry = lstatSync(directory, { bigint: true });
    items = readdirSync(directory).sort();
  } catch {
    fail("synthetic drill directory cannot be inspected safely");
  }
  if (!entry.isDirectory() || entry.isSymbolicLink()
      || items.join("\0") !== [...expected].sort().join("\0")) {
    fail("synthetic drill directory does not contain the exact phase file set");
  }
}

function readAndVerifyFixedSyntheticBundle(directory, expectedModerationKeyId) {
  let metadataBytes;
  let envelopeBytes;
  try {
    metadataBytes = readBoundedRegularFile(
      join(directory, MODERATION_STAGING_DRILL_METADATA_FILENAME),
      MAXIMUM_METADATA_BYTES,
      "synthetic drill metadata",
      { requireOwnerOnly: true },
    );
    envelopeBytes = readBoundedRegularFile(
      join(directory, MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME),
      MAXIMUM_REPORT_CIPHERTEXT_BYTES,
      "synthetic drill ciphertext",
      { requireOwnerOnly: true },
    );
    const metadata = parseModerationMetadata(metadataBytes.toString("utf8"));
    verifyFixedSyntheticMetadata(metadata, expectedModerationKeyId);
    validateModerationCiphertextDescriptor(metadata, envelopeBytes);
    return {
      metadata,
      metadataBytes: Buffer.from(metadataBytes),
      envelopeBytes: Buffer.from(envelopeBytes),
    };
  } finally {
    metadataBytes?.fill(0);
    envelopeBytes?.fill(0);
  }
}

export function verifySyntheticDrillBundleDirectory(directory, expectedModerationKeyId) {
  requireExactDirectoryFiles(directory, [
    MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME,
    MODERATION_STAGING_DRILL_METADATA_FILENAME,
  ]);
  const bundle = readAndVerifyFixedSyntheticBundle(directory, expectedModerationKeyId);
  try {
    return Object.freeze({ verified: true });
  } finally {
    bundle.metadataBytes.fill(0);
    bundle.envelopeBytes.fill(0);
  }
}

export function verifySyntheticDrillReviewDirectory(directory, expectedModerationKeyId) {
  requireExactDirectoryFiles(directory, [
    MODERATION_STAGING_DRILL_AUDIT_FILENAME,
    MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME,
    MODERATION_STAGING_DRILL_METADATA_FILENAME,
    MODERATION_STAGING_DRILL_REVIEW_FILENAME,
    `${MODERATION_STAGING_DRILL_REVIEW_FILENAME}.receipt`,
  ]);
  const bundle = readAndVerifyFixedSyntheticBundle(directory, expectedModerationKeyId);
  let reviewBytes;
  let receiptBytes;
  let auditBytes;
  try {
    reviewBytes = readBoundedRegularFile(
      join(directory, MODERATION_STAGING_DRILL_REVIEW_FILENAME),
      SYNTHETIC_CANONICAL_JPEG.length,
      "synthetic drill review",
      { requireOwnerOnly: true },
    );
    if (reviewBytes.length !== SYNTHETIC_CANONICAL_JPEG.length
        || !timingSafeEqual(reviewBytes, SYNTHETIC_CANONICAL_JPEG)) {
      fail("review JPEG is not byte-exact fixed synthetic content");
    }
    receiptBytes = readBoundedRegularFile(
      join(directory, `${MODERATION_STAGING_DRILL_REVIEW_FILENAME}.receipt`),
      MODERATION_REVIEW_RECEIPT_BYTES,
      "synthetic drill review receipt",
      { requireOwnerOnly: true },
    );
    validateModerationReviewReceipt(receiptBytes, bundle.metadata, reviewBytes);
    auditBytes = readBoundedRegularFile(
      join(directory, MODERATION_STAGING_DRILL_AUDIT_FILENAME),
      MAXIMUM_AUDIT_LOG_BYTES,
      "synthetic drill audit",
      { requireOwnerOnly: true },
    );
    verifySyntheticDrillAuditTransitions(bundle.metadataBytes, auditBytes, ["decrypt_succeeded"]);
    return Object.freeze({ verified: true });
  } finally {
    bundle.metadataBytes.fill(0);
    bundle.envelopeBytes.fill(0);
    reviewBytes?.fill(0);
    receiptBytes?.fill(0);
    auditBytes?.fill(0);
  }
}

export function verifyCompletedSyntheticDrillDirectory(directory, expectedModerationKeyId) {
  const expected = [
    MODERATION_STAGING_DRILL_AUDIT_FILENAME,
    MODERATION_STAGING_DRILL_METADATA_FILENAME,
  ].sort();
  requireExactDirectoryFiles(directory, expected);
  let metadataBytes;
  let auditBytes;
  try {
    metadataBytes = readBoundedRegularFile(
      join(directory, MODERATION_STAGING_DRILL_METADATA_FILENAME),
      MAXIMUM_METADATA_BYTES,
      "synthetic drill metadata",
      { requireOwnerOnly: true },
    );
    auditBytes = readBoundedRegularFile(
      join(directory, MODERATION_STAGING_DRILL_AUDIT_FILENAME),
      MAXIMUM_AUDIT_LOG_BYTES,
      "synthetic drill audit",
      { requireOwnerOnly: true },
    );
    const metadata = parseModerationMetadata(metadataBytes.toString("utf8"), {
      enforceCurrentWindow: false,
    });
    verifyFixedSyntheticMetadata(metadata, expectedModerationKeyId);
    return verifyCompletedSyntheticDrillAudit(metadataBytes, auditBytes);
  } finally {
    metadataBytes?.fill(0);
    auditBytes?.fill(0);
  }
}

export function generateStagingModerationDrillFiles({
  publicKeyFile,
  moderationKeyId,
  expectedPublicKeySHA256,
  outputDirectory,
  confirmLocalEncryptedNoSync,
} = {}) {
  requireNode22();
  if (process.platform !== "win32") {
    fail("operational staging moderation drills are supported only on Windows");
  }
  if (confirmLocalEncryptedNoSync !== true) {
    fail("explicit local encrypted no-sync confirmation is required");
  }
  if (typeof publicKeyFile !== "string" || publicKeyFile.length === 0) {
    fail("the fixed staging public-key file is required");
  }
  validateModerationKeyId(moderationKeyId);
  validateExpectedPublicKeySHA256(expectedPublicKeySHA256);
  const validatedPublicKey = validateExistingRestrictedFile(
    publicKeyFile,
    { expectedFilename: `${moderationKeyId}.public.base64url`, expectedBytes: 43 },
  );
  runWindowsSecurityPhase("ValidateKeyDirectory", validatedPublicKey.directory, moderationKeyId);
  const validatedDirectory = validateNewOutputDirectory(outputDirectory, {
    allowPreparedWindowsDirectory: true,
  });
  if (pathIsWithin(validatedDirectory.path, validatedPublicKey.directory, "win32")
      || pathIsWithin(validatedPublicKey.directory, validatedDirectory.path, "win32")) {
    fail("the drill and key directories must be canonically disjoint");
  }
  runWindowsSecurityPhase("VerifyDrillDirectory", validatedDirectory.path);
  return createDrillFilesInValidatedDirectory(validatedDirectory, validatedPublicKey, {
    moderationKeyId,
    expectedPublicKeySHA256,
    postWriteVerifier: ({ directory }) => runWindowsSecurityPhase("HardenDrillFiles", directory),
  });
}
