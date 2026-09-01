#!/usr/bin/env node

import process from "node:process";
import { join } from "node:path";

import { runWorkersDevControl } from "./personal-staging-workers-dev-control-lib.mjs";

const projectDirectory = join(import.meta.dirname, "..");

try {
  console.log(await runWorkersDevControl(process.argv.slice(2), {
    projectDirectory,
    environment: process.env,
  }));
} catch (error) {
  console.error(`FAIL personal staging workers.dev control: ${
    error instanceof Error ? error.message : "unknown failure"
  }`);
  process.exitCode = 1;
}
