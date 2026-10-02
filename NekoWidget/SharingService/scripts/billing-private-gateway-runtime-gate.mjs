#!/usr/bin/env node

import process from "node:process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runBillingRuntimeGateControl } from "./billing-staging-runtime-gate-lib.mjs";

try {
  console.log(await runBillingRuntimeGateControl(process.argv.slice(2), {
    projectDirectory: join(dirname(fileURLToPath(import.meta.url)), ".."),
    profile: "private-gateway",
  }));
} catch (error) {
  console.error(`FAIL private billing operation: ${error instanceof Error ? error.message : "unknown failure"}`);
  process.exitCode = 1;
}
