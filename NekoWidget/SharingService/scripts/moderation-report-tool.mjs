#!/usr/bin/env node

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, realpathSync } from "node:fs";
import { basename, dirname, join, resolve, win32 as windowsPath } from "node:path";
import { fileURLToPath } from "node:url";
import {
  MAXIMUM_CANONICAL_JPEG_BYTES,
  MAXIMUM_METADATA_BYTES,
  MAXIMUM_REPORT_CIPHERTEXT_BYTES,
  MODERATION_REVIEW_RECEIPT_BYTES,
  ModerationToolError,
  appendAuditEvent,
  createModerationReviewReceipt,
  decryptModerationReport,
  deleteBoundedRegularFile,
  parseModerationMetadata,
  readBoundedRegularFile,
  reportReferenceSHA256,
  requireSafeLocalPath,
  validateExpectedPublicKeySHA256,
  validateCanonicalJPEG,
  validateModerationKeyId,
  validateModerationCiphertextDescriptor,
  validateModerationReviewReceipt,
  verifyReviewedModerationPrivateKey,
  writeOwnerOnlyFile,
} from "./moderation-report-lib.mjs";

const WINDOWS_POWERSHELL = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
const WINDOWS_SECURITY_HELPER = fileURLToPath(new URL(
  "./moderation-staging-keygen-windows-security.ps1",
  import.meta.url,
));
const WINDOWS_SECURITY_TIMEOUT_MS = 30_000;
const WINDOWS_SECURITY_OUTPUT_LIMIT_BYTES = 4_096;
const WINDOWS_PROOF_PREFIX = "NEKO_MODERATION_KEYGEN_WINDOWS_";

const WINDOWS_PRODUCTION_FILES = Object.freeze({
  metadata: "moderation-export.json",
  ciphertext: "moderation-report.ciphertext",
  output: "moderation-review.jpg",
  receipt: "moderation-review.jpg.receipt",
  audit: "moderation-audit.jsonl",
});
const WINDOWS_SYNTHETIC_FILES = Object.freeze({
  metadata: "synthetic-export.json",
  ciphertext: "synthetic-report.ciphertext",
  output: "synthetic-review.jpg",
  receipt: "synthetic-review.jpg.receipt",
  audit: "synthetic-audit.jsonl",
});

function usage() {
  return [
    "Offline moderation report tool",
    "",
    "Decrypt:",
    "  node scripts/moderation-report-tool.mjs decrypt \\",
    "    --metadata <export.json> --ciphertext <report.ciphertext> \\",
    "    --moderation-key-id <moderation-v1|moderation-v2> \\",
    "    --private-key <explicit-32-byte-raw-key> \\",
    "    --expected-public-key-sha256 <reviewed-lowercase-hex> \\",
    "    --output <review.jpg> \\",
    "    --audit-log <audit.jsonl> [--delete-ciphertext-after-success]",
    "",
    "Delete a local review artifact after the case decision:",
    "  node scripts/moderation-report-tool.mjs delete \\",
    "    --metadata <export.json> --file <review.jpg|report.ciphertext> \\",
    "    --kind <plaintext|ciphertext> [--receipt <review.jpg.receipt>] \\",
    "    --moderation-key-id <moderation-v1|moderation-v2> \\",
    "    --private-key <explicit-32-byte-raw-key> \\",
    "    --expected-public-key-sha256 <reviewed-lowercase-hex> \\",
    "    --audit-log <audit.jsonl> \\",
    "    --confirm-delete",
  ].join("\n");
}

function parseOptions(values, valueOptions, booleanOptions = new Set()) {
  const result = new Map();
  for (let index = 0; index < values.length; index += 1) {
    const option = values[index];
    if (booleanOptions.has(option)) {
      if (result.has(option)) throw new ModerationToolError("an option was supplied more than once");
      result.set(option, true);
      continue;
    }
    if (!valueOptions.has(option)) throw new ModerationToolError("an unsupported option was supplied");
    if (result.has(option)) throw new ModerationToolError("an option was supplied more than once");
    if (index + 1 >= values.length || values[index + 1].startsWith("--")) {
      throw new ModerationToolError("an option value is missing");
    }
    result.set(option, values[index + 1]);
    index += 1;
  }
  return result;
}

