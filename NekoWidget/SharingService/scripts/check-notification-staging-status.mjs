#!/usr/bin/env node

import process from "node:process";

import {
  collectNotificationStagingStatus,
  formatNotificationStagingStatus,
  requireNoStatusArguments,
} from "./notification-staging-status-lib.mjs";

try {
  requireNoStatusArguments(process.argv.slice(2));
  const status = await collectNotificationStagingStatus();
  console.log(formatNotificationStagingStatus(status));
} catch (error) {
  const message = error instanceof Error ? error.message : "unknown notification status failure";
  console.error(`FAIL notification staging status: ${message}`);
  process.exitCode = 1;
}
