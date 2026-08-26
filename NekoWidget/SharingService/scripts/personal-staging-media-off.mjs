#!/usr/bin/env node

import process from "node:process";

import { runSelectiveOffControl } from "./selective-staging-off-lib.mjs";

try {
  console.log(await runSelectiveOffControl("media", process.argv.slice(2)));
} catch (error) {
  console.error(`FAIL media-only OFF: ${error instanceof Error ? error.message : "unknown failure"}`);
  process.exitCode = 1;
}
