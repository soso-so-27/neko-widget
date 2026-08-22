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
    "    -ConfirmLocalEncryptedNoSync",
    "",
    "This generator accepts a public key only. Production, network, deploy, upload, and runtime changes are prohibited.",
  ].join("\n");
}

export function parseArguments(argv) {
  let publicKeyFile;
  let outputDirectory;
  let confirmed = false;
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === "--confirm-local-encrypted-nosync") {
      if (confirmed) throw new ModerationStagingDrillError("confirmation was supplied more than once");
      confirmed = true;
      continue;
    }
    if (option !== "--public-key-file" && option !== "--output-dir") {
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
    } else {
      if (outputDirectory !== undefined) {
        throw new ModerationStagingDrillError("output directory was supplied more than once");
      }
      outputDirectory = next;
    }
    index += 1;
  }
  if (publicKeyFile === undefined || outputDirectory === undefined) {
    throw new ModerationStagingDrillError("public-key file and output directory are required");
  }
  return { publicKeyFile, outputDirectory, confirmed };
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