function required(options, option) {
  const value = options.get(option);
  if (typeof value !== "string" || value.length === 0) {
    throw new ModerationToolError("a required option is missing");
  }
  return value;
}

function normalizeWindowsFixedPath(value) {
  if (typeof value !== "string" || value.length === 0 || value !== value.trim()) {
    throw new ModerationToolError("Windows moderation paths must be non-empty and contain no surrounding whitespace");
  }
  const normalized = windowsPath.normalize(value);
  if (!windowsPath.isAbsolute(value)
      || !/^[A-Za-z]:\\/u.test(normalized)
      || normalized.slice(3).includes(":")
      || normalized !== value) {
    throw new ModerationToolError("Windows moderation paths must use canonical absolute local-drive spelling");
  }
  return normalized;
}

function requiredWindowsFixedFile(options, option, expectedFilename) {
  const value = normalizeWindowsFixedPath(required(options, option));
  if (windowsPath.basename(value) !== expectedFilename) {
    throw new ModerationToolError("Windows moderation operations require the fixed file layout");
  }
  return value;
}

function sameWindowsPath(left, right) {
  return left.toLowerCase() === right.toLowerCase();
}

function windowsPathWithin(candidate, root) {
  const relative = windowsPath.relative(root, candidate);
  return relative === ""
    || (!relative.startsWith(`..${windowsPath.sep}`)
      && relative !== ".."
      && !windowsPath.isAbsolute(relative));
}

function requireWindowsCaseLayout(casePaths, keyDirectory) {
  const caseDirectory = windowsPath.dirname(casePaths[0]);
  if (!casePaths.every((item) => sameWindowsPath(windowsPath.dirname(item), caseDirectory))) {
    throw new ModerationToolError("Windows moderation case files must share one fixed restricted directory");
  }
  if (windowsPathWithin(caseDirectory, keyDirectory)
      || windowsPathWithin(keyDirectory, caseDirectory)) {
    throw new ModerationToolError("Windows moderation key and case directories must be disjoint");
  }
  return caseDirectory;
}

function windowsProof(mode, outputDirectory, keyDirectory, moderationKeyId) {
  return Object.freeze({
    mode,
    outputDirectory,
    ...(keyDirectory === undefined ? {} : { disjointDirectory: keyDirectory }),
    moderationKeyId,
  });
}

function windowsReviewedKey(options) {
  const moderationKeyId = required(options, "--moderation-key-id");
  validateModerationKeyId(moderationKeyId);
  validateExpectedPublicKeySHA256(required(options, "--expected-public-key-sha256"));
  const privateKeyPath = requiredWindowsFixedFile(
    options,
    "--private-key",
    `${moderationKeyId}.private.raw`,
  );
  return Object.freeze({
    moderationKeyId,
    privateKeyPath,
    keyDirectory: windowsPath.dirname(privateKeyPath),
  });
}

function windowsFileContract(metadataPath) {
  const metadataFilename = windowsPath.basename(metadataPath);
  if (metadataFilename === WINDOWS_PRODUCTION_FILES.metadata) {
    return Object.freeze({ kind: "production", files: WINDOWS_PRODUCTION_FILES });
  }
  if (metadataFilename === WINDOWS_SYNTHETIC_FILES.metadata) {
    return Object.freeze({ kind: "synthetic", files: WINDOWS_SYNTHETIC_FILES });
  }
  throw new ModerationToolError("Windows moderation operations require a fixed production or synthetic file layout");
}

