import assert from "node:assert/strict";
import {
  createPrivateKey,
  createPublicKey,
} from "node:crypto";
import {
  existsSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";
import {
  MODERATION_STAGING_DRILL_AUDIT_FILENAME,
  MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME,
  MODERATION_STAGING_DRILL_METADATA_FILENAME,
  ModerationStagingDrillError,
  SYNTHETIC_CANONICAL_JPEG,
  createDrillFilesInValidatedDirectory,
  createSyntheticModerationBundle,
  parseCanonicalModerationPublicKey,
  verifyCompletedSyntheticDrillAudit,
  verifySyntheticDrillBundleDirectory,
  verifySyntheticDrillReviewDirectory,
} from "../scripts/moderation-staging-drill-lib.mjs";
import {
  decryptModerationReport,
  parseModerationMetadata,
  reportReferenceSHA256,
} from "../scripts/moderation-report-lib.mjs";
import {
  MODERATION_PUBLIC_FILENAME,
  X25519_PKCS8_PREFIX,
  X25519_SPKI_PREFIX,
  validateExistingRestrictedFile,
} from "../scripts/moderation-staging-keygen-lib.mjs";
import {
  parseArguments,
  runCLI,
} from "../scripts/generate-moderation-staging-drill.mjs";

// Synthetic test-only key material. It must never be used for staging or production.
const FIXTURE_RECIPIENT_PRIVATE_KEY = Buffer.from(
  "70076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c6a",
  "hex",
);
const FIXTURE_WRONG_PRIVATE_KEY = Buffer.from(
  "18076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c55",
  "hex",
);

function fixturePublicRaw(privateRaw = FIXTURE_RECIPIENT_PRIVATE_KEY) {
  const privateDER = Buffer.concat([X25519_PKCS8_PREFIX, privateRaw]);
  try {
    const privateKey = createPrivateKey({ key: privateDER, format: "der", type: "pkcs8" });
    const publicDER = createPublicKey(privateKey).export({ format: "der", type: "spki" });
    assert.equal(publicDER.subarray(0, X25519_SPKI_PREFIX.length).equals(X25519_SPKI_PREFIX), true);
    return Buffer.from(publicDER.subarray(X25519_SPKI_PREFIX.length));
  } finally {
    privateDER.fill(0);
  }
}

function cleanup(path) {
  rmSync(path, { recursive: true, force: true });
}

function workspace() {
  const root = mkdtempSync(join(tmpdir(), "neko-moderation-drill-test-"));
  const keyDirectory = join(root, "keys");
  const outputDirectory = join(root, "drill");
  mkdirSync(keyDirectory);
  mkdirSync(outputDirectory);
  const publicPath = join(keyDirectory, MODERATION_PUBLIC_FILENAME);
  const publicRaw = fixturePublicRaw();
  writeFileSync(publicPath, publicRaw.toString("base64url"), { mode: 0o600 });
  publicRaw.fill(0);
  const publicEntry = lstatSync(publicPath, { bigint: true });
  return {
    root,
    keyDirectory,
    outputDirectory,
    publicPath,
    validatedDirectory: Object.freeze({ path: outputDirectory, prepared: true }),
    validatedPublic: Object.freeze({
      path: publicPath,
      directory: keyDirectory,
      device: publicEntry.dev,
      inode: publicEntry.ino,
      bytes: 43,
    }),
  };
}

function completionAudit(metadata) {
  const names = [
    "decrypt_succeeded",
    "local_plaintext_deletion_started",
    "local_plaintext_deleted",
    "local_ciphertext_deletion_started",
    "local_ciphertext_deleted",
  ];
  return Buffer.from(`${names.map((event, index) => JSON.stringify({
    event,
    at: new Date(1_787_000_000_000 + index).toISOString(),
    reportReferenceSHA256: reportReferenceSHA256(metadata.reportId),
    moderationKeyId: metadata.moderationKeyId,
    ciphertextSHA256: metadata.ciphertextSHA256,
  })).join("\n")}\n`, "utf8");
}

test("uses the supplied public key only and decrypts with the matching synthetic private key", () => {
  const publicRaw = fixturePublicRaw();
  const bundle = createSyntheticModerationBundle(publicRaw);
  try {
    const result = decryptModerationReport(
      bundle.metadata,
      bundle.envelopeBytes,
      FIXTURE_RECIPIENT_PRIVATE_KEY,
    );
    try {
      assert.deepEqual(result.canonicalJPEG, SYNTHETIC_CANONICAL_JPEG);
      assert.deepEqual(result.dimensions, { width: 1, height: 1 });
    } finally {
      result.canonicalJPEG.fill(0);
    }
  } finally {
    publicRaw.fill(0);
    bundle.metadataBytes.fill(0);
    bundle.envelopeBytes.fill(0);
  }
});

test("fresh ephemeral X25519 keys and nonces produce distinct envelopes", () => {
  const publicRaw = fixturePublicRaw();
  const nowMilliseconds = Date.now();
  const first = createSyntheticModerationBundle(publicRaw, { nowMilliseconds });
  const second = createSyntheticModerationBundle(publicRaw, { nowMilliseconds });
  try {
    assert.equal(first.envelopeBytes.equals(second.envelopeBytes), false);
    assert.notEqual(first.metadata.ciphertextSHA256, second.metadata.ciphertextSHA256);
    assert.equal(first.metadata.committedAt, second.metadata.committedAt);
    assert.equal(first.metadata.contentExpiresAt - first.metadata.committedAt, 7 * 86_400);
  } finally {
    publicRaw.fill(0);
    first.metadataBytes.fill(0);
    first.envelopeBytes.fill(0);
    second.metadataBytes.fill(0);
    second.envelopeBytes.fill(0);
  }
});

test("wrong private key and authenticated metadata tampering fail closed", () => {
  const publicRaw = fixturePublicRaw();
  const bundle = createSyntheticModerationBundle(publicRaw);
  try {
    assert.throws(
      () => decryptModerationReport(bundle.metadata, bundle.envelopeBytes, FIXTURE_WRONG_PRIVATE_KEY),
      /authentication failed/u,
    );
    assert.throws(
      () => decryptModerationReport(
        { ...bundle.metadata, reasonCode: "harassment" },
        bundle.envelopeBytes,
        FIXTURE_RECIPIENT_PRIVATE_KEY,
      ),
      /authentication failed/u,
    );
  } finally {
    publicRaw.fill(0);
    bundle.metadataBytes.fill(0);
    bundle.envelopeBytes.fill(0);
  }
});

test("canonical public key parser rejects length, newline, padding, and high-bit ASCII aliases", () => {
  const publicRaw = fixturePublicRaw();
  const canonical = Buffer.from(publicRaw.toString("base64url"), "ascii");
  try {
    assert.deepEqual(parseCanonicalModerationPublicKey(canonical), publicRaw);
    assert.throws(() => parseCanonicalModerationPublicKey(Buffer.concat([canonical, Buffer.from("\n")])), /43 ASCII/u);
    assert.throws(() => parseCanonicalModerationPublicKey(Buffer.from(`${canonical.toString("ascii")}=`, "ascii")), /43 ASCII/u);
    const highBit = Buffer.from(canonical);
    highBit[0] |= 0x80;
    assert.throws(() => parseCanonicalModerationPublicKey(highBit), /43 ASCII/u);
    highBit.fill(0);
  } finally {
    publicRaw.fill(0);
    canonical.fill(0);
  }
});

test("rejects a low-order all-zero X25519 recipient public key", () => {
  const lowOrder = Buffer.alloc(32);
  try {
    assert.throws(
      () => createSyntheticModerationBundle(lowOrder),
      /key agreement|invalid secret/u,
    );
  } finally {
    lowOrder.fill(0);
  }
});

test("fixed synthetic JPEG fully decodes in the Windows platform decoder", {
  skip: process.platform !== "win32",
}, () => {
  const powershell = join(
    process.env.SystemRoot,
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe",
  );
  const command = [
    "$ErrorActionPreference='Stop'",
    "Add-Type -AssemblyName System.Drawing",
    "$bytes=[Convert]::FromBase64String([Console]::In.ReadToEnd())",
    "$stream=New-Object IO.MemoryStream(,$bytes)",
    "$image=[System.Drawing.Image]::FromStream($stream,$true,$true)",
    "try { if($image.Width -ne 1 -or $image.Height -ne 1){throw 'invalid'}; $bitmap=New-Object System.Drawing.Bitmap($image); try {$pixel=$bitmap.GetPixel(0,0); if($pixel.R -lt 35 -or $pixel.R -gt 50 -or $pixel.G -lt 90 -or $pixel.G -gt 110 -or $pixel.B -lt 150 -or $pixel.B -gt 170){throw 'pixel'}} finally {$bitmap.Dispose()}; [Console]::Out.Write('DECODE_OK') } finally {$image.Dispose();$stream.Dispose();[Array]::Clear($bytes,0,$bytes.Length)}",
  ].join("; ");
  const result = spawnSync(
    powershell,
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
    {
      input: SYNTHETIC_CANONICAL_JPEG.toString("base64"),
      encoding: "utf8",
      windowsHide: true,
      timeout: 20_000,
      maxBuffer: 8 * 1_024,
    },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "DECODE_OK");
});

test("creates only the fixed O_EXCL outputs and they decrypt compatibly", () => {
  const item = workspace();
  try {
    createDrillFilesInValidatedDirectory(item.validatedDirectory, item.validatedPublic);
    assert.deepEqual(readdirSync(item.outputDirectory).sort(), [
      MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME,
      MODERATION_STAGING_DRILL_METADATA_FILENAME,
    ].sort());
    const metadataBytes = readFileSync(join(item.outputDirectory, MODERATION_STAGING_DRILL_METADATA_FILENAME));
    const envelopeBytes = readFileSync(join(item.outputDirectory, MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME));
    const metadata = parseModerationMetadata(metadataBytes.toString("utf8"));
    const result = decryptModerationReport(metadata, envelopeBytes, FIXTURE_RECIPIENT_PRIVATE_KEY);
    try {
      assert.deepEqual(result.canonicalJPEG, SYNTHETIC_CANONICAL_JPEG);
      assert.equal(lstatSync(join(item.outputDirectory, MODERATION_STAGING_DRILL_METADATA_FILENAME), { bigint: true }).nlink, 1n);
      assert.equal(lstatSync(join(item.outputDirectory, MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME), { bigint: true }).nlink, 1n);
    } finally {
      metadataBytes.fill(0);
      envelopeBytes.fill(0);
      result.canonicalJPEG.fill(0);
    }
  } finally {
    cleanup(item.root);
  }
});

test("refuses an existing output without overwrite", () => {
  const item = workspace();
  const collision = join(item.outputDirectory, MODERATION_STAGING_DRILL_METADATA_FILENAME);
  writeFileSync(collision, "do-not-overwrite", { mode: 0o600 });
  try {
    assert.throws(
      () => createDrillFilesInValidatedDirectory(item.validatedDirectory, item.validatedPublic),
      /empty real directory/u,
    );
    assert.equal(readFileSync(collision, "utf8"), "do-not-overwrite");
  } finally {
    cleanup(item.root);
  }
});

test("rejects key-directory child or ancestor output before creating any drill file", () => {
  const item = workspace();
  const child = join(item.keyDirectory, "drill-child");
  mkdirSync(child);
  const before = readdirSync(item.keyDirectory).sort();
  try {
    assert.throws(
      () => createDrillFilesInValidatedDirectory(
        { path: child, prepared: true },
        item.validatedPublic,
      ),
      /canonically disjoint/u,
    );
    assert.deepEqual(readdirSync(item.keyDirectory).sort(), before);
    assert.deepEqual(readdirSync(child), []);
    assert.throws(
      () => createDrillFilesInValidatedDirectory(
        { path: item.root, prepared: true },
        item.validatedPublic,
      ),
      /canonically disjoint/u,
    );
    assert.deepEqual(readdirSync(item.keyDirectory).sort(), before);
  } finally {
    cleanup(item.root);
  }
});

test("refuses a hard-linked public key before bundle generation", () => {
  const item = workspace();
  const alias = join(item.keyDirectory, "public-hardlink-alias");
  linkSync(item.publicPath, alias);
  let called = false;
  try {
    assert.throws(
      () => createDrillFilesInValidatedDirectory(
        item.validatedDirectory,
        item.validatedPublic,
        { bundleFactory: () => { called = true; } },
      ),
      /identity changed/u,
    );
    assert.equal(called, false);
  } finally {
    cleanup(item.root);
  }
});

test("detects an output hard-link race and never reports success", () => {
  const item = workspace();
  const alias = join(item.root, "ciphertext-hardlink-alias");
  const publicRaw = fixturePublicRaw();
  try {
    assert.throws(
      () => createDrillFilesInValidatedDirectory(
        item.validatedDirectory,
        item.validatedPublic,
        {
          bundleFactory: () => {
            linkSync(
              join(item.outputDirectory, MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME),
              alias,
            );
            return createSyntheticModerationBundle(publicRaw);
          },
        },
      ),
      /identity, size, link, or permission/u,
    );
    assert.equal(existsSync(alias), true);
  } finally {
    publicRaw.fill(0);
    cleanup(item.root);
  }
});

test("existing public-file validator shares restricted-root and single-link policy", () => {
  const item = workspace();
  const policyRoot = join(item.root, "policy-roots");
  const currentDirectory = join(policyRoot, "current");
  const repositoryRoot = join(policyRoot, "repository");
  const temporaryDirectory = join(policyRoot, "temporary");
  const userProfile = join(policyRoot, "profile");
  for (const path of [policyRoot, currentDirectory, repositoryRoot, temporaryDirectory, userProfile]) {
    if (!existsSync(path)) mkdirSync(path);
  }
  try {
    // GitHub's Windows runner exposes RUNNER_TEMP through a path alias. The
    // operational validator intentionally rejects that spelling, so exercise
    // the nominal contract with the handle-resolved canonical path while the
    // separate alias fixtures continue to assert fail-closed behavior.
    const canonicalPublicPath = realpathSync.native(item.publicPath);
    const validated = validateExistingRestrictedFile(canonicalPublicPath, {
      expectedFilename: MODERATION_PUBLIC_FILENAME,
      expectedBytes: 43,
      currentDirectory,
      repositoryRoot,
      temporaryDirectory,
      userProfile,
      environment: {},
    });
    assert.equal(validated.path, canonicalPublicPath);
    assert.throws(
      () => validateExistingRestrictedFile(canonicalPublicPath, {
        expectedFilename: MODERATION_PUBLIC_FILENAME,
        expectedBytes: 43,
        currentDirectory: item.root,
        repositoryRoot,
        temporaryDirectory,
        userProfile,
        environment: {},
      }),
      /restricted|repository|working|temporary|profile/u,
    );
  } finally {
    cleanup(item.root);
  }
});

test("completion verifier requires exact successful audit transitions", () => {
  const publicRaw = fixturePublicRaw();
  const bundle = createSyntheticModerationBundle(publicRaw);
  const audit = completionAudit(bundle.metadata);
  try {
    assert.deepEqual(
      verifyCompletedSyntheticDrillAudit(bundle.metadataBytes, audit),
      { complete: true },
    );
    const lines = audit.toString("utf8").trimEnd().split("\n");
    const swapped = Buffer.from(`${[lines[0], lines[2], lines[1], ...lines.slice(3)].join("\n")}\n`);
    assert.throws(
      () => verifyCompletedSyntheticDrillAudit(bundle.metadataBytes, swapped),
      /non-canonical|mismatched transition/u,
    );
    const failed = Buffer.from(audit.toString("utf8").replace(
      "local_plaintext_deleted",
      "local_deletion_failed",
    ));
    assert.throws(
      () => verifyCompletedSyntheticDrillAudit(bundle.metadataBytes, failed),
      /non-canonical|mismatched transition/u,
    );
    swapped.fill(0);
    failed.fill(0);
  } finally {
    publicRaw.fill(0);
    bundle.metadataBytes.fill(0);
    bundle.envelopeBytes.fill(0);
    audit.fill(0);
  }
});

test("pre-private-key preflight rejects a descriptor with non-fixture identity", () => {
  const item = workspace();
  try {
    createDrillFilesInValidatedDirectory(item.validatedDirectory, item.validatedPublic);
    assert.deepEqual(verifySyntheticDrillBundleDirectory(item.outputDirectory), { verified: true });
    const metadataPath = join(item.outputDirectory, MODERATION_STAGING_DRILL_METADATA_FILENAME);
    const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
    metadata.reportId = "not_the_fixed_synthetic_fixture";
    writeFileSync(metadataPath, `${JSON.stringify(metadata)}\n`, { mode: 0o600 });
    assert.throws(
      () => verifySyntheticDrillBundleDirectory(item.outputDirectory),
      /fixed synthetic fixture/u,
    );
  } finally {
    cleanup(item.root);
  }
});

test("pre-human-view verifier requires byte-exact JPEG, bound receipt, and one decrypt audit", () => {
  const item = workspace();
  const privatePath = join(item.keyDirectory, "synthetic-test-private.raw");
  const metadataPath = join(item.outputDirectory, MODERATION_STAGING_DRILL_METADATA_FILENAME);
  const ciphertextPath = join(item.outputDirectory, MODERATION_STAGING_DRILL_CIPHERTEXT_FILENAME);
  const reviewPath = join(item.outputDirectory, "synthetic-review.jpg");
  const auditPath = join(item.outputDirectory, MODERATION_STAGING_DRILL_AUDIT_FILENAME);
  const tool = fileURLToPath(new URL("../scripts/moderation-report-tool.mjs", import.meta.url));
  try {
    createDrillFilesInValidatedDirectory(item.validatedDirectory, item.validatedPublic);
    writeFileSync(privatePath, FIXTURE_RECIPIENT_PRIVATE_KEY, { mode: 0o600 });
    const result = spawnSync(process.execPath, [
      tool,
      "decrypt",
      "--metadata", metadataPath,
      "--ciphertext", ciphertextPath,
      "--private-key", privatePath,
      "--output", reviewPath,
      "--audit-log", auditPath,
    ], { encoding: "utf8", windowsHide: true, timeout: 20_000, maxBuffer: 8 * 1_024 });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(verifySyntheticDrillReviewDirectory(item.outputDirectory), { verified: true });
    const changed = readFileSync(reviewPath);
    changed[changed.length - 10] ^= 0x01;
    writeFileSync(reviewPath, changed, { mode: 0o600 });
    changed.fill(0);
    assert.throws(
      () => verifySyntheticDrillReviewDirectory(item.outputDirectory),
      /byte-exact fixed synthetic content/u,
    );
  } finally {
    cleanup(item.root);
  }
});

test("CLI has no private-key input and logs no key or operator path", () => {
  assert.throws(
    () => parseArguments(["--private-key", "secret", "--output-dir", "out"]),
    /unsupported option/u,
  );
  let received;
  let output = "";
  const keyPath = "C:\\restricted\\staging-key\\moderation-v1.public.base64url";
  const drillPath = "C:\\restricted\\staging-drill";
  runCLI(
    ["--public-key-file", keyPath, "--output-dir", drillPath, "--confirm-local-encrypted-nosync"],
    {
      generate: (value) => { received = value; },
      stdout: { write: (value) => { output += value; } },
    },
  );
  assert.deepEqual(received, {
    publicKeyFile: keyPath,
    outputDirectory: drillPath,
    confirmLocalEncryptedNoSync: true,
  });
  assert.equal(output.includes(keyPath), false);
  assert.equal(output.includes(drillPath), false);
  assert.equal(output.includes(FIXTURE_RECIPIENT_PRIVATE_KEY.toString("hex")), false);
});

test("drill implementation is offline-only and stays aligned with Swift field contracts", () => {
  const libraryPath = fileURLToPath(new URL("../scripts/moderation-staging-drill-lib.mjs", import.meta.url));
  const generatorPath = fileURLToPath(new URL("../scripts/generate-moderation-staging-drill.mjs", import.meta.url));
  const wrapperPath = fileURLToPath(new URL("../scripts/moderation-staging-drill-windows.ps1", import.meta.url));
  const source = [libraryPath, generatorPath, wrapperPath].map((path) => readFileSync(path, "utf8")).join("\n");
  assert.doesNotMatch(source, /\b(?:fetch|https?|wrangler|xcodebuild|gh)\s*(?:\(|:|\s)/iu);
  assert.doesNotMatch(readFileSync(generatorPath, "utf8"), /--private-key/u);
  assert.match(source, /generateKeyPairSync\("x25519"\)/u);
  assert.match(source, /randomBytes\(12\)/u);
  assert.match(source, /moderationKeyID/u);
  assert.match(source, /momentID/u);
  assert.match(source, /reporterParticipantID/u);

  const swift = readFileSync(
    new URL("../../Shared/Sharing/MomentSharingCore.swift", import.meta.url),
    "utf8",
  );
  assert.match(swift, /static let version = 2/u);
  assert.match(swift, /"NW2\.MODERATION-REPORT",\s*String\(MomentSharingProtocol\.version\),\s*momentID,\s*reporterParticipantID,\s*reason\.rawValue,\s*moderationKeyID/su);
  assert.match(swift, /salt: Data\(SHA256\.hash\(data: aad\)\)/u);
  assert.match(swift, /sharedInfo: Data\("jp\.nekowidget\.moment\.report\.v1"\.utf8\)/u);
  assert.match(swift, /let sealed = try ChaChaPoly\.seal\(plaintext, using: key, authenticating: aad\)\.combined/u);
  assert.match(swift, /var count = UInt32\(bytes\.count\)\.bigEndian/u);
});

test("Windows operator wrappers preserve the human-view boundary and exact deletion proof", () => {
  const generation = readFileSync(
    new URL("../scripts/moderation-staging-drill-windows.ps1", import.meta.url),
    "utf8",
  );
  const review = readFileSync(
    new URL("../scripts/moderation-staging-drill-review-windows.ps1", import.meta.url),
    "utf8",
  );
  const security = readFileSync(
    new URL("../scripts/moderation-staging-keygen-windows-security.ps1", import.meta.url),
    "utf8",
  );
  assert.doesNotMatch(generation, /moderation-v1\.private\.raw|--private-key/u);
  assert.match(generation, /-Mode PrepareDrillDirectory[\s\S]*?-DisjointDirectory \$KeyDirectory/su);
  assert.match(review, /DecryptForHumanReview/u);
  assert.match(review, /DeleteAfterHumanReview/u);
  assert.match(review, /--private-key\s+\$privateKey/u);
  assert.match(review, /--phase bundle --drill-dir \$DrillDirectory[\s\S]*?--private-key/su);
  assert.match(review, /HardenDrillReviewFiles[\s\S]*?--phase review --drill-dir \$DrillDirectory/su);
  assert.doesNotMatch(review, /--delete-ciphertext-after-success/u);
  assert.match(review, /--kind plaintext[\s\S]*?--receipt \$receipt/su);
  assert.match(review, /--kind ciphertext/su);
  assert.match(review, /ValidateDrillAfterDelete/u);
  assert.match(review, /verify-moderation-staging-drill-completion\.mjs/u);
  assert.match(review, /--phase deleted --drill-dir \$DrillDirectory/u);
  for (const mode of [
    "ValidateKeyDirectory",
    "PrepareDrillDirectory",
    "VerifyDrillDirectory",
    "HardenDrillFiles",
    "ValidateDrillForReview",
    "HardenDrillReviewFiles",
    "ValidateDrillForDelete",
    "ValidateDrillAfterDelete",
  ]) {
    assert.match(security, new RegExp(mode, "u"));
  }
  assert.match(security, /Test-Administrator/u);
  assert.match(security, /GetFinalPathNameByHandle/u);
  assert.match(security, /NumberOfLinks/u);
  assert.match(security, /Test-DisjointOperationalDirectories/u);
  assert.doesNotMatch(`${generation}\n${review}`, /\b(?:wrangler|xcodebuild|git|gh|curl|Invoke-WebRequest)\b/iu);
});
