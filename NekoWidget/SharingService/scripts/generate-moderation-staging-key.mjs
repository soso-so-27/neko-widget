#!/usr/bin/env node

import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  ModerationKeygenError,
  generateStagingModerationKeyFiles,
} from "./moderation-staging-keygen-lib.mjs";

function usage() {
  return [
    "Staging-only offline moderation key generation",
    "",
    "Windows (required wrapper):",
    "  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/moderation-staging-keygen-windows.ps1 \\",
    "    -OutputDirectory <absolute-new-directory> -ConfirmLocalEncryptedNoSync",
    "",
    "Operational key generation is Windows-only; do not invoke this Node helper directly.",
  ].join("\n");
}

export function parseArguments(argv) {
  let outputDirectory;
  let confirmed = false;
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--confirm-local-encrypted-nosync") {
      if (confirmed) throw new ModerationKeygenError("confirmation was supplied more than once");
      confirmed = true;
      continue;
    }
    if (value !== "--output-dir") {
      throw new ModerationKeygenError("an unsupported option was supplied");
    }
    if (outputDirectory !== undefined) {
      throw new ModerationKeygenError("output directory was supplied more than once");
    }
    const next = argv[index + 1];
    if (typeof next !== "string" || next.length === 0 || next.startsWith("--")) {
      throw new ModerationKeygenError("output directory value is missing");
    }
    outputDirectory = next;
    index += 1;
  }
  if (outputDirectory === undefined) {
    throw new ModerationKeygenError("output directory is required");
  }
  return { outputDirectory, confirmed };
}

export function runCLI(
  argv = process.argv.slice(2),
  {
    generate = generateStagingModerationKeyFiles,
    stdout = process.stdout,
  } = {},
) {
  const options = parseArguments(argv);
  generate({
    outputDirectory: options.outputDirectory,
    confirmLocalEncryptedNoSync: options.confirmed,
  });
  stdout.write("Staging moderation key files were created with restricted access.\n");
}

const invokedDirectly = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (invokedDirectly) {
  try {
    runCLI();
  } catch (error) {
    const message = error instanceof ModerationKeygenError
      ? error.message
      : "unexpected failure";
    process.stderr.write(`Staging moderation key generation refused: ${message}\n${usage()}\n`);
    process.exitCode = 1;
  }
}