function createWindowsDecryptSecurityPlan(values) {
  const options = parseOptions(
    values,
    new Set([
      "--metadata",
      "--ciphertext",
      "--moderation-key-id",
      "--private-key",
      "--expected-public-key-sha256",
      "--output",
      "--audit-log",
    ]),
    new Set(["--delete-ciphertext-after-success"]),
  );
  const rawMetadataPath = normalizeWindowsFixedPath(required(options, "--metadata"));
  const contract = windowsFileContract(rawMetadataPath);
  const metadataPath = requiredWindowsFixedFile(options, "--metadata", contract.files.metadata);
  const ciphertextPath = requiredWindowsFixedFile(options, "--ciphertext", contract.files.ciphertext);
  const outputPath = requiredWindowsFixedFile(options, "--output", contract.files.output);
  const auditPath = requiredWindowsFixedFile(options, "--audit-log", contract.files.audit);
  const receiptPath = normalizeWindowsFixedPath(`${outputPath}.receipt`);
  if (windowsPath.basename(receiptPath) !== contract.files.receipt) {
    throw new ModerationToolError("Windows moderation operations require the fixed receipt filename");
  }
  const reviewed = windowsReviewedKey(options);
  const caseDirectory = requireWindowsCaseLayout(
    [metadataPath, ciphertextPath, outputPath, receiptPath, auditPath],
    reviewed.keyDirectory,
  );
  const deleteCiphertext = options.get("--delete-ciphertext-after-success") === true;
  const preMode = contract.kind === "production"
    ? "ValidateModerationDecryptInput"
    : "ValidateDrillForReview";
  const postMode = contract.kind === "production"
    ? (deleteCiphertext
      ? "HardenModerationDecryptOutputWithoutCiphertext"
      : "HardenModerationDecryptOutput")
    : (deleteCiphertext
      ? "HardenDrillReviewFilesWithoutCiphertext"
      : "HardenDrillReviewFiles");
  return Object.freeze({
    command: "decrypt",
    layout: contract.kind,
    pre: Object.freeze([
      windowsProof("ValidateKeyDirectory", reviewed.keyDirectory, undefined, reviewed.moderationKeyId),
      windowsProof(preMode, caseDirectory, reviewed.keyDirectory, reviewed.moderationKeyId),
    ]),
    post: Object.freeze([
      windowsProof(postMode, caseDirectory, reviewed.keyDirectory, reviewed.moderationKeyId),
    ]),
  });
}

function createWindowsDeleteSecurityPlan(values) {
  const options = parseOptions(
    values,
    new Set([
      "--metadata",
      "--file",
      "--kind",
      "--receipt",
      "--audit-log",
      "--moderation-key-id",
      "--private-key",
      "--expected-public-key-sha256",
    ]),
    new Set(["--confirm-delete"]),
  );
  if (options.get("--confirm-delete") !== true) {
    throw new ModerationToolError("explicit deletion confirmation is required");
  }
  const rawMetadataPath = normalizeWindowsFixedPath(required(options, "--metadata"));
  const contract = windowsFileContract(rawMetadataPath);
  const metadataPath = requiredWindowsFixedFile(options, "--metadata", contract.files.metadata);
  const auditPath = requiredWindowsFixedFile(options, "--audit-log", contract.files.audit);
  const kind = required(options, "--kind");
  if (kind !== "plaintext" && kind !== "ciphertext") {
    throw new ModerationToolError("deletion kind must be plaintext or ciphertext");
  }
  const expectedTarget = kind === "plaintext" ? contract.files.output : contract.files.ciphertext;
  const filePath = requiredWindowsFixedFile(options, "--file", expectedTarget);
  const receiptPath = options.get("--receipt");
  const casePaths = [metadataPath, filePath, auditPath];
  if (kind === "plaintext") {
    const fixedReceiptPath = requiredWindowsFixedFile(options, "--receipt", contract.files.receipt);
    if (!sameWindowsPath(fixedReceiptPath, `${filePath}.receipt`)) {
      throw new ModerationToolError("Windows moderation plaintext and receipt paths do not match");
    }
    casePaths.push(fixedReceiptPath);
  } else if (receiptPath !== undefined) {
    throw new ModerationToolError("ciphertext deletion must not receive a review receipt");
  }
  const reviewed = windowsReviewedKey(options);
  const caseDirectory = requireWindowsCaseLayout(casePaths, reviewed.keyDirectory);
  const preMode = contract.kind === "production"
    ? (kind === "plaintext"
      ? "ValidateModerationPlaintextDeleteInput"
      : "ValidateModerationCiphertextDeleteInput")
    : (kind === "plaintext"
      ? "ValidateDrillForDelete"
      : "ValidateDrillAfterPlaintextDelete");
  const postMode = contract.kind === "production"
    ? (kind === "plaintext"
      ? "HardenModerationAfterPlaintextDelete"
      : "HardenModerationAfterCiphertextDelete")
    : (kind === "plaintext"
      ? "HardenDrillAfterPlaintextDelete"
      : "HardenDrillAfterDelete");
  return Object.freeze({
    command: "delete",
    layout: contract.kind,
    pre: Object.freeze([
      windowsProof("ValidateKeyDirectory", reviewed.keyDirectory, undefined, reviewed.moderationKeyId),
      windowsProof(preMode, caseDirectory, reviewed.keyDirectory, reviewed.moderationKeyId),
    ]),
    post: Object.freeze([
      windowsProof(postMode, caseDirectory, reviewed.keyDirectory, reviewed.moderationKeyId),
    ]),
  });
}

