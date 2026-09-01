#!/usr/bin/env node

import process from "node:process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { runBillingRuntimeGateControl } from "./billing-staging-runtime-gate-lib.mjs";

const projectDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
try {
  console.log(await runBillingRuntimeGateControl(process.argv.slice(2), {
    projectDirectory,
  }));
} catch (error) {
  console.error(
    `FAIL billing runtime gate control: ${
      error instanceof Error ? error.message : "unknown failure"
    }`,
  );
  process.exitCode = 1;
}
