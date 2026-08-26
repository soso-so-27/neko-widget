import assert from "node:assert/strict";
import {
  createCipheriv,
  createHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  hkdfSync,
} from "node:crypto";
import {
  chmodSync,
  existsSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";
import {
  MAXIMUM_REPORT_CIPHERTEXT_BYTES,
  MODERATION_ALGORITHM,
  MODERATION_ENVELOPE_DOMAIN,
  MODERATION_EXPORT_SCHEMA,
  readBoundedRegularFile,
} from "../scripts/moderation-report-lib.mjs";

// Synthetic test-only X25519 seeds. These are not production key material.
const FIXTURE_RECIPIENT_PRIVATE_KEY = Buffer.from(
  "70076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c6a",
  "hex",
);
const FIXTURE_WRONG_PRIVATE_KEY = Buffer.from(
  "18076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c55",
  "hex",
);
const FIXTURE_EPHEMERAL_PRIVATE_KEY = Buffer.from(
  "58ab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e055",
  "hex",
);
const X25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
const X25519_SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex");
const TOOL = fileURLToPath(new URL("../scripts/moderation-report-tool.mjs", import.meta.url));
const WINDOWS_PORTABLE_CLI_SKIP_REASON = [
  "portable CLI fixtures use arbitrary temporary filenames and intentionally do not bypass",
  "the mandatory Windows BitLocker/NTFS/exact-ACL boundary; Ubuntu CI runs this full suite",
].join(" ");

function portableCliTest(name, fn) {
  return test(name, {
    skip: process.platform === "win32" ? WINDOWS_PORTABLE_CLI_SKIP_REASON : false,
  }, fn);
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
  if (length < 15) return Buffer.from([(type << 4) | length]);
  const width = byteWidth(length);
  const power = Math.log2(width);
  return Buffer.concat([
    Buffer.from([(type << 4) | 0x0f, 0x10 | power]),
    unsigned(length, width),
  ]);
}

/** Minimal fixture encoder for the exact Foundation binary-plist value types. */
function binaryPlist(root) {
  const nodes = [];
  function add(value) {
    if (Buffer.isBuffer(value)) {
      nodes.push({ type: "data", value });
    } else if (value instanceof Date) {
      nodes.push({ type: "date", value });
    } else if (typeof value === "number" && Number.isSafeInteger(value)) {
      nodes.push({ type: "integer", value });
    } else if (typeof value === "string") {
      assert.match(value, /^[\x20-\x7e]*$/u);
      nodes.push({ type: "string", value });
    } else if (value !== null && typeof value === "object" && !Array.isArray(value)) {
      const entries = Object.entries(value);
      const keys = entries.map(([key]) => add(key));
      const values = entries.map(([, item]) => add(item));
      nodes.push({ type: "dictionary", keys, values });
    } else {
      throw new Error("unsupported fixture plist value");
    }
    return nodes.length - 1;
  }
  const topObject = add(root);
  const referenceWidth = byteWidth(nodes.length - 1);
  function encodeNode(node) {
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
      output.writeDoubleBE((node.value.getTime() - 978_307_200_000) / 1_000, 1);
      return output;
    }
    const references = [
      ...node.keys.map((item) => unsigned(item, referenceWidth)),
      ...node.values.map((item) => unsigned(item, referenceWidth)),
    ];
    return Buffer.concat([countedMarker(0xd, node.keys.length), ...references]);
  }
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

function rawX25519Private(bytes) {
  return createPrivateKey({
    key: Buffer.concat([X25519_PKCS8_PREFIX, bytes]),
    format: "der",
    type: "pkcs8",
  });
}

function rawX25519Public(privateBytes) {
  const der = createPublicKey(rawX25519Private(privateBytes)).export({ format: "der", type: "spki" });
  assert.equal(der.subarray(0, X25519_SPKI_PREFIX.length).compare(X25519_SPKI_PREFIX), 0);
  return der.subarray(X25519_SPKI_PREFIX.length);
}

function canonicalFields(fields) {
  return Buffer.concat(fields.flatMap((field) => {
    const value = Buffer.from(field, "utf8");
    const length = Buffer.alloc(4);
    length.writeUInt32BE(value.length);
    return [length, value];
  }));
}

// A structurally complete, metadata-free 1x1 baseline JPEG fixture.
function canonicalJPEG() {
  return Buffer.from([
    0xff, 0xd8,
    0xff, 0xdb, 0x00, 0x43, 0x00,
    ...Array(64).fill(0x01),
    0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x01, 0x00, 0x01, 0x03,
    0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
    0xff, 0xc4, 0x00, 0x14, 0x00,
    ...Array(16).fill(0x00), 0x00,
    0xff, 0xda, 0x00, 0x0c, 0x03,
    0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x00, 0x3f, 0x00,
    0x00,
    0xff, 0xd9,
  ]);
}

function createBundle({
  jpeg = canonicalJPEG(),
  moderationKeyId = "moderation-v1",
  metadataOverrides = {},
  envelopeOverrides = {},
  plaintextOverrides = {},
} = {}) {
  const base = {
    momentId: "moment_fixture",
    reporterParticipantId: "member_reporter",
    reasonCode: "privacy",
    moderationKeyId,
  };
  const aad = canonicalFields([
    MODERATION_ENVELOPE_DOMAIN,
    "2",
    base.momentId,
    base.reporterParticipantId,
    base.reasonCode,
    base.moderationKeyId,
  ]);
  const plaintext = binaryPlist({
    protocolVersion: 2,
    momentID: base.momentId,
    reporterParticipantID: base.reporterParticipantId,
    reason: base.reasonCode,
    capturedAt: new Date("2026-08-20T12:34:56.000Z"),
    reportedAt: new Date("2026-08-22T03:45:00.000Z"),
    canonicalJPEG: jpeg,
    ...plaintextOverrides,
  });
  const recipientPublic = createPublicKey(rawX25519Private(FIXTURE_RECIPIENT_PRIVATE_KEY));
  const ephemeralPrivate = rawX25519Private(FIXTURE_EPHEMERAL_PRIVATE_KEY);
  const shared = diffieHellman({ privateKey: ephemeralPrivate, publicKey: recipientPublic });
  const key = Buffer.from(hkdfSync(
    "sha256",
    shared,
    createHash("sha256").update(aad).digest(),
    Buffer.from("jp.nekowidget.moment.report.v1", "utf8"),
    32,
  ));
  const nonce = Buffer.from("000102030405060708090a0b", "hex");
  const cipher = createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
  cipher.setAAD(aad, { plaintextLength: plaintext.length });
  const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const combined = Buffer.concat([nonce, encrypted, cipher.getAuthTag()]);
  const envelope = binaryPlist({
    protocolVersion: 2,
    moderationKeyID: base.moderationKeyId,
    ephemeralPublicKey: rawX25519Public(FIXTURE_EPHEMERAL_PRIVATE_KEY),
    ciphertext: combined,
    ...envelopeOverrides,
  });
  const exportCommittedAt = Math.floor(Date.now() / 1_000) - 60;
  const metadata = {
    schema: MODERATION_EXPORT_SCHEMA,
    protocolVersion: 2,
    envelopeDomain: MODERATION_ENVELOPE_DOMAIN,
    algorithm: MODERATION_ALGORITHM,
    reportId: "report_fixture",
    momentId: base.momentId,
    reporterParticipantId: base.reporterParticipantId,
    reasonCode: base.reasonCode,
    moderationKeyId: base.moderationKeyId,
    ciphertextSize: envelope.length,
    ciphertextSHA256: createHash("sha256").update(envelope).digest("base64url"),
    committedAt: exportCommittedAt,
    contentExpiresAt: exportCommittedAt + (7 * 86_400),
    ...metadataOverrides,
  };
  plaintext.fill(0);
  shared.fill(0);
  key.fill(0);
  return { envelope, jpeg, metadata };
}

function workspace(bundle = createBundle(), key = FIXTURE_RECIPIENT_PRIVATE_KEY) {
  const directory = mkdtempSync(join(tmpdir(), "neko-moderation-tool-"));
  const paths = {
    directory,
    metadata: join(directory, "metadata.json"),
    ciphertext: join(directory, "report.ciphertext"),
    key: join(directory, `${bundle.metadata.moderationKeyId}.private.raw`),
    publicKey: join(directory, `${bundle.metadata.moderationKeyId}.public.base64url`),
    output: join(directory, "review.jpg"),
    receipt: join(directory, "review.jpg.receipt"),
    audit: join(directory, "audit.jsonl"),
    moderationKeyId: bundle.metadata.moderationKeyId,
  };
  writeFileSync(paths.metadata, `${JSON.stringify(bundle.metadata)}\n`, { mode: 0o600 });
  writeFileSync(paths.ciphertext, bundle.envelope, { mode: 0o600 });
  writeFileSync(paths.key, key, { mode: 0o600 });
  const publicRaw = rawX25519Public(key);
  paths.expectedPublicKeySHA256 = createHash("sha256").update(publicRaw).digest("hex");
  writeFileSync(paths.publicKey, publicRaw.toString("base64url"), { mode: 0o600 });
  chmodSync(paths.key, 0o600);
  chmodSync(paths.publicKey, 0o600);
  return { bundle, paths };
}

function runDecrypt(paths, extra = []) {
  return spawnSync(process.execPath, [
    TOOL,
    "decrypt",
    "--metadata", paths.metadata,
    "--ciphertext", paths.ciphertext,
    "--moderation-key-id", paths.moderationKeyId,
    "--private-key", paths.key,
    "--expected-public-key-sha256", paths.expectedPublicKeySHA256,
    "--output", paths.output,
    "--audit-log", paths.audit,
    ...extra,
  ], { encoding: "utf8" });
}

function runDelete(paths, {
  file = paths.output,
  kind = "plaintext",
  receipt = kind === "plaintext" ? paths.receipt : undefined,
  audit = paths.audit,
} = {}) {
  const args = [
    TOOL,
    "delete",
    "--metadata", paths.metadata,
    "--file", file,
    "--kind", kind,
    "--moderation-key-id", paths.moderationKeyId,
    "--private-key", paths.key,
    "--expected-public-key-sha256", paths.expectedPublicKeySHA256,
    "--audit-log", audit,
    "--confirm-delete",
  ];
  if (receipt !== undefined) args.splice(8, 0, "--receipt", receipt);
  return spawnSync(process.execPath, args, { encoding: "utf8" });
}

function cleanup(directory) {
  rmSync(directory, { recursive: true, force: true });
}

test("zeros a bounded-read buffer on a post-read size failure but transfers it on success", () => {
  const directory = mkdtempSync(join(tmpdir(), "neko-moderation-read-zero-"));
  const path = join(directory, "moderation-v1.private.raw");
  writeFileSync(path, Buffer.alloc(32, 0x11), { mode: 0o600 });
  chmodSync(path, 0o600);

  const failedRead = Buffer.alloc(31, 0xa5);
  const successfulRead = Buffer.alloc(32, 0x5a);
  try {
    assert.throws(
      () => readBoundedRegularFile(path, 32, "private key file", {
        requireOwnerOnly: true,
        readFileFromDescriptor: () => failedRead,
      }),
      /changed while reading/u,
    );
    assert.deepEqual(failedRead, Buffer.alloc(failedRead.length));

    const returned = readBoundedRegularFile(path, 32, "private key file", {
      requireOwnerOnly: true,
      readFileFromDescriptor: () => successfulRead,
    });
    assert.strictEqual(returned, successfulRead);
    assert.deepEqual(returned, Buffer.alloc(returned.length, 0x5a));
  } finally {
    failedRead.fill(0);
    successfulRead.fill(0);
    cleanup(directory);
  }
});

portableCliTest("decrypts a synthetic Swift-compatible envelope without logging secrets", () => {
  const item = workspace();
  try {
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(readFileSync(item.paths.output), item.bundle.jpeg);
    assert.equal(existsSync(item.paths.receipt), true);
    if (process.platform !== "win32") assert.equal(statSync(item.paths.output).mode & 0o077, 0);
    const combinedLogs = `${result.stdout}\n${result.stderr}\n${readFileSync(item.paths.audit, "utf8")}`;
    assert.doesNotMatch(combinedLogs, /moment_fixture|member_reporter|70076d0a7318a57d/u);
    const audit = readFileSync(item.paths.audit, "utf8").trim().split("\n").map(JSON.parse);
    assert.equal(audit.length, 1);
    assert.equal(audit[0].event, "decrypt_succeeded");

    const deleted = runDelete(item.paths);
    assert.equal(deleted.status, 0, deleted.stderr);
    assert.equal(existsSync(item.paths.output), false);
    assert.equal(existsSync(item.paths.receipt), false);
    assert.deepEqual(
      readFileSync(item.paths.audit, "utf8").trim().split("\n").map(JSON.parse).map(
        (event) => event.event,
      ),
      [
        "decrypt_succeeded",
        "local_plaintext_deletion_started",
        "local_plaintext_deleted",
      ],
    );
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("reviews and deletes an existing moderation-v2 artifact with an explicit key identity", () => {
  const item = workspace(createBundle({ moderationKeyId: "moderation-v2" }));
  try {
    const decrypted = runDecrypt(item.paths);
    assert.equal(decrypted.status, 0, decrypted.stderr);
    assert.deepEqual(readFileSync(item.paths.output), item.bundle.jpeg);
    const deleted = runDelete(item.paths);
    assert.equal(deleted.status, 0, deleted.stderr);
    assert.equal(existsSync(item.paths.output), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("checks the reviewed key ID before any private-key path access", () => {
  const item = workspace();
  try {
    const missingPrivate = join(item.paths.directory, "moderation-v2.private.raw");
    const result = spawnSync(process.execPath, [
      TOOL,
      "decrypt",
      "--metadata", item.paths.metadata,
      "--ciphertext", item.paths.ciphertext,
      "--moderation-key-id", "moderation-v2",
      "--private-key", missingPrivate,
      "--expected-public-key-sha256", "0".repeat(64),
      "--output", item.paths.output,
      "--audit-log", item.paths.audit,
    ], { encoding: "utf8" });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /reviewed moderation key ID does not match metadata/u);
    assert.doesNotMatch(result.stderr, /private key file/u);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("rejects unknown, whitespace, and non-canonical reviewed key inputs", async (suite) => {
  for (const [name, option, value, pattern] of [
    ["unknown ID", "--moderation-key-id", "moderation-v3", /key ID is unsupported/u],
    ["whitespace ID", "--moderation-key-id", " moderation-v1", /key ID is unsupported/u],
    ["uppercase fingerprint", "--expected-public-key-sha256", "A".repeat(64), /not canonical lowercase hex/u],
  ]) {
    await suite.test(name, () => {
      const item = workspace();
      try {
        const args = [
          TOOL,
          "decrypt",
          "--metadata", item.paths.metadata,
          "--ciphertext", item.paths.ciphertext,
          "--moderation-key-id", item.paths.moderationKeyId,
          "--private-key", item.paths.key,
          "--expected-public-key-sha256", item.paths.expectedPublicKeySHA256,
          "--output", item.paths.output,
          "--audit-log", item.paths.audit,
        ];
        const index = args.indexOf(option);
        args[index + 1] = value;
        const result = spawnSync(process.execPath, args, { encoding: "utf8" });
        assert.equal(result.status, 1);
        assert.match(result.stderr, pattern);
        assert.equal(existsSync(item.paths.output), false);
      } finally {
        cleanup(item.paths.directory);
      }
    });
  }
});

portableCliTest("requires private, companion-public, and reviewed fingerprint identities to agree", async (suite) => {
  await suite.test("reviewed fingerprint mismatch", () => {
    const item = workspace();
    try {
      item.paths.expectedPublicKeySHA256 = "0".repeat(64);
      const result = runDecrypt(item.paths);
      assert.equal(result.status, 1);
      assert.match(result.stderr, /fingerprint does not match/u);
      assert.equal(existsSync(item.paths.output), false);
    } finally { cleanup(item.paths.directory); }
  });
  await suite.test("companion public key mismatch", () => {
    const item = workspace();
    try {
      writeFileSync(
        item.paths.publicKey,
        rawX25519Public(FIXTURE_WRONG_PRIVATE_KEY).toString("base64url"),
        { mode: 0o600 },
      );
      const result = runDecrypt(item.paths);
      assert.equal(result.status, 1);
      assert.match(result.stderr, /does not match its companion public key/u);
      assert.equal(existsSync(item.paths.output), false);
    } finally { cleanup(item.paths.directory); }
  });
  await suite.test("replacing both local key files cannot replace the reviewed identity", () => {
    const item = workspace();
    try {
      writeFileSync(item.paths.key, FIXTURE_WRONG_PRIVATE_KEY, { mode: 0o600 });
      writeFileSync(
        item.paths.publicKey,
        rawX25519Public(FIXTURE_WRONG_PRIVATE_KEY).toString("base64url"),
        { mode: 0o600 },
      );
      const result = runDecrypt(item.paths);
      assert.equal(result.status, 1);
      assert.match(result.stderr, /fingerprint does not match/u);
      assert.equal(existsSync(item.paths.output), false);
    } finally { cleanup(item.paths.directory); }
  });
  await suite.test("delete fails closed on a reviewed fingerprint mismatch", () => {
    const item = workspace();
    try {
      assert.equal(runDecrypt(item.paths).status, 0);
      item.paths.expectedPublicKeySHA256 = "0".repeat(64);
      const result = runDelete(item.paths);
      assert.equal(result.status, 1);
      assert.match(result.stderr, /fingerprint does not match/u);
      assert.equal(existsSync(item.paths.output), true);
      assert.equal(existsSync(item.paths.receipt), true);
    } finally { cleanup(item.paths.directory); }
  });
});

portableCliTest("optionally deletes the downloaded ciphertext only after validated output", () => {
  const item = workspace();
  try {
    const result = runDecrypt(item.paths, ["--delete-ciphertext-after-success"]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(existsSync(item.paths.output), true);
    assert.equal(existsSync(item.paths.receipt), true);
    assert.equal(existsSync(item.paths.ciphertext), false);
    assert.deepEqual(
      readFileSync(item.paths.audit, "utf8").trim().split("\n").map(JSON.parse).map(
        (event) => event.event,
      ),
      [
        "decrypt_succeeded",
        "local_ciphertext_deletion_started",
        "local_ciphertext_deleted",
      ],
    );
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("refuses to delete a private key even when a genuine review receipt is supplied", () => {
  const item = workspace();
  try {
    assert.equal(runDecrypt(item.paths).status, 0);
    const result = runDelete(item.paths, { file: item.paths.key });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /JPEG|review receipt|paths must be distinct/u);
    assert.equal(existsSync(item.paths.key), true);
    assert.equal(existsSync(item.paths.output), true);
    assert.equal(existsSync(item.paths.receipt), true);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("refuses to delete an arbitrary bounded file as ciphertext", () => {
  const item = workspace();
  try {
    const result = runDelete(item.paths, {
      file: item.paths.key,
      kind: "ciphertext",
      receipt: undefined,
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /ciphertext (file size|SHA-256) does not match|paths must be distinct/u);
    assert.equal(existsSync(item.paths.key), true);
    assert.equal(existsSync(item.paths.ciphertext), true);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("refuses plaintext deletion when its review receipt is altered", () => {
  const item = workspace();
  try {
    assert.equal(runDecrypt(item.paths).status, 0);
    const receipt = readFileSync(item.paths.receipt);
    receipt[receipt.length - 1] ^= 0x01;
    writeFileSync(item.paths.receipt, receipt, { mode: 0o600 });
    receipt.fill(0);
    const result = runDelete(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /review receipt does not match/u);
    assert.equal(existsSync(item.paths.output), true);
    assert.equal(existsSync(item.paths.receipt), true);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("does not delete an artifact when the deletion-start audit cannot be written", () => {
  const item = workspace();
  try {
    assert.equal(runDecrypt(item.paths).status, 0);
    const result = runDelete(item.paths, { audit: item.paths.directory });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /audit log must be a regular file/u);
    assert.equal(existsSync(item.paths.output), true);
    assert.equal(existsSync(item.paths.receipt), true);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("does not delete an artifact after a partial audit-log record", () => {
  const item = workspace();
  try {
    assert.equal(runDecrypt(item.paths).status, 0);
    const validPrefix = readFileSync(item.paths.audit);
    writeFileSync(
      item.paths.audit,
      Buffer.concat([validPrefix, Buffer.from('{"event":', "utf8")]),
      { mode: 0o600 },
    );
    validPrefix.fill(0);
    const result = runDelete(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /audit log is not a bounded complete JSONL file/u);
    assert.equal(existsSync(item.paths.output), true);
    assert.equal(existsSync(item.paths.receipt), true);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("does not create plaintext when receipt file creation fails", () => {
  const item = workspace();
  try {
    // 250 bytes fits a normal filename component, while the appended
    // `.receipt` suffix exceeds the common 255-byte component limit.
    item.paths.output = join(item.paths.directory, "r".repeat(250));
    item.paths.receipt = `${item.paths.output}.receipt`;
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(
      result.stderr,
      /restricted review output setup failed and cleanup could not be completed/u,
    );
    assert.equal(existsSync(item.paths.output), false);
    assert.equal(existsSync(item.paths.receipt), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("refuses automatic resume from an ambiguous receipt-only state", () => {
  const item = workspace();
  try {
    assert.equal(runDecrypt(item.paths).status, 0);
    rmSync(item.paths.output);
    assert.equal(existsSync(item.paths.receipt), true);
    const resumed = runDecrypt(item.paths);
    assert.equal(resumed.status, 1);
    assert.match(resumed.stderr, /automatic resume is refused/u);
    assert.equal(existsSync(item.paths.output), false);
    assert.equal(existsSync(item.paths.receipt), true);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("refuses future output and audit paths that alias through a directory link", (context) => {
  const item = workspace();
  try {
    const realDirectory = join(item.paths.directory, "real");
    const aliasDirectory = join(item.paths.directory, "alias");
    mkdirSync(realDirectory);
    try {
      symlinkSync(
        realDirectory,
        aliasDirectory,
        process.platform === "win32" ? "junction" : "dir",
      );
    } catch {
      context.skip("directory links are unavailable on this filesystem");
      return;
    }
    item.paths.output = join(realDirectory, "review.jpg");
    item.paths.receipt = `${item.paths.output}.receipt`;
    item.paths.audit = join(aliasDirectory, "review.jpg");
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /paths must be distinct/u);
    assert.equal(existsSync(item.paths.output), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("refuses hidden Windows alternate-stream and reserved-device paths", (context) => {
  if (process.platform !== "win32") {
    context.skip("Windows path namespaces are not present on this platform");
    return;
  }
  const item = workspace();
  try {
    const alternateStream = runDecrypt({
      ...item.paths,
      audit: `${item.paths.audit}:hidden`,
    });
    assert.equal(alternateStream.status, 1);
    assert.match(alternateStream.stderr, /alternate data stream/u);
    assert.equal(existsSync(item.paths.output), false);

    const reservedDevice = runDecrypt({
      ...item.paths,
      audit: join(item.paths.directory, "NUL.txt"),
    });
    assert.equal(reservedDevice.status, 1);
    assert.match(reservedDevice.stderr, /reserved device names/u);
    assert.equal(existsSync(item.paths.output), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("refuses deletion while the target has another hard link", (context) => {
  const item = workspace();
  try {
    assert.equal(runDecrypt(item.paths).status, 0);
    const alias = join(item.paths.directory, "review-copy.jpg");
    try {
      linkSync(item.paths.output, alias);
    } catch {
      context.skip("hard links are unavailable on this filesystem");
      return;
    }
    const result = runDelete(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /deletion target is not a bounded regular file/u);
    assert.equal(existsSync(item.paths.output), true);
    assert.equal(existsSync(alias), true);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("refuses deletion when the audit log has another hard link", (context) => {
  const item = workspace();
  try {
    assert.equal(runDecrypt(item.paths).status, 0);
    const alias = join(item.paths.directory, "audit-copy.jsonl");
    try {
      linkSync(item.paths.audit, alias);
    } catch {
      context.skip("hard links are unavailable on this filesystem");
      return;
    }
    const result = runDelete(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /audit log must be a regular file/u);
    assert.equal(existsSync(item.paths.output), true);
    assert.equal(existsSync(item.paths.receipt), true);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("refuses a private key input that has an undisclosed hard link", (context) => {
  const item = workspace();
  try {
    const alias = join(item.paths.directory, "key-copy.bin");
    try {
      linkSync(item.paths.key, alias);
    } catch {
      context.skip("hard links are unavailable on this filesystem");
      return;
    }
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /private key file is not a bounded regular file/u);
    assert.equal(existsSync(item.paths.output), false);
    assert.equal(existsSync(item.paths.key), true);
    assert.equal(existsSync(alias), true);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("rejects a ciphertext whose stored SHA-256 descriptor is wrong", () => {
  const item = workspace();
  try {
    item.bundle.envelope[20] ^= 0x01;
    writeFileSync(item.paths.ciphertext, item.bundle.envelope);
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /SHA-256 does not match/u);
    assert.equal(existsSync(item.paths.output), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("rejects an expired or non-seven-day report export window", async (suite) => {
  const now = Math.floor(Date.now() / 1_000);
  await suite.test("expired", () => {
    const committedAt = now - (8 * 86_400);
    const item = workspace(createBundle({
      metadataOverrides: {
        committedAt,
        contentExpiresAt: committedAt + (7 * 86_400),
      },
    }));
    try {
      const result = runDecrypt(item.paths);
      assert.equal(result.status, 1);
      assert.match(result.stderr, /content window has closed/u);
      assert.equal(existsSync(item.paths.output), false);
    } finally { cleanup(item.paths.directory); }
  });
  await suite.test("wrong TTL", () => {
    const committedAt = now - 60;
    const item = workspace(createBundle({
      metadataOverrides: {
        committedAt,
        contentExpiresAt: committedAt + (6 * 86_400),
      },
    }));
    try {
      const result = runDecrypt(item.paths);
      assert.equal(result.status, 1);
      assert.match(result.stderr, /retention timestamps are invalid/u);
      assert.equal(existsSync(item.paths.output), false);
    } finally { cleanup(item.paths.directory); }
  });
});

portableCliTest("still deletes a locally reviewed artifact after its server content window closes", () => {
  const item = workspace();
  try {
    assert.equal(runDecrypt(item.paths).status, 0);
    const expired = { ...item.bundle.metadata };
    expired.committedAt = Math.floor(Date.now() / 1_000) - (8 * 86_400);
    expired.contentExpiresAt = expired.committedAt + (7 * 86_400);
    writeFileSync(item.paths.metadata, `${JSON.stringify(expired)}\n`, { mode: 0o600 });
    const result = runDelete(item.paths);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(existsSync(item.paths.output), false);
    assert.equal(existsSync(item.paths.receipt), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("rejects authenticated-envelope tampering even if metadata hash is replaced", () => {
  const bundle = createBundle();
  const nonceOffset = bundle.envelope.indexOf(Buffer.from("000102030405060708090a0b", "hex"));
  assert.ok(nonceOffset >= 0);
  bundle.envelope[nonceOffset + 20] ^= 0x01;
  bundle.metadata.ciphertextSHA256 = createHash("sha256")
    .update(bundle.envelope)
    .digest("base64url");
  const item = workspace(bundle);
  try {
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /authentication failed/u);
    assert.equal(existsSync(item.paths.output), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("rejects the wrong moderation private key", () => {
  const item = workspace(createBundle(), FIXTURE_WRONG_PRIVATE_KEY);
  try {
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /authentication failed/u);
    assert.equal(existsSync(item.paths.output), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("rejects an AAD identity mismatch even when the stored hash is valid", () => {
  const bundle = createBundle();
  bundle.metadata.reasonCode = "harassment";
  const item = workspace(bundle);
  try {
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /authentication failed/u);
    assert.equal(existsSync(item.paths.output), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("rejects envelope and plaintext protocol or key identifier changes", async (suite) => {
  await suite.test("envelope protocol", () => {
    const item = workspace(createBundle({ envelopeOverrides: { protocolVersion: 3 } }));
    try {
      const result = runDecrypt(item.paths);
      assert.equal(result.status, 1);
      assert.match(result.stderr, /envelope protocol/u);
    } finally { cleanup(item.paths.directory); }
  });
  await suite.test("envelope key ID", () => {
    const item = workspace(createBundle({ envelopeOverrides: { moderationKeyID: "moderation-v2" } }));
    try {
      const result = runDecrypt(item.paths);
      assert.equal(result.status, 1);
      assert.match(result.stderr, /key ID does not match/u);
    } finally { cleanup(item.paths.directory); }
  });
  await suite.test("plaintext protocol", () => {
    const item = workspace(createBundle({ plaintextOverrides: { protocolVersion: 3 } }));
    try {
      const result = runDecrypt(item.paths);
      assert.equal(result.status, 1);
      assert.match(result.stderr, /identity does not match/u);
    } finally { cleanup(item.paths.directory); }
  });
});

portableCliTest("rejects APP metadata in a decrypted JPEG", () => {
  const clean = canonicalJPEG();
  const privateAPP1 = Buffer.from([0xff, 0xe1, 0x00, 0x04, 0x01, 0x02]);
  const jpeg = Buffer.concat([clean.subarray(0, 2), privateAPP1, clean.subarray(2)]);
  const item = workspace(createBundle({ jpeg }));
  try {
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /APP or comment metadata/u);
    assert.equal(existsSync(item.paths.output), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("rejects an oversized downloaded object before parsing", () => {
  const item = workspace();
  try {
    writeFileSync(item.paths.ciphertext, Buffer.alloc(MAXIMUM_REPORT_CIPHERTEXT_BYTES + 1, 0x41));
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /not a bounded regular file/u);
    assert.equal(existsSync(item.paths.output), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("rejects duplicate manifest keys instead of accepting JSON last-write-wins", () => {
  const item = workspace();
  try {
    const metadata = readFileSync(item.paths.metadata, "utf8").trim();
    writeFileSync(item.paths.metadata, metadata.replace(
      '"protocolVersion":2',
      '"protocolVersion":2,"protocolVersion":2',
    ));
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /duplicate key/u);
  } finally {
    cleanup(item.paths.directory);
  }
});

portableCliTest("refuses an audit path that aliases a sensitive input", (context) => {
  const item = workspace();
  try {
    try {
      linkSync(item.paths.metadata, item.paths.audit);
    } catch {
      context.skip("hard links are unavailable on this filesystem");
      return;
    }
    const result = runDecrypt(item.paths);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /must not be hard links|metadata file is not a bounded regular file/u);
    assert.equal(existsSync(item.paths.output), false);
  } finally {
    cleanup(item.paths.directory);
  }
});

test("synthetic fixture constants stay aligned with Swift and Worker contracts", () => {
  const toolSource = readFileSync(TOOL, "utf8");
  const swift = readFileSync(
    new URL("../../Shared/Sharing/MomentSharingCore.swift", import.meta.url),
    "utf8",
  );
  const worker = readFileSync(new URL("../src/moments.ts", import.meta.url), "utf8");
  assert.match(swift, /static let version = 2/u);
  assert.match(swift, /static let maximumObjectCiphertextBytes = 1_024 \* 1_024/u);
  assert.match(swift, /"NW2\.MODERATION-REPORT",\s*String\(MomentSharingProtocol\.version\),\s*momentID,\s*reporterParticipantID,\s*reason\.rawValue,\s*moderationKeyID/su);
  assert.match(swift, /salt: Data\(SHA256\.hash\(data: aad\)\)/u);
  assert.match(swift, /sharedInfo: Data\("jp\.nekowidget\.moment\.report\.v1"\.utf8\)/u);
  assert.match(swift, /let sealed = try ChaChaPoly\.seal\(plaintext, using: key, authenticating: aad\)\.combined/u);
  assert.match(swift, /var count = UInt32\(bytes\.count\)\.bigEndian/u);
  assert.match(worker, /export const MOMENT_PROTOCOL_VERSION = 2 as const/u);
  assert.match(worker, /export const MAXIMUM_MOMENT_CIPHERTEXT_BYTES = 1024 \* 1024/u);
  assert.match(worker, /const minimumAEADCiphertextBytes = 29/u);
  assert.match(worker, /const allowedModerationKeyIDs = new Set\(\["moderation-v1", "moderation-v2"\]\)/u);
  assert.match(worker, /row\.ciphertext_size !== body\.length \|\| row\.ciphertext_sha256 !== digestValue/u);
  assert.match(
    toolSource,
    /lstatSync\(path, \{ bigint: true \}\)/u,
    "Windows file IDs must not be rounded through Number during hard-link checks",
  );
  assert.match(
    toolSource,
    /requireSafeLocalPath\(path\)/u,
    "every CLI path must pass the local-filesystem namespace gate",
  );
  const librarySource = readFileSync(
    new URL("../scripts/moderation-report-lib.mjs", import.meta.url),
    "utf8",
  );
  assert.match(
    librarySource,
    /unlinkSync\(path\);\s*fsyncParentDirectory\(path\);/su,
    "POSIX artifact deletion must sync its parent before completion audit",
  );
  const ownerOnlyWriter = librarySource.match(
    /export function writeOwnerOnlyFile\([\s\S]*?\r?\n\}\r?\n\r?\nexport function reportReferenceSHA256/u,
  )?.[0] ?? "";
  assert.ok(
    (ownerOnlyWriter.match(/unlinkSync\(path\);\s*fsyncParentDirectory\(path\);/gu) ?? [])
      .length >= 2,
    "failed restricted-file creation must durably remove its directory entry",
  );
  assert.match(
    librarySource,
    /if \(existing === null\) fsyncParentDirectory\(path\);/u,
    "new audit log directory entries must be synchronized",
  );
  assert.ok(
    toolSource.indexOf("writeOwnerOnlyFile(receiptPath, receipt)")
      < toolSource.indexOf("writeOwnerOnlyFile(outputPath, result.canonicalJPEG)"),
    "the durable deletion receipt must be written before plaintext",
  );
  const cleanupHelper = toolSource.match(
    /function cleanupRestrictedReviewFiles\([\s\S]*?\r?\n\}\r?\n\r?\nfunction decryptCommand/u,
  )?.[0] ?? "";
  assert.match(
    cleanupHelper,
    /if \(outputSafeToForget && outputAbsent[\s\S]*?isDefinitelyAbsent\(outputPath\)\) \{[\s\S]*?deleteBoundedRegularFile\(\s*receiptPath/su,
    "the recovery receipt must only be deleted after the plaintext is definitely absent",
  );
  assert.match(
    cleanupHelper,
    /deleteBoundedRegularFile\(\s*outputPath,[\s\S]*?\);\s*outputSafeToForget = true;\s*\} catch/su,
    "an absent path after a failed directory sync must not authorize receipt deletion",
  );
  assert.match(
    cleanupHelper,
    /deleteBoundedRegularFile\(\s*receiptPath,[\s\S]*?\);\s*receiptSafeToForget = true;\s*\} catch/su,
    "receipt cleanup is complete only after its hash-bound delete returns successfully",
  );
  assert.equal(
    (toolSource.match(/cleanupRestrictedReviewFiles\(\{/gu) ?? []).length,
    4,
    "the helper definition and all three cleanup paths must stay receipt-preserving",
  );
});