export function createWindowsModerationSecurityPlan(argv) {
  if (!Array.isArray(argv)) {
    throw new ModerationToolError("Windows moderation arguments are invalid");
  }
  const [command, ...values] = argv;
  if (command === "decrypt") return createWindowsDecryptSecurityPlan(values);
  if (command === "delete") return createWindowsDeleteSecurityPlan(values);
  throw new ModerationToolError(usage());
}

function windowsSecurityEnvironment() {
  return {
    ...Object.fromEntries(
      Object.entries(process.env).filter(([name]) => name.toLowerCase() !== "psmodulepath"),
    ),
    SystemRoot: "C:\\Windows",
  };
}

export function runWindowsModerationSecurityProof(proof, spawn = spawnSync) {
  if (proof === null || typeof proof !== "object"
      || typeof proof.mode !== "string"
      || typeof proof.outputDirectory !== "string"
      || typeof proof.moderationKeyId !== "string") {
    throw new ModerationToolError("Windows moderation security proof request is invalid");
  }
  const args = [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    WINDOWS_SECURITY_HELPER,
    "-Mode",
    proof.mode,
    "-OutputDirectory",
    proof.outputDirectory,
    "-ModerationKeyId",
    proof.moderationKeyId,
    "-ConfirmLocalEncryptedNoSync",
  ];
  if (proof.disjointDirectory !== undefined) {
    args.push("-DisjointDirectory", proof.disjointDirectory);
  }
  const result = spawn(WINDOWS_POWERSHELL, args, {
    encoding: "utf8",
    env: windowsSecurityEnvironment(),
    maxBuffer: WINDOWS_SECURITY_OUTPUT_LIMIT_BYTES,
    timeout: WINDOWS_SECURITY_TIMEOUT_MS,
    windowsHide: true,
  });
  const expectedProof = `${WINDOWS_PROOF_PREFIX}${proof.mode.toUpperCase()}_V1`;
  const stdoutIsExactProof = result?.stdout === `${expectedProof}\r\n`
    || result?.stdout === `${expectedProof}\n`;
  if (result?.error !== undefined
      || result?.signal !== null
      || result?.status !== 0
      || result?.stderr !== ""
      || !stdoutIsExactProof) {
    throw new ModerationToolError("Windows moderation security verification failed");
  }
}

function requireDistinctPaths(paths) {
  const resolved = paths.map((path) => {
    requireSafeLocalPath(path);
    const absolute = resolve(path);
    let canonical;
    try {
      canonical = realpathSync.native(absolute);
    } catch {
      // Outputs may not exist yet. Resolve their existing parent so a symlink
      // or Windows junction cannot spell the same future file two ways.
      try {
        canonical = join(realpathSync.native(dirname(absolute)), basename(absolute));
      } catch {
        canonical = absolute;
      }
    }
    return process.platform === "win32" ? canonical.toLowerCase() : canonical;
  });
  if (new Set(resolved).size !== resolved.length) {
    throw new ModerationToolError("input, output, and audit paths must be distinct");
  }
  const identities = [];
  for (const path of paths) {
    try {
      // Windows file IDs routinely exceed Number.MAX_SAFE_INTEGER. Using the
      // default numeric Stats can round two adjacent, distinct files to the
      // same inode and falsely classify them as hard links.
      const entry = lstatSync(path, { bigint: true });
      identities.push(`${entry.dev}:${entry.ino}`);
    } catch { /* output may not exist yet */ }
  }
  if (new Set(identities).size !== identities.length) {
    throw new ModerationToolError("input, output, and audit files must not be hard links");
  }
}

