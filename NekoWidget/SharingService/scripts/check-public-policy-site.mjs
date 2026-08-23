#!/usr/bin/env node

import process from "node:process";
import { checkPublicPolicySite } from "./public-policy-site-check-lib.mjs";

function usage() {
  return "Usage: node scripts/check-public-policy-site.mjs --site-base https://example.com/policy/ --expected-revision YYYY-MM-DD";
}

function parseArguments(argv) {
  let siteBase = process.env.NEKO_PUBLIC_POLICY_SITE_BASE;
  let expectedRevision = process.env.NEKO_PUBLIC_POLICY_REVISION;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--site-base" && argv[index + 1] !== undefined) {
      siteBase = argv[index + 1];
      index += 1;
    } else if (argument === "--expected-revision" && argv[index + 1] !== undefined) {
      expectedRevision = argv[index + 1];
      index += 1;
    } else {
      throw new Error(`unknown or incomplete argument: ${argument ?? "<missing>"}`);
    }
  }

  if (siteBase === undefined || expectedRevision === undefined) {
    throw new Error(usage());
  }
  return { siteBase, expectedRevision };
}

try {
  const input = parseArguments(process.argv.slice(2));
  const result = await checkPublicPolicySite(input);
  const summary = result.pages
    .map((page) => `${page.name}=200/${page.bytes}B/${page.revision}`)
    .join(", ");
  console.log(`PASS public policy site: ${summary}`);
} catch (error) {
  const message = error instanceof Error ? error.message : "unknown public policy site check failure";
  console.error(`FAIL public policy site check: ${message}`);
  process.exitCode = 1;
}
