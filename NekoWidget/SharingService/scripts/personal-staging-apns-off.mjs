#!/usr/bin/env node

import process from "node:process";

import { runSelectiveOffControl } from "./selective-staging-off-lib.mjs";

try {
  console.log(await runSelectiveOffControl("apns", process.argv.slice(2)));
} catch (error) {
  console.error(`FAIL APNs-only OFF: ${error instanceof Error ? error.message : "unknown failure"}`);
  process.exitCode = 1;
}