function auditEvent(event, metadata) {
  return {
    event,
    at: new Date().toISOString(),
    reportReferenceSHA256: reportReferenceSHA256(metadata.reportId),
    moderationKeyId: metadata.moderationKeyId,
    ciphertextSHA256: metadata.ciphertextSHA256,
  };
}

function loadMetadata(path, { enforceCurrentWindow = true } = {}) {
  const bytes = readBoundedRegularFile(
    path,
    MAXIMUM_METADATA_BYTES,
    "metadata file",
    { requireOwnerOnly: true },
  );
  try {
    return parseModerationMetadata(bytes.toString("utf8"), { enforceCurrentWindow });
  } finally {
    bytes.fill(0);
  }
}

function reviewedKeyOptions(options, metadata) {
  const reviewedKeyId = required(options, "--moderation-key-id");
  const privateKeyPath = required(options, "--private-key");
  const expectedPublicKeySHA256 = required(options, "--expected-public-key-sha256");
  validateModerationKeyId(reviewedKeyId);
  validateExpectedPublicKeySHA256(expectedPublicKeySHA256);
  if (reviewedKeyId !== metadata.moderationKeyId) {
    throw new ModerationToolError("reviewed moderation key ID does not match metadata");
  }
  const expectedPrivateFilename = `${reviewedKeyId}.private.raw`;
  if (basename(privateKeyPath) !== expectedPrivateFilename) {
    throw new ModerationToolError("private key path does not match the reviewed key ID");
  }
  return Object.freeze({
    reviewedKeyId,
    privateKeyPath,
    companionPublicKeyPath: join(
      dirname(privateKeyPath),
      `${reviewedKeyId}.public.base64url`,
    ),
    expectedPublicKeySHA256,
  });
}

function loadAndVerifyReviewedPrivateKey(reviewed, metadata) {
  const privateKey = readBoundedRegularFile(
    reviewed.privateKeyPath,
    32,
    "private key file",
    { requireOwnerOnly: true },
  );
  let companionPublicKey;
  try {
    companionPublicKey = readBoundedRegularFile(
      reviewed.companionPublicKeyPath,
      43,
      "companion public key file",
      { requireOwnerOnly: true },
    );
    verifyReviewedModerationPrivateKey({
      reviewedKeyId: reviewed.reviewedKeyId,
      metadataKeyId: metadata.moderationKeyId,
      privateKeyBytes: privateKey,
      companionPublicKeyBytes: companionPublicKey,
      expectedPublicKeySHA256: reviewed.expectedPublicKeySHA256,
    });
    return privateKey;
  } catch (error) {
    privateKey.fill(0);
    throw error;
  } finally {
    companionPublicKey?.fill(0);
  }
}

function isDefinitelyAbsent(path) {
  try {
    lstatSync(path, { bigint: true });
    return false;
  } catch (error) {
    return error?.code === "ENOENT";
  }
}

/**
 * Best-effort cleanup for the restricted plaintext review pair.
 *
 * The receipt is the only descriptor that can later authorize deletion of a
 * plaintext review image. Never remove it unless the image is confirmed
 * absent; a locked, hard-linked, replaced, or otherwise unverifiable image
 * must keep its receipt for operator recovery.
 */
function cleanupRestrictedReviewFiles({
  outputPath,
  receiptPath,
  outputSHA256,
  receiptSHA256,
  outputWasNeverAttempted = false,
  outputDeletionConfirmed = false,
  receiptWasNeverAttempted = false,
  receiptDeletionConfirmed = false,
}) {
  let outputAbsent = isDefinitelyAbsent(outputPath);
  let outputSafeToForget = outputDeletionConfirmed && outputAbsent;
  if (outputWasNeverAttempted && outputAbsent) outputSafeToForget = true;
  if (!outputAbsent) {
    try {
      deleteBoundedRegularFile(
        outputPath,
        MAXIMUM_CANONICAL_JPEG_BYTES,
        outputSHA256,
      );
      outputSafeToForget = true;
    } catch { /* preserve the receipt and report incomplete cleanup */ }
    outputAbsent = isDefinitelyAbsent(outputPath);
    outputSafeToForget = outputSafeToForget && outputAbsent;
  }

  let receiptAbsent = isDefinitelyAbsent(receiptPath);
  let receiptSafeToForget = receiptDeletionConfirmed && receiptAbsent;
  if (receiptWasNeverAttempted && receiptAbsent) receiptSafeToForget = true;
  if (outputSafeToForget && outputAbsent
      && !receiptAbsent && isDefinitelyAbsent(outputPath)) {
    try {
      deleteBoundedRegularFile(
        receiptPath,
        MODERATION_REVIEW_RECEIPT_BYTES,
        receiptSHA256,
      );
      receiptSafeToForget = true;
    } catch { /* report incomplete cleanup */ }
    receiptAbsent = isDefinitelyAbsent(receiptPath);
    receiptSafeToForget = receiptSafeToForget && receiptAbsent;
  }

  return {
    complete: outputSafeToForget && outputAbsent
      && receiptSafeToForget && receiptAbsent,
    outputAbsent,
    outputDeletionConfirmed: outputSafeToForget,
    receiptAbsent,
    receiptDeletionConfirmed: receiptSafeToForget,
  };
}

