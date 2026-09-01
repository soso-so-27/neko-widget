import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

import {
  MODERATION_OPERATOR_CONTROL_PLANE_PREFLIGHT_FAILURE_CODE,
  ModerationOperatorControlPlanePreflightError,
  validateModerationOperatorControlPlanePreflight,
} from "../scripts/moderation-operator-control-plane-preflight-lib.mjs";

const reviewed = {
  schemaVersion: 1,
  accountId: "0".repeat(32),
  applicationId: "11111111-1111-4111-8111-111111111111",
  applicationDomain: "moderation.operator.example.test",
  applicationOrigin: "https://moderation.operator.example.test",
  applicationAudience: "a".repeat(64),
  accessIssuer: "https://neko-operator.cloudflareaccess.com",
  allowPolicyId: "22222222-2222-4222-8222-222222222222",
  identityProviderId: "33333333-3333-4333-8333-333333333333",
  webAuthnRpId: "moderation.operator.example.test",
  runtimeVerifierIssuer: "https://neko-operator.cloudflareaccess.com",
  runtimeVerifierAudience: "a".repeat(64),
  operatorRateLimits: [
    {
      limiterId: "OPERATOR_AUTH_RATE_LIMITER",
      periodSeconds: 10,
      limit: 5,
    },
    {
      limiterId: "OPERATOR_ACTION_RATE_LIMITER",
      periodSeconds: 60,
      limit: 30,
    },
  ],
  publicLimiterIds: [
    "CREATE_RATE_LIMITER",
    "INVITE_RATE_LIMITER",
    "MEMBER_RATE_LIMITER",
    "BILLING_RATE_LIMITER",
    "BILLING_APPLE_NOTIFICATION_RATE_LIMITER",
  ],
};

const snapshot = {
  schemaVersion: 1,
  accountId: reviewed.accountId,
  application: {
    id: reviewed.applicationId,
    type: "self_hosted",
    domain: reviewed.applicationDomain,
    origin: reviewed.applicationOrigin,
    audience: reviewed.applicationAudience,
    accessIssuer: reviewed.accessIssuer,
    webAuthnRpId: reviewed.webAuthnRpId,
    runtimeVerifier: {
      issuer: reviewed.runtimeVerifierIssuer,
      audience: reviewed.runtimeVerifierAudience,
    },
    sessionDurationSeconds: 900,
    policiesComplete: true,
    serviceAuthEnabled: false,
    warpAuthenticationEnabled: false,
    policies: [{
      id: reviewed.allowPolicyId,
      decision: "allow",
      sessionDurationSeconds: 900,
      identityProviderIds: [reviewed.identityProviderId],
      authenticationMethods: ["security_key"],
      mfaReauthentication: "every_session",
      managedDevicePostureRequired: true,
      everyoneIncluded: false,
      serviceTokenIncluded: false,
      warpAuthenticationIncluded: false,
    }],
  },
  rateLimits: {
    accountNamespaceInventoryComplete: true,
    operatorBindings: [
      {
        limiterId: "OPERATOR_AUTH_RATE_LIMITER",
        namespaceId: "200001",
        periodSeconds: 10,
        limit: 5,
      },
      {
        limiterId: "OPERATOR_ACTION_RATE_LIMITER",
        namespaceId: "200002",
        periodSeconds: 60,
        limit: 30,
      },
    ],
    accountNamespaceBindings: [
      { limiterId: "CREATE_RATE_LIMITER", namespaceId: "100001" },
      { limiterId: "INVITE_RATE_LIMITER", namespaceId: "100002" },
      { limiterId: "MEMBER_RATE_LIMITER", namespaceId: "100003" },
      { limiterId: "BILLING_RATE_LIMITER", namespaceId: "100004" },
      { limiterId: "BILLING_APPLE_NOTIFICATION_RATE_LIMITER", namespaceId: "100005" },
      { limiterId: "OPERATOR_AUTH_RATE_LIMITER", namespaceId: "200001" },
      { limiterId: "OPERATOR_ACTION_RATE_LIMITER", namespaceId: "200002" },
      { limiterId: "OTHER_ACCOUNT_LIMITER", namespaceId: "300001" },
    ],
  },
};

