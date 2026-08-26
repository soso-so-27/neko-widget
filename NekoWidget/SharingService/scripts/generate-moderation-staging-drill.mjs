#!/usr/bin/env node

import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  ModerationStagingDrillError,
  generateStagingModerationDrillFiles,
} from "./moderation-staging-drill-lib.mjs";

function usage() {
  return [
    "Staging-only synthetic moderation decrypt/delete drill bundle",
    "",
    "Windows (required wrapper):",
    "  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/moderation-staging-drill-windows.ps1 \\",
    "    -KeyDirectory <existing-restricted-staging-key-directory> \\",
    "    -OutputDirectory <absolute-new-restricted-drill-directory> \\",
    "    -ModerationKeyId <moderation-v1|moderation-v2> \\",
    "    -ExpectedPublicKeySHA256 <reviewed-lowercase-hex> \\",
    "    -ConfirmLocalEncryptedNoSync",
    "",
    "This generator accepts a public key only. Production, network, deploy, upload, and runtime changes are prohibited.",
  ].join("\n");
}

export function parseArguments(argv) {
  let publicKeyFile;
  let moderationKeyId;
  let expectedPublicKeySHA256;
  let outputDirectory;
  let confirmed = false;
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === "--confirm-local-encrypted-nosync") {
      if (confirmed) throw new ModerationStagingDrillError("confirmation was supplied more than once");
      confirmed = true;
      continue;
    }
    if (!["--public-key-file", "--output-dir", "--moderation-key-id",
      "--expected-public-key-sha256"].includes(option)) {
      throw new ModerationStagingDrillError("an unsupported option was supplied");
    }
    const next = argv[index + 1];
    if (typeof next !== "string" || next.length === 0 || next.startsWith("--")) {
      throw new ModerationStagingDrillError("an option value is missing");
    }
    if (option === "--public-key-file") {
      if (publicKeyFile !== undefined) {
        throw new ModerationStagingDrillError("public-key file was supplied more than once");
      }
      publicKeyFile = next;
    } else if (option === "--output-dir") {
      if (outputDirectory !== undefined) {
        throw new ModerationStagingDrillError("output directory was supplied more than once");
      }
      outputDirectory = next;
    } else if (option === "--moderation-key-id") {
      if (moderationKeyId !== undefined) {
        throw new ModerationStagingDrillError("moderation key ID was supplied more than once");
      }
      moderationKeyId = next;
    } else {
      if (expectedPublicKeySHA256 !== undefined) {
        throw new ModerationStagingDrillError(
          "expected public-key SHA-256 was supplied more than once",
        );
      }
      expectedPublicKeySHA256 = next;
    }
    index += 1;
  }
  if (publicKeyFile === undefined || outputDirectory === undefined
      || !["moderation-v1", "moderation-v2"].includes(moderationKeyId)
      || typeof expectedPublicKeySHA256 !== "string"
      || !/^[0-9a-f]{64}$/u.test(expectedPublicKeySHA256)) {
    throw new ModerationStagingDrillError(
      "public-key file, output directory, exact key ID, and reviewed fingerprint are required",
    );
  }
  return {
    publicKeyFile,
    outputDirectory,
    moderationKeyId,
    expectedPublicKeySHA256,
    confirmed,
  };
}

export function runCLI(
  argv = process.argv.slice(2),
  {
    generate = generateStagingModerationDrillFiles,
    stdout = process.stdout,
  } = {},
) {
  const options = parseArguments(argv);
  generate({
    publicKeyFile: options.publicKeyFile,
    moderationKeyId: options.moderationKeyId,
    expectedPublicKeySHA256: options.expectedPublicKeySHA256,
    outputDirectory: options.outputDirectory,
    confirmLocalEncryptedNoSync: options.confirmed,
  });
  stdout.write("Synthetic staging moderation bundle created with restricted access; runtime and upload remain off.\n");
}

const invokedDirectly = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (invokedDirectly) {
  try {
    runCLI();
  } catch (error) {
    const message = error instanceof ModerationStagingDrillError
      ? error.message
      : "unexpected failure";
    process.stderr.write(`Synthetic staging moderation drill refused: ${message}\n${usage()}\n`);
    process.exitCode = 1;
  }
}