function decryptCommand(values) {
  const options = parseOptions(
    values,
    new Set([
      "--metadata",
      "--ciphertext",
      "--moderation-key-id",
      "--private-key",
      "--expected-public-key-sha256",
      "--output",
      "--audit-log",
    ]),
    new Set(["--delete-ciphertext-after-success"]),
  );
  const metadataPath = required(options, "--metadata");
  const ciphertextPath = required(options, "--ciphertext");
  const outputPath = required(options, "--output");
  const auditPath = required(options, "--audit-log");
  const receiptPath = `${outputPath}.receipt`;
  const metadata = loadMetadata(metadataPath);
  const reviewed = reviewedKeyOptions(options, metadata);
  requireDistinctPaths([
    metadataPath,
    ciphertextPath,
    reviewed.privateKeyPath,
    reviewed.companionPublicKeyPath,
    outputPath,
    receiptPath,
    auditPath,
  ]);
  if (existsSync(outputPath)) throw new ModerationToolError("output already exists; overwrite is refused");
  if (existsSync(receiptPath)) {
    throw new ModerationToolError(
      "review receipt exists without a new output; automatic resume is refused",
    );
  }

  const envelope = readBoundedRegularFile(
    ciphertextPath,
    MAXIMUM_REPORT_CIPHERTEXT_BYTES,
    "ciphertext file",
    { requireOwnerOnly: true },
  );
  validateModerationCiphertextDescriptor(metadata, envelope);
  const privateKey = loadAndVerifyReviewedPrivateKey(reviewed, metadata);
  let result;
  let receipt;
  let retainReviewFiles = false;
  let outputWriteAttempted = false;
  let outputDeletionConfirmed = false;
  let receiptWriteAttempted = false;
  let receiptDeletionConfirmed = false;
  let outputSHA256;
  let receiptSHA256;
  try {
    result = decryptModerationReport(metadata, envelope, privateKey);
    receipt = createModerationReviewReceipt(metadata, result.canonicalJPEG);
    outputSHA256 = createHash("sha256").update(result.canonicalJPEG).digest();
    receiptSHA256 = createHash("sha256").update(receipt).digest();
    try {
      // Persist the non-image deletion receipt first. A crash can then leave
      // a harmless but ambiguous orphan receipt, but never an unaudited JPEG
      // without its validated cleanup descriptor. Automatic resume is refused
      // because receipt-only is also the plaintext-deletion crash boundary.
      receiptWriteAttempted = true;
      writeOwnerOnlyFile(receiptPath, receipt);
      outputWriteAttempted = true;
      writeOwnerOnlyFile(outputPath, result.canonicalJPEG);
      requireDistinctPaths([
        metadataPath,
        ciphertextPath,
        reviewed.privateKeyPath,
        reviewed.companionPublicKeyPath,
        outputPath,
        receiptPath,
        auditPath,
      ]);
    } catch (error) {
      const cleanup = cleanupRestrictedReviewFiles({
        outputPath,
        receiptPath,
        outputSHA256,
        receiptSHA256,
        outputWasNeverAttempted: !outputWriteAttempted,
        outputDeletionConfirmed,
        receiptWasNeverAttempted: !receiptWriteAttempted,
        receiptDeletionConfirmed,
      });
      outputDeletionConfirmed = cleanup.outputDeletionConfirmed;
      receiptDeletionConfirmed = cleanup.receiptDeletionConfirmed;
      if (!cleanup.complete) {
        throw new ModerationToolError(
          "restricted review output setup failed and cleanup could not be completed",
        );
      }
      throw error;
    }
    try {
      appendAuditEvent(auditPath, auditEvent("decrypt_succeeded", metadata));
    } catch (error) {
      const cleanup = cleanupRestrictedReviewFiles({
        outputPath,
        receiptPath,
        outputSHA256,
        receiptSHA256,
        outputWasNeverAttempted: !outputWriteAttempted,
        outputDeletionConfirmed,
        receiptWasNeverAttempted: !receiptWriteAttempted,
        receiptDeletionConfirmed,
      });
      outputDeletionConfirmed = cleanup.outputDeletionConfirmed;
      receiptDeletionConfirmed = cleanup.receiptDeletionConfirmed;
      if (!cleanup.complete) {
        throw new ModerationToolError(
          "audit write failed and restricted review output cleanup could not be completed",
        );
      }
      throw error;
    }
    retainReviewFiles = true;
    if (options.get("--delete-ciphertext-after-success") === true) {
      appendAuditEvent(
        auditPath,
        auditEvent("local_ciphertext_deletion_started", metadata),
      );
      const expectedCiphertextSHA256 = createHash("sha256").update(envelope).digest();
      try {
        deleteBoundedRegularFile(
          ciphertextPath,
          MAXIMUM_REPORT_CIPHERTEXT_BYTES,
          expectedCiphertextSHA256,
        );
      } catch (error) {
        try {
          appendAuditEvent(auditPath, auditEvent("local_deletion_failed", metadata));
        } catch { /* retain the first safe error */ }
        throw error;
      } finally {
        expectedCiphertextSHA256.fill(0);
      }
      try {
        appendAuditEvent(auditPath, auditEvent("local_ciphertext_deleted", metadata));
      } catch {
        throw new ModerationToolError(
          "ciphertext was deleted, but its completion audit could not be appended; the deletion-started event remains",
        );
      }
    }
  } finally {
    privateKey.fill(0);
    result?.canonicalJPEG.fill(0);
    receipt?.fill(0);
    // The envelope is ciphertext, but clear the process copy consistently.
    envelope.fill(0);
    if (!retainReviewFiles
        && outputSHA256 !== undefined
        && receiptSHA256 !== undefined) {
      cleanupRestrictedReviewFiles({
        outputPath,
        receiptPath,
        outputSHA256,
        receiptSHA256,
        outputWasNeverAttempted: !outputWriteAttempted,
        outputDeletionConfirmed,
        receiptWasNeverAttempted: !receiptWriteAttempted,
        receiptDeletionConfirmed,
      });
    }
    outputSHA256?.fill(0);
    receiptSHA256?.fill(0);
  }
  return "Report decrypted and validated; restricted review output created.\n";
}

