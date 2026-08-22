#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, lstatSync, realpathSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
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
  validateCanonicalJPEG,
  validateModerationCiphertextDescriptor,
  validateModerationReviewReceipt,
  writeOwnerOnlyFile,
} from "./moderation-report-lib.mjs";

function usage() {
  return [
    "Offline moderation report tool",
    "",
    "Decrypt:",
    "  node scripts/moderation-report-tool.mjs decrypt \\",
    "    --metadata <export.json> --ciphertext <report.ciphertext> \\",
    "    --private-key <32-byte-raw-key> --output <review.jpg> \\",
    "    --audit-log <audit.jsonl> [--delete-ciphertext-after-success]",
    "",
    "Delete a local review artifact after the case decision:",
    "  node scripts/moderation-report-tool.mjs delete \\",
    "    --metadata <export.json> --file <review.jpg|report.ciphertext> \\",
    "    --kind <plaintext|ciphertext> [--receipt <review.jpg.receipt>] \\",
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
    new Set(["--metadata", "--ciphertext", "--private-key", "--output", "--audit-log"]),
    new Set(["--delete-ciphertext-after-success"]),
  );
  const metadataPath = required(options, "--metadata");
  const ciphertextPath = required(options, "--ciphertext");
  const privateKeyPath = required(options, "--private-key");
  const outputPath = required(options, "--output");
  const auditPath = required(options, "--audit-log");
  const receiptPath = `${outputPath}.receipt`;
  requireDistinctPaths([
    metadataPath,
    ciphertextPath,
    privateKeyPath,
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

  const metadata = loadMetadata(metadataPath);
  const envelope = readBoundedRegularFile(
    ciphertextPath,
    MAXIMUM_REPORT_CIPHERTEXT_BYTES,
    "ciphertext file",
    { requireOwnerOnly: true },
  );
  const privateKey = readBoundedRegularFile(
    privateKeyPath,
    32,
    "private key file",
    { requireOwnerOnly: true },
  );
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
        privateKeyPath,
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
  process.stdout.write("Report decrypted and validated; restricted review output created.\n");
}

function deleteCommand(values) {
  const options = parseOptions(
    values,
    new Set(["--metadata", "--file", "--kind", "--receipt", "--audit-log"]),
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
  requireDistinctPaths([
    metadataPath,
    filePath,
    ...(typeof receiptPath === "string" ? [receiptPath] : []),
    auditPath,
  ]);
  const metadata = loadMetadata(metadataPath, { enforceCurrentWindow: false });
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
  process.stdout.write("Confirmed local moderation artifact deleted; audit event appended.\n");
}

export function main(argv = process.argv.slice(2)) {
  const [command, ...values] = argv;
  if (command === "decrypt") decryptCommand(values);
  else if (command === "delete") deleteCommand(values);
  else throw new ModerationToolError(usage());
}

const invokedDirectly = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
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