function copyReviewed() {
  return structuredClone(reviewed);
}

function copySnapshot() {
  return structuredClone(snapshot);
}

function fixedFailure(reviewedValue, snapshotValue) {
  let caught;
  try {
    validateModerationOperatorControlPlanePreflight(
      reviewedValue,
      snapshotValue,
    );
  } catch (error) {
    caught = error;
  }
  assert.ok(caught instanceof ModerationOperatorControlPlanePreflightError);
  assert.equal(
    caught.code,
    MODERATION_OPERATOR_CONTROL_PLANE_PREFLIGHT_FAILURE_CODE,
  );
  assert.equal(
    caught.message,
    "Moderation operator control-plane preflight failed.",
  );
  assert.equal(JSON.stringify(caught), JSON.stringify({
    name: "ModerationOperatorControlPlanePreflightError",
    code: MODERATION_OPERATOR_CONTROL_PLANE_PREFLIGHT_FAILURE_CODE,
  }));
}

test("accepts only the reviewed app and returns a minimal hard-boundary contract", () => {
  const result = validateModerationOperatorControlPlanePreflight(
    copyReviewed(),
    copySnapshot(),
  );
  assert.deepEqual(result, {
    snapshotAccepted: true,
    releaseReady: false,
    schemaVersion: 1,
    evidence: "caller_supplied_sanitized_snapshot_only",
    accessControl: "exact_reviewed_match",
    cloudflareRateLimiting: "approximate_only",
    d1ExactQuota: "not_validated_required_hard_boundary",
  });
  assert.equal(Object.isFrozen(result), true);
  const output = JSON.stringify(result);
  assert.doesNotMatch(
    output,
    /jwt|email|name|device.?id|token|secret|11111111|moderation\.operator/iu,
  );
});

test("rejects app identity, domain, audience, IdP and session drift", () => {
  const mutations = [
    (value) => { value.accountId = "f".repeat(32); },
    (value) => { value.application.id = "44444444-4444-4444-8444-444444444444"; },
    (value) => { value.application.type = "saas"; },
    (value) => { value.application.domain = "other.operator.example.test"; },
    (value) => { value.application.origin = "https://other.operator.example.test"; },
    (value) => { value.application.audience = "b".repeat(64); },
    (value) => { value.application.accessIssuer =
      "https://other-team.cloudflareaccess.com"; },
    (value) => { value.application.webAuthnRpId = "other.operator.example.test"; },
    (value) => { value.application.runtimeVerifier.issuer =
      "https://other-team.cloudflareaccess.com"; },
    (value) => { value.application.runtimeVerifier.audience = "b".repeat(64); },
    (value) => { value.application.sessionDurationSeconds = 901; },
    (value) => { value.application.policies[0].sessionDurationSeconds = 901; },
    (value) => { value.application.policies[0].identityProviderIds = [
      "44444444-4444-4444-8444-444444444444",
    ]; },
    (value) => { value.application.policiesComplete = false; },
  ];
  for (const mutate of mutations) {
    const value = copySnapshot();
    mutate(value);
    fixedFailure(copyReviewed(), value);
  }
});

test("requires one Allow policy with security-key MFA and managed posture", () => {
  const mutations = [
    (value) => { value.application.policies[0].decision = "bypass"; },
    (value) => { value.application.policies[0].decision = "service_auth"; },
    (value) => { value.application.policies[0].authenticationMethods = ["otp"]; },
    (value) => { value.application.policies[0].mfaReauthentication = "initial"; },
    (value) => { value.application.policies[0].managedDevicePostureRequired = false; },
    (value) => { value.application.policies[0].everyoneIncluded = true; },
    (value) => { value.application.policies[0].serviceTokenIncluded = true; },
    (value) => { value.application.policies[0].warpAuthenticationIncluded = true; },
    (value) => { value.application.serviceAuthEnabled = true; },
    (value) => { value.application.warpAuthenticationEnabled = true; },
    (value) => { value.application.policies.push(structuredClone(
      value.application.policies[0],
    )); },
  ];
  for (const mutate of mutations) {
    const value = copySnapshot();
    mutate(value);
    fixedFailure(copyReviewed(), value);
  }
});