function deleteCommand(values) {
  const options = parseOptions(
    values,
    new Set([
      "--metadata",
      "--file",
      "--kind",
      "--receipt",
      "--audit-log",
      "--moderation-key-id",
      "--private-key",
      "--expected-public-key-sha256",
    ]),
    new Set(["--confirm-delete"]),
  );
  if (options.get("--confirm-delete") !== true) {
    throw new ModerationToolError("explicit deletion confirmation is required");
  }
  const metadataPath = required(options, "--metadata");
  const filePath = required(options, "--file");
  const kind = required(options, "--kind");
  const auditPath = required(options, "--audit-log");
  if (kind !== "plaintext" && kind !== "ciphertext") {
    throw new ModerationToolError("deletion kind must be plaintext or ciphertext");
  }
  const receiptPath = options.get("--receipt");
  if (kind === "plaintext" && typeof receiptPath !== "string") {
    throw new ModerationToolError("plaintext deletion requires its review receipt");
  }
  if (kind === "ciphertext" && receiptPath !== undefined) {
    throw new ModerationToolError("ciphertext deletion must not receive a review receipt");
  }
  const metadata = loadMetadata(metadataPath, { enforceCurrentWindow: false });
  const reviewed = reviewedKeyOptions(options, metadata);
  requireDistinctPaths([
    metadataPath,
    filePath,
    ...(typeof receiptPath === "string" ? [receiptPath] : []),
    auditPath,
    reviewed.privateKeyPath,
    reviewed.companionPublicKeyPath,
  ]);
  const privateKey = loadAndVerifyReviewedPrivateKey(reviewed, metadata);
  privateKey.fill(0);
  const maximumBytes = kind === "plaintext"
    ? MAXIMUM_CANONICAL_JPEG_BYTES
    : MAXIMUM_REPORT_CIPHERTEXT_BYTES;
  const candidate = readBoundedRegularFile(
    filePath,
    maximumBytes,
    "deletion target",
    { requireOwnerOnly: true },
  );
  let receipt;
  let expectedFileSHA256;
  let expectedReceiptSHA256;
  try {
    if (kind === "plaintext") {
      validateCanonicalJPEG(candidate);
      receipt = readBoundedRegularFile(
        receiptPath,
        MODERATION_REVIEW_RECEIPT_BYTES,
        "review receipt",
        { requireOwnerOnly: true },
      );
      validateModerationReviewReceipt(receipt, metadata, candidate);
      expectedReceiptSHA256 = createHash("sha256").update(receipt).digest();
    } else {
      validateModerationCiphertextDescriptor(
        metadata,
        candidate,
        { enforceCurrentWindow: false },
      );
    }
    expectedFileSHA256 = createHash("sha256").update(candidate).digest();
  } finally {
    candidate.fill(0);
    receipt?.fill(0);
  }

  const startedEvent = kind === "plaintext"
    ? "local_plaintext_deletion_started"
    : "local_ciphertext_deletion_started";
  appendAuditEvent(auditPath, auditEvent(startedEvent, metadata));
  try {
    deleteBoundedRegularFile(filePath, maximumBytes, expectedFileSHA256);
    if (kind === "plaintext") {
      deleteBoundedRegularFile(
        receiptPath,
        MODERATION_REVIEW_RECEIPT_BYTES,
        expectedReceiptSHA256,
      );
    }
  } catch (error) {
    try {
      appendAuditEvent(auditPath, auditEvent("local_deletion_failed", metadata));
    } catch { /* the durable started event remains the recovery boundary */ }
    throw error;
  } finally {
    expectedFileSHA256?.fill(0);
    expectedReceiptSHA256?.fill(0);
  }
  try {
    appendAuditEvent(
      auditPath,
      auditEvent(kind === "plaintext" ? "local_plaintext_deleted" : "local_ciphertext_deleted", metadata),
    );
  } catch {
    throw new ModerationToolError(
      "the validated artifact was deleted, but its completion audit could not be appended; the deletion-started event remains",
    );
  }
  return "Confirmed local moderation artifact deleted; audit event appended.\n";
}

