#!/usr/bin/env node

import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  ModerationStagingDrillError,
  verifyCompletedSyntheticDrillDirectory,
  verifySyntheticDrillBundleDirectory,
  verifySyntheticDrillReviewDirectory,
} from "./moderation-staging-drill-lib.mjs";

export function parseArguments(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const option = argv[index];
    const value = argv[index + 1];
    if (!["--phase", "--drill-dir"].includes(option) || values.has(option)
        || typeof value !== "string" || value.length === 0 || value.startsWith("--")) {
      throw new ModerationStagingDrillError("one explicit phase and drill directory are required");
    }
    values.set(option, value);
  }
  const phase = values.get("--phase");
  const drillDirectory = values.get("--drill-dir");
  if (!["bundle", "review", "deleted"].includes(phase)
      || typeof drillDirectory !== "string" || values.size !== 2) {
    throw new ModerationStagingDrillError("one explicit phase and drill directory are required");
  }
  return { phase, drillDirectory };
}

export function runCLI(argv = process.argv.slice(2), { stdout = process.stdout } = {}) {
  const options = parseArguments(argv);
  if (options.phase === "bundle") {
    verifySyntheticDrillBundleDirectory(options.drillDirectory);
    stdout.write("Fixed synthetic staging bundle identity and descriptor verified before private-key use.\n");
  } else if (options.phase === "review") {
    verifySyntheticDrillReviewDirectory(options.drillDirectory);
    stdout.write("Fixed synthetic review bytes, receipt binding, and initial audit transition verified.\n");
  } else {
    verifyCompletedSyntheticDrillDirectory(options.drillDirectory);
    stdout.write("Synthetic staging moderation decrypt/delete drill completion verified; no review, receipt, or ciphertext artifact remains.\n");
  }
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
    process.stderr.write(`Synthetic staging moderation drill completion refused: ${message}\n`);
    process.exitCode = 1;
  }
}
