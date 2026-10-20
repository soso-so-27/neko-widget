#!/usr/bin/env node

import process from "node:process";
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyReadiness } from '../../ci/verify-moderation-readiness.mjs';
import { checkStagingRuntime } from "./staging-runtime-check-lib.mjs";

function usage() {
  return "Usage: node scripts/check-staging-runtime.mjs --expected on|limited-external-beta|internal-purchase-sandbox|internal-purchase-sandbox-report-ui-continuation|internal-report-first-connection|internal-report-ui-continuation|moment-on-window-name-off|off [--origin https://example.com]";
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

export async function resolveReportRuntimeExpected(expected, { evidence, policy, verify = verifyReadiness } = {}) {
  const combined = expected === 'internal-purchase-sandbox-report-ui-continuation';
  if (!combined && !['internal-report-first-connection', 'internal-report-ui-continuation'].includes(expected)) return expected;
  evidence ??= JSON.parse(await readFile(new URL('../../ci/moderation-v2-readiness.json', import.meta.url), 'utf8'));
  policy ??= JSON.parse(await readFile(new URL('../../ci/moderation-client-rollout-policy.json', import.meta.url), 'utf8'));
  const checked = await verify(evidence, policy);
  if (checked.purpose === 'testflight-owner-report-ui-continuation') return combined ? expected : 'internal-report-ui-continuation';
  if (expected === 'internal-report-first-connection' && checked.purpose === 'testflight-owner-first-connection') return expected;
  throw new Error('Signed readiness purpose does not authorize this internal runtime phase');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
try {
  const input = parseArguments(process.argv.slice(2));
  input.expected = await resolveReportRuntimeExpected(input.expected);
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

}
