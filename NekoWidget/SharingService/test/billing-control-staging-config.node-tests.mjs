import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  billingControlEnabledFlags,
  renderBillingControlStagingPair,
  validateBillingControlStagingPair,
} from "../scripts/billing-control-staging-config-lib.mjs";
import { validateStagingConfig } from "../scripts/staging-config-lib.mjs";

const projectDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const template = await readFile(
  join(projectDirectory, "wrangler.staging.template.jsonc"),
  "utf8",
);
const environment = Object.freeze({
  NEKO_STAGING_D1_DATABASE_ID: "00000000-0000-0000-0000-000000000000",
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
  NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID: "700004",
  NEKO_STAGING_BILLING_APPLE_NOTIFICATION_RATE_LIMIT_NAMESPACE_ID: "700005",
});

function pair() {
  const rendered = renderBillingControlStagingPair(template, environment);
  return {
    off: JSON.parse(rendered.off),
    on: JSON.parse(rendered.on),
  };
}

test("renders exact billing control OFF/ON candidates", () => {
  const { off, on } = pair();
  for (const flag of [
    "MOMENT_RUNTIME_ENABLED",
    "REACTION_RUNTIME_ENABLED",
    "WINDOW_NAME_RUNTIME_ENABLED",
    "APNS_RUNTIME_ENABLED",
    "REPORT_INGESTION_RUNTIME_ENABLED",
  ]) {
    assert.equal(off.vars[flag], "YES");
    assert.equal(on.vars[flag], "YES");
  }
  for (const flag of billingControlEnabledFlags) {
    assert.equal(off.vars[flag], "NO");
    assert.equal(on.vars[flag], "YES");
  }
  assert.doesNotThrow(() => validateBillingControlStagingPair(off, on));
});

test("keeps the tracked template and default validator fail closed", () => {
  const templateConfig = JSON.parse(template);
  for (const key of Object.keys(templateConfig.vars).filter((value) => (
    value.startsWith("BILLING_") && value.endsWith("_RUNTIME_ENABLED")
  ))) {
    assert.equal(templateConfig.vars[key], "NO");
  }
  const { on } = pair();
  assert.throws(() => validateStagingConfig(on), /reviewed staging policy/u);
});

test("rejects partial gates, binding drift, and secret vars", () => {
  for (const mutate of [
    (on) => { on.vars.BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED = "NO"; },
    (on) => { on.vars.BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED = "NO"; },
    (on) => { on.r2_buckets[0].bucket_name = "another-bucket"; },
    (on) => { on.vars.BILLING_VERIFIER_SHARED_SECRET = "must-not-be-in-vars"; },
    (on) => { on.vars.BILLING_VERIFIER_ACCESS_CLIENT_ID = "must-not-be-in-vars"; },
    (on) => { on.vars.BILLING_VERIFIER_ACCESS_CLIENT_SECRET = "must-not-be-in-vars"; },
  ]) {
    const { off, on } = pair();
    mutate(on);
    assert.throws(
      () => validateBillingControlStagingPair(off, on),
      /reviewed staging policy|unreviewed field|seven reviewed|not isolated/u,
    );
  }
});

test("requires the OFF candidate to remain the exact ordinary staging config", () => {
  const { off, on } = pair();
  off.vars.MOMENT_RUNTIME_ENABLED = "NO";
  assert.throws(
    () => validateBillingControlStagingPair(off, on),
    /reviewed staging policy/u,
  );
});

test("keeps both generated candidates and the manifest out of git", async () => {
  const ignore = await readFile(join(projectDirectory, ".gitignore"), "utf8");
  assert.match(ignore, /^wrangler\.billing-control-staging-off\.jsonc$/mu);
  assert.match(ignore, /^wrangler\.billing-control-staging-on\.jsonc$/mu);
  assert.match(ignore, /^billing-staging-runtime-gate-manifest\.json$/mu);
});
