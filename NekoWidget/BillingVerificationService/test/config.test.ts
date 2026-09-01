import assert from "node:assert/strict";
import test from "node:test";
import { Environment } from "@apple/app-store-server-library";
import { loadConfig } from "../src/config.js";

function environment(): NodeJS.ProcessEnv {
  return {
    BILLING_VERIFIER_RUNTIME_ENABLED: "YES",
    BILLING_VERIFIER_SHARED_SECRET: Buffer.alloc(32, 7).toString("base64url"),
    BILLING_NONCE_REDIS_URL: "rediss://billing-nonce.invalid:6380/0",
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
  assert.equal(result.notificationVerificationEnabled, false);
  assert.equal(result.subscriptionStatusEnabled, false);
  assert.equal(result.accountRecoveryVerificationEnabled, false);
  assert.equal(result.serverAPI, undefined);
  assert.equal(result.nonceRedisURL, "rediss://billing-nonce.invalid:6380/0");
});

test("requires a TLS Redis nonce store without URL options", () => {
  const missing = environment();
  delete missing.BILLING_NONCE_REDIS_URL;
  assert.throws(() => loadConfig(missing), /NONCE_REDIS_URL is required/u);

  const plaintext = environment();
  plaintext.BILLING_NONCE_REDIS_URL = "redis://billing-nonce.invalid:6379/0";
  assert.throws(() => loadConfig(plaintext), /must use TLS/u);

  const options = environment();
  options.BILLING_NONCE_REDIS_URL = "rediss://billing-nonce.invalid:6380/0?secret=value";
  assert.throws(() => loadConfig(options), /without query or fragment/u);
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

test("keeps notification verification independent from Server API credentials", () => {
  const notification = environment();
  notification.BILLING_NOTIFICATION_VERIFIER_RUNTIME_ENABLED = "YES";
  const result = loadConfig(notification);
  assert.equal(result.notificationVerificationEnabled, true);
  assert.equal(result.subscriptionStatusEnabled, false);
  assert.equal(result.serverAPI, undefined);

  notification.BILLING_NOTIFICATION_VERIFIER_RUNTIME_ENABLED = "yes";
  assert.throws(() => loadConfig(notification), /must be YES or NO/u);
});

test("requires isolated Server API credentials only behind the exact status switch", () => {
  const status = environment();
  status.BILLING_SUBSCRIPTION_STATUS_RUNTIME_ENABLED = "YES";
  assert.throws(() => loadConfig(status), /PRIVATE_KEY/u);
  status.APP_STORE_SERVER_API_PRIVATE_KEY = [
    "-----BEGIN PRIVATE KEY-----",
    "test-only-key",
    "-----END PRIVATE KEY-----",
  ].join("\n");
  status.APP_STORE_SERVER_API_KEY_ID = "ABCDEFGHIJ";
  status.APP_STORE_SERVER_API_ISSUER_ID = "c0938ad3-2941-4079-8248-0769666c8fd8";
  const result = loadConfig(status);
  assert.equal(result.subscriptionStatusEnabled, true);
  assert.equal(result.serverAPI?.keyId, "ABCDEFGHIJ");

  const disabled = environment();
  disabled.APP_STORE_SERVER_API_PRIVATE_KEY = status.APP_STORE_SERVER_API_PRIVATE_KEY;
  assert.throws(() => loadConfig(disabled), /require the exact runtime switch/u);
});

test("keeps account recovery verification behind its own exact switch", () => {
  const recovery = environment();
  recovery.BILLING_ACCOUNT_RECOVERY_VERIFIER_RUNTIME_ENABLED = "YES";
  assert.equal(loadConfig(recovery).accountRecoveryVerificationEnabled, true);
  recovery.BILLING_ACCOUNT_RECOVERY_VERIFIER_RUNTIME_ENABLED = "yes";
  assert.throws(() => loadConfig(recovery), /must be YES or NO/u);
});
