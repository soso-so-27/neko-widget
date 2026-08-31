import assert from "node:assert/strict";
import test from "node:test";
import { Environment } from "@apple/app-store-server-library";
import { loadConfig } from "../src/config.js";

function environment(): NodeJS.ProcessEnv {
  return {
    BILLING_VERIFIER_RUNTIME_ENABLED: "YES",
    BILLING_VERIFIER_SHARED_SECRET: Buffer.alloc(32, 7).toString("base64url"),
    APPLE_ROOT_CERTIFICATES_BASE64_JSON: JSON.stringify([
      Buffer.alloc(300, 1).toString("base64"),
    ]),
    BILLING_STORE_ENVIRONMENT: Environment.SANDBOX,
    BILLING_BUNDLE_ID: "jp.nekowidget.app",
    BILLING_SUBSCRIPTION_GROUP_ID: "20999999",
    BILLING_MONTHLY_PRODUCT_ID: "jp.nekowidget.plus.monthly",
    BILLING_ANNUAL_PRODUCT_ID: "jp.nekowidget.plus.annual",
  };
}

test("loads only an explicit Sandbox verifier configuration", () => {
  const result = loadConfig(environment());
  assert.equal(result.environment, Environment.SANDBOX);
  assert.equal(result.rootCertificates.length, 1);
  assert.equal(result.appAppleId, undefined);
});

test("requires appAppleId in Production and rejects test bypass environments", () => {
  const production = environment();
  production.BILLING_STORE_ENVIRONMENT = Environment.PRODUCTION;
  assert.throws(() => loadConfig(production), /APP_APPLE_ID/u);
  production.BILLING_APP_APPLE_ID = "6801962436";
  assert.equal(loadConfig(production).appAppleId, 6_801_962_436);

  const bypass = environment();
  bypass.BILLING_STORE_ENVIRONMENT = Environment.LOCAL_TESTING;
  assert.throws(() => loadConfig(bypass), /STORE_ENVIRONMENT/u);
});

test("fails closed unless the runtime flag is exact YES", () => {
  const disabled = environment();
  disabled.BILLING_VERIFIER_RUNTIME_ENABLED = "yes";
  assert.throws(() => loadConfig(disabled), /disabled/u);
});
