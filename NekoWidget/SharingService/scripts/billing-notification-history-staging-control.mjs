#!/usr/bin/env node

import process from "node:process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  runHistoryStagingControl,
} from "./billing-notification-history-staging-control-lib.mjs";

const projectDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");

try {
  console.log(await runHistoryStagingControl(process.argv.slice(2), {
    projectDirectory,
  }));
} catch (error) {
  console.error(
    `FAIL notification history staging control: ${
      error instanceof Error ? error.message : "unknown failure"
    }`,
  );
  process.exitCode = 1;
}
