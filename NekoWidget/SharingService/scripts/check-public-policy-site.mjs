#!/usr/bin/env node

import process from "node:process";
import {
  checkPublicPolicySite,
  resolvePublicPolicyCheckInput,
} from "./public-policy-site-check-lib.mjs";

function usage() {
  return "Usage: node scripts/check-public-policy-site.mjs --profile sharing-beta|local-only --site-base https://example.com/policy/ --expected-revision YYYY-MM-DD";
}

try {
  let input;
  try {
    input = resolvePublicPolicyCheckInput({
      argv: process.argv.slice(2),
      environment: process.env,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "invalid public policy check input";
    throw new Error(`${message}. ${usage()}`);
  }
  const result = await checkPublicPolicySite(input);
  const summary = result.pages
    .map((page) => `${page.name}=200/${page.bytes}B/${page.revision}`)
    .join(", ");
  console.log(`PASS public policy site profile=${result.profile}: ${summary}`);
} catch (error) {
  const message = error instanceof Error ? error.message : "unknown public policy site check failure";
  console.error(`FAIL public policy site check: ${message}`);
  process.exitCode = 1;
}