test("rejects approximate rate-limit specs that cannot prove isolation", () => {
  const mutations = [
    (value) => { value.rateLimits.operatorBindings[0].periodSeconds = 30; },
    (value) => { value.rateLimits.operatorBindings[0].limit = 0; },
    (value) => { value.rateLimits.operatorBindings[0].limit = 1.5; },
    (value) => { value.rateLimits.accountNamespaceInventoryComplete = false; },
    (value) => { value.rateLimits.operatorBindings[0].namespaceId = "0200001"; },
    (value) => { value.rateLimits.operatorBindings[1].namespaceId = "200001"; },
    (value) => {
      value.rateLimits.accountNamespaceBindings.find(
        (binding) => binding.limiterId === "OPERATOR_ACTION_RATE_LIMITER",
      ).namespaceId = "200001";
    },
    (value) => { value.rateLimits.accountNamespaceBindings =
      value.rateLimits.accountNamespaceBindings.filter(
        (binding) => binding.limiterId !== "CREATE_RATE_LIMITER",
      ); },
    (value) => { value.rateLimits.operatorBindings[0].limiterId =
      "UNREVIEWED_OPERATOR_LIMITER"; },
  ];
  for (const mutate of mutations) {
    const value = copySnapshot();
    mutate(value);
    fixedFailure(copyReviewed(), value);
  }

  const collidingReviewed = copyReviewed();
  collidingReviewed.publicLimiterIds.push("OPERATOR_AUTH_RATE_LIMITER");
  fixedFailure(collidingReviewed, copySnapshot());
});

test("accepts only reviewed exact 10/60 periods and positive integer limits", () => {
  for (const [periodSeconds, limit] of [[10, 1], [60, 2_147_483_647]]) {
    const value = copySnapshot();
    const policy = copyReviewed();
    value.rateLimits.operatorBindings[0].periodSeconds = periodSeconds;
    value.rateLimits.operatorBindings[0].limit = limit;
    policy.operatorRateLimits[0].periodSeconds = periodSeconds;
    policy.operatorRateLimits[0].limit = limit;
    assert.doesNotThrow(() => validateModerationOperatorControlPlanePreflight(
      policy,
      value,
    ));
  }
});

test("rejects extra fields, raw identity material and non-plain input", () => {
  for (const [path, rawValue] of [
    ["jwt", "header.payload.signature"],
    ["email", "operator@example.invalid"],
    ["name", "Operator Person"],
    ["deviceId", "raw-device-id"],
    ["token", "service-token"],
    ["secret", "not-for-a-preflight"],
  ]) {
    const value = copySnapshot();
    value.application[path] = rawValue;
    fixedFailure(copyReviewed(), value);
  }

  const withDate = copySnapshot();
  withDate.application.observedAt = new Date();
  fixedFailure(copyReviewed(), withDate);

  const withFunction = copySnapshot();
  withFunction.rateLimits.loader = () => snapshot;
  fixedFailure(copyReviewed(), withFunction);

  const withGetter = copySnapshot();
  let getterCalled = false;
  Object.defineProperty(withGetter.application, "email", {
    enumerable: true,
    get() {
      getterCalled = true;
      return "operator@example.invalid";
    },
  });
  fixedFailure(copyReviewed(), withGetter);
  assert.equal(getterCalled, false);

  const trapped = new Proxy(copyReviewed(), {
    getPrototypeOf() {
      throw new Error("raw-secret-leak");
    },
  });
  fixedFailure(trapped, copySnapshot());
});

test("module remains pure and contains no live control-plane capability", async () => {
  const source = await readFile(join(
    import.meta.dirname,
    "..",
    "scripts",
    "moderation-operator-control-plane-preflight-lib.mjs",
  ), "utf8");
  assert.doesNotMatch(
    source,
    /\bfetch\s*\(|WebSocket|puppeteer|playwright|wrangler|process\.env|\.dev\.vars/iu,
  );
});
