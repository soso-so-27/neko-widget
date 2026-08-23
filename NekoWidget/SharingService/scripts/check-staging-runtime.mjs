#!/usr/bin/env node

import process from "node:process";
import { checkStagingRuntime } from "./staging-runtime-check-lib.mjs";

function usage() {
  return "Usage: node scripts/check-staging-runtime.mjs --expected on|moment-on-window-name-off|off [--origin https://example.com]";
}

function parseArguments(argv) {
  let origin = process.env.NEKO_STAGING_API_ORIGIN;
  let expected;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--origin") {
      origin = argv[index + 1];
      index += 1;
    } else if (argument === "--expected") {
      expected = argv[index + 1];
      index += 1;
    } else {
      throw new Error(`unknown or incomplete argument: ${argument ?? "<missing>"}`);
    }
  }

  if (origin === undefined || expected === undefined) {
    throw new Error(usage());
  }
  return { origin, expected };
}

try {
  const input = parseArguments(process.argv.slice(2));
  const result = await checkStagingRuntime(input);
  const summary = result.checks
    .map((check) => `${check.name}=${check.status}${check.code === undefined ? "" : `/${check.code}`}`)
    .join(", ");
  console.log(`PASS staging runtime expected=${result.expected}: ${summary}`);
} catch (error) {
  const message = error instanceof Error ? error.message : "unknown staging runtime check failure";
  console.error(`FAIL staging runtime check: ${message}`);
  process.exitCode = 1;
}