export function main(argv = process.argv.slice(2)) {
  const [command, ...values] = argv;
  const windowsPlan = process.platform === "win32"
    ? createWindowsModerationSecurityPlan(argv)
    : undefined;
  for (const proof of windowsPlan?.pre ?? []) {
    runWindowsModerationSecurityProof(proof);
  }
  let successMessage;
  if (command === "decrypt") successMessage = decryptCommand(values);
  else if (command === "delete") successMessage = deleteCommand(values);
  else throw new ModerationToolError(usage());
  for (const proof of windowsPlan?.post ?? []) {
    runWindowsModerationSecurityProof(proof);
  }
  process.stdout.write(successMessage);
}

const invokedDirectly = (() => {
  if (process.argv[1] === undefined) return false;
  try {
    const invokedPath = realpathSync.native(resolve(process.argv[1]));
    const modulePath = realpathSync.native(fileURLToPath(import.meta.url));
    return process.platform === "win32"
      ? invokedPath.toLowerCase() === modulePath.toLowerCase()
      : invokedPath === modulePath;
  } catch {
    return false;
  }
})();
if (invokedDirectly) {
  try {
    main();
  } catch (error) {
    const message = error instanceof ModerationToolError
      ? error.message
      : "unexpected failure";
    process.stderr.write(`Moderation report operation failed: ${message}\n`);
    process.exitCode = 1;
  }
}
