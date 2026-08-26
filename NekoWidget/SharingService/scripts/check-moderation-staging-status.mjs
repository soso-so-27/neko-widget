#!/usr/bin/env node

import process from "node:process";

import {
  collectModerationStagingStatus,
  formatModerationStagingStatus,
  requireNoModerationStatusArguments,
} from "./moderation-staging-status-lib.mjs";

try {
  requireNoModerationStatusArguments(process.argv.slice(2));
  const status = await collectModerationStagingStatus();
  console.log(formatModerationStagingStatus(status));
} catch (error) {
  const message = error instanceof Error ? error.message : "unknown moderation status failure";
  console.error(`FAIL moderation staging status: ${message}`);
  process.exitCode = 1;
}
