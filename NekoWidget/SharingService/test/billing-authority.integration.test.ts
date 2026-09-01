import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import {
  ingestAppleBillingNotification,
  runBillingSubscriptionReconciliation,
} from "../src/billing-authority";
import type {
  VerifiedAppleNotification,
  VerifiedSubscriptionStatus,
} from "../src/billing-apple-client";
import { requestBillingReconciliation } from "../src/billing-reconciliation-queue";
import { effectiveBillingEntitlement } from "../src/billing-entitlement";
import type { VerifiedBillingTransaction } from "../src/billing-verifier-client";
import { ApiError } from "../src/errors";
import type { Env } from "../src/env";
import { route } from "../src/index";

const testEnv = env as unknown as Env;
const nowMs = Date.now();

interface GateRow {
  generation: number;
  apple_notification_ingestion_enabled: number;
  subscription_reconciliation_enabled: number;
}

async function setAuthorityGates(
  notifications: boolean,
  reconciliation: boolean,
): Promise<void> {
  const row = await testEnv.DB.prepare(
    `SELECT generation, apple_notification_ingestion_enabled,
            subscription_reconciliation_enabled
       FROM billing_runtime_gate WHERE singleton = 1`,
  ).first<GateRow>();
  if (row === null) throw new Error("missing billing runtime gate");
  const notificationValue = notifications ? 1 : 0;
  const reconciliationValue = reconciliation ? 1 : 0;
  if (
    row.apple_notification_ingestion_enabled === notificationValue
    && row.subscription_reconciliation_enabled === reconciliationValue
  ) return;
  const result = await testEnv.DB.prepare(
    `UPDATE billing_runtime_gate
        SET generation = generation + 1,
            apple_notification_ingestion_enabled = ?,
            subscription_reconciliation_enabled = ?,
            updated_at = unixepoch()
      WHERE singleton = 1 AND generation = ?`,
  ).bind(notificationValue, reconciliationValue, row.generation).run();
  if (result.meta.changes !== 1) throw new Error("billing authority gate CAS failed");
}

async function registerAccount(billingAccountId: string): Promise<void> {
  await testEnv.DB.prepare(
    "INSERT OR IGNORE INTO billing_accounts(id) VALUES (?)",
  ).bind(billingAccountId).run();
}

function transaction(
  billingAccountId: string,
  overrides: Partial<VerifiedBillingTransaction> = {},
): VerifiedBillingTransaction {
  return {
    transactionId: "210000000000001",
    originalTransactionId: "210000000000001",
    billingAccountId,
    productId: "jp.nekowidget.plus.monthly",
    subscriptionGroupId: "20999999",
    bundleId: "jp.nekowidget.app",
    environment: "Sandbox",
    ownershipType: "PURCHASED",
    transactionReason: "PURCHASE",
    purchaseDateMs: nowMs - 1_000,
    originalPurchaseDateMs: nowMs - 1_000,
    expiresDateMs: nowMs + 2_592_000_000,
    signedDateMs: nowMs,
    revocationDateMs: null,
    revocationReason: null,
    isUpgraded: false,
    ...overrides,
  };
}

function notification(
  notificationUUID: string,
  value: VerifiedBillingTransaction | null,
  overrides: Partial<VerifiedAppleNotification> = {},
): VerifiedAppleNotification {
  return {
    notificationUUID,
    notificationType: value === null ? "TEST" : "DID_RENEW",
    subtype: null,
    signedDateMs: nowMs,
    environment: "Sandbox",
    bundleId: "jp.nekowidget.app",
    status: value === null ? null : 1,
    relevant: value !== null,
    transaction: value,
    renewal: null,
    ...overrides,
  };
}

function notificationRequest(signedPayload: string): Request {
  return new Request("https://sharing.invalid/v1/billing/apple-notifications", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ signedPayload }),
  });
}

function status(value: VerifiedBillingTransaction, appleStatus = 1): VerifiedSubscriptionStatus {
  return {
    requestedTransactionId: value.originalTransactionId,
    environment: value.environment,
    bundleId: value.bundleId,
    fetchedAtMs: nowMs + 10_000,
    items: [{
      status: appleStatus as 1 | 2 | 3 | 4 | 5,
      originalTransactionId: value.originalTransactionId,
      transaction: value,
      renewal: {
        originalTransactionId: value.originalTransactionId,
        billingAccountId: value.billingAccountId,
        productId: value.productId,
        autoRenewProductId: value.productId,
        autoRenewStatus: appleStatus === 5 ? 0 : 1,
        isInBillingRetryPeriod: appleStatus === 3 || appleStatus === 4,
        gracePeriodExpiresDateMs: appleStatus === 4 ? nowMs + 86_400_000 : null,
        renewalDateMs: value.expiresDateMs,
        signedDateMs: value.signedDateMs,
        environment: value.environment,
      },
    }],
  };
}

describe.sequential("App Store billing authority", () => {
  it("keeps upper and lower notification gates closed before parsing or verification", async () => {
    const inaccessible = new Proxy({} as Env, {
      get(_target, property) {
        if (property === "BILLING_APPLE_NOTIFICATION_RUNTIME_ENABLED") return "NO";
        throw new Error(`unexpected environment read: ${String(property)}`);
      },
    });
    await expect(route(notificationRequest("not-json"), inaccessible)).rejects.toMatchObject({
      status: 503,
      code: "billing_runtime_disabled",
    });

    await setAuthorityGates(false, false);
    let calls = 0;
    await expect(ingestAppleBillingNotification(
      notificationRequest("header.lowergate.signature"),
      testEnv,
      async () => {
        calls += 1;
        return notification("1ab3d5f7-1234-4abc-8def-1234567890ab", null);
      },
    )).rejects.toMatchObject({ status: 503, code: "billing_runtime_disabled" });
    expect(calls).toBe(0);
  });

  it("rate limits the public Apple endpoint before parsing or verifier work", async () => {
    await setAuthorityGates(true, false);
    const keys: string[] = [];
    const limitedEnv = new Proxy(testEnv, {
      get(target, property, receiver) {
        if (property === "ENVIRONMENT") return "staging";
        if (property === "BILLING_APPLE_NOTIFICATION_RATE_LIMITER") {
          return {
            async limit({ key }: { key: string }) {
              keys.push(key);
              return { success: false };
            },
          };
        }
        if (property === "BILLING_RATE_LIMITER") {
          throw new Error("the generic billing limiter must not serve Apple notifications");
        }
        if (property === "DB") {
          throw new Error("the lower gate must not be read before the edge limiter");
        }
        return Reflect.get(target, property, receiver);
      },
    }) as Env;
    let verifierCalls = 0;
    await expect(ingestAppleBillingNotification(
      notificationRequest("header.rate_limited.signature"), limitedEnv, async () => {
      verifierCalls += 1;
      return notification("1ab3d5f7-1234-4abc-8def-1234567890ac", null);
      },
    )).rejects.toMatchObject({ status: 429, code: "rate_limited" });
    expect(keys).toEqual(["billing-apple-notification"]);
    expect(verifierCalls).toBe(0);
  });

  it("fails closed before verifier work when the Apple endpoint limiter is missing", async () => {
    await setAuthorityGates(true, false);
    const unavailableEnv = new Proxy(testEnv, {
      get(target, property, receiver) {
        if (property === "ENVIRONMENT") return "staging";
        if (property === "BILLING_APPLE_NOTIFICATION_RATE_LIMITER") return undefined;
        return Reflect.get(target, property, receiver);
      },
    }) as Env;
    let verifierCalls = 0;
    await expect(ingestAppleBillingNotification(
      notificationRequest("header.missing_limiter.signature"),
      unavailableEnv,
      async () => {
        verifierCalls += 1;
        return notification("1ab3d5f7-1234-4abc-8def-1234567890ad", null);
      },
    )).rejects.toMatchObject({ status: 503, code: "rate_limiter_unavailable" });
    expect(verifierCalls).toBe(0);
  });

  it("deduplicates Apple retries, preserves order-independent facts, and never stores raw JWS", async () => {
    await setAuthorityGates(true, false);
    const billingAccountId = "5f30c0de-0000-4000-8000-000000000101";
    await registerAccount(billingAccountId);
    const latest = transaction(billingAccountId);
    const firstUUID = "1ab3d5f7-1234-4abc-8def-123456789101";
    const rawMarker = "header.billing_authority_raw_marker.signature";
    const verify = async () => notification(firstUUID, latest);

    expect((await ingestAppleBillingNotification(
      notificationRequest(rawMarker), testEnv, verify,
    )).status).toBe(204);
    expect((await ingestAppleBillingNotification(
      notificationRequest(rawMarker), testEnv, verify,
    )).status).toBe(204);
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_apple_notification_events WHERE notification_uuid = ?",
    ).bind(firstUUID).first()).toEqual({ count: 1 });
    expect(await testEnv.DB.prepare(
      "SELECT source FROM billing_transaction_events WHERE transaction_id = ?",
    ).bind(latest.transactionId).first()).toEqual({ source: "apple_notification" });
    expect(await testEnv.DB.prepare(
      "SELECT request_generation FROM billing_reconciliation_jobs WHERE original_transaction_id = ?",
    ).bind(latest.originalTransactionId).first()).toEqual({ request_generation: 2 });

    await expect(ingestAppleBillingNotification(
      notificationRequest("header.conflicting_marker.signature"), testEnv, verify,
    )).rejects.toMatchObject({ status: 409, code: "apple_notification_conflict" });

    const older = transaction(billingAccountId, {
      transactionId: "210000000000002",
      signedDateMs: nowMs - 100_000,
      purchaseDateMs: nowMs - 101_000,
    });
    expect((await ingestAppleBillingNotification(
      notificationRequest("header.older_raw_marker.signature"),
      testEnv,
      async () => notification(
        "1ab3d5f7-1234-4abc-8def-123456789102",
        older,
        { signedDateMs: nowMs - 100_000, status: 2 },
      ),
    )).status).toBe(204);
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM billing_transaction_events
        WHERE original_transaction_id = ?`,
    ).bind(latest.originalTransactionId).first()).toEqual({ count: 2 });

    for (const table of [
      "billing_apple_notification_events",
      "billing_transaction_events",
      "billing_reconciliation_jobs",
    ]) {
      const rows = await testEnv.DB.prepare(`SELECT * FROM ${table}`).all();
      expect(JSON.stringify(rows.results)).not.toContain("raw_marker");
    }
    const columns = await testEnv.DB.prepare(
      "PRAGMA table_info(billing_apple_notification_events)",
    ).all<{ name: string }>();
    expect(columns.results.map((column) => column.name).join(" "))
      .not.toMatch(/raw_jws|signed_payload|signed_transaction|signed_renewal/iu);
    await expect(testEnv.DB.prepare(
      "DELETE FROM billing_apple_notification_events WHERE notification_uuid = ?",
    ).bind(firstUUID).run()).rejects.toThrow();
  });

  it("acknowledges verified but unregistered accounts without creating a lineage or queue", async () => {
    await setAuthorityGates(true, false);
    const unregistered = transaction("5f30c0de-0000-4000-8000-000000000102", {
      transactionId: "210000000000010",
      originalTransactionId: "210000000000010",
    });
    const response = await ingestAppleBillingNotification(
      notificationRequest("header.unmatched_marker.signature"),
      testEnv,
      async () => notification(
        "1ab3d5f7-1234-4abc-8def-123456789110",
        unregistered,
      ),
    );
    expect(response.status).toBe(204);
    expect(await testEnv.DB.prepare(
      "SELECT relevance FROM billing_apple_notification_events WHERE notification_uuid = ?",
    ).bind("1ab3d5f7-1234-4abc-8def-123456789110").first())
      .toEqual({ relevance: "unmatched" });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_reconciliation_jobs WHERE original_transaction_id = ?",
    ).bind(unregistered.originalTransactionId).first()).toEqual({ count: 0 });
  });

  it("records Subscription Status as authority even when notification status differs", async () => {
    await setAuthorityGates(true, true);
    const billingAccountId = "5f30c0de-0000-4000-8000-000000000103";
    await registerAccount(billingAccountId);
    const value = transaction(billingAccountId, {
      transactionId: "210000000000020",
      originalTransactionId: "210000000000020",
    });
    await ingestAppleBillingNotification(
      notificationRequest("header.authority_marker.signature"),
      testEnv,
      async () => notification(
        "1ab3d5f7-1234-4abc-8def-123456789120",
        value,
        { status: 1 },
      ),
    );
    const runAt = Math.floor(Date.now() / 1_000) + 10;
    await runBillingSubscriptionReconciliation(
      testEnv,
      async () => status(value, 4),
      runAt,
    );
    expect(await testEnv.DB.prepare(
      `SELECT apple_status, is_in_billing_retry_period, ownership_type
         FROM billing_subscription_authority_observations
        WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).first()).toEqual({
      apple_status: 4,
      is_in_billing_retry_period: 1,
      ownership_type: "PURCHASED",
    });
    expect(await testEnv.DB.prepare(
      `SELECT attempts, not_before FROM billing_reconciliation_jobs
        WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).first()).toEqual({
      attempts: 0,
      not_before: runAt + 86_400,
    });
    await expect(testEnv.DB.prepare(
      `UPDATE billing_subscription_authority_observations
          SET apple_status = 1 WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).run()).rejects.toThrow();
  });

  it("does not let an older failed lease delay a newer reconciliation request", async () => {
    await setAuthorityGates(true, true);
    const billingAccountId = "5f30c0de-0000-4000-8000-000000000104";
    await registerAccount(billingAccountId);
    const value = transaction(billingAccountId, {
      transactionId: "210000000000030",
      originalTransactionId: "210000000000030",
    });
    await ingestAppleBillingNotification(
      notificationRequest("header.generation_marker.signature"),
      testEnv,
      async () => notification(
        "1ab3d5f7-1234-4abc-8def-123456789130",
        value,
      ),
    );
    const runAt = Math.floor(Date.now() / 1_000) + 10;
    await runBillingSubscriptionReconciliation(testEnv, async () => {
      await requestBillingReconciliation(testEnv, value.originalTransactionId, runAt + 1);
      throw new ApiError(503, "simulated_status_outage", "temporary");
    }, runAt);
    expect(await testEnv.DB.prepare(
      `SELECT request_generation, attempts, not_before, lease_token
         FROM billing_reconciliation_jobs WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).first()).toEqual({
      request_generation: 2,
      attempts: 0,
      not_before: runAt,
      lease_token: null,
    });

    await runBillingSubscriptionReconciliation(
      testEnv,
      async () => status(value, 5),
      runAt,
    );
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_reconciliation_jobs WHERE original_transaction_id = ?",
    ).bind(value.originalTransactionId).first()).toEqual({ count: 0 });
  });

  it("does not materialize a late successful fetch after its generation is superseded", async () => {
    await setAuthorityGates(true, true);
    const billingAccountId = "5f30c0de-0000-4000-8000-000000000106";
    await registerAccount(billingAccountId);
    const value = transaction(billingAccountId, {
      transactionId: "210000000000050",
      originalTransactionId: "210000000000050",
    });
    await ingestAppleBillingNotification(
      notificationRequest("header.stale_success_marker.signature"),
      testEnv,
      async () => notification(
        "1ab3d5f7-1234-4abc-8def-123456789150",
        value,
      ),
    );
    const runAt = Math.floor(Date.now() / 1_000) + 20;
    await runBillingSubscriptionReconciliation(testEnv, async () => {
      await requestBillingReconciliation(testEnv, value.originalTransactionId, runAt + 1);
      return status(value, 1);
    }, runAt);
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM billing_effective_entitlement_current
        WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).first()).toEqual({ count: 0 });
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM billing_effective_entitlement_decisions
        WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).first()).toEqual({ count: 0 });

    await runBillingSubscriptionReconciliation(
      testEnv,
      async () => status(value, 5),
      runAt,
    );
    expect(await testEnv.DB.prepare(
      `SELECT materialized_status, materialized_grants_plus, request_generation
         FROM billing_effective_entitlement_current
        WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).first()).toEqual({
      materialized_status: "revoked",
      materialized_grants_plus: 0,
      request_generation: 2,
    });
  });

  it("does not materialize or complete a response after its lease expires", async () => {
    await setAuthorityGates(true, true);
    const billingAccountId = "5f30c0de-0000-4000-8000-000000000108";
    await registerAccount(billingAccountId);
    const value = transaction(billingAccountId, {
      transactionId: "210000000000070",
      originalTransactionId: "210000000000070",
    });
    await ingestAppleBillingNotification(
      notificationRequest("header.expired_lease_marker.signature"),
      testEnv,
      async () => notification(
        "1ab3d5f7-1234-4abc-8def-123456789170",
        value,
      ),
    );
    const runAt = Math.floor(Date.now() / 1_000) + 40;
    const completedAt = runAt + 121;
    await runBillingSubscriptionReconciliation(
      testEnv,
      async () => status(value, 1),
      runAt,
      completedAt,
    );
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM billing_effective_entitlement_decisions
        WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).first()).toEqual({ count: 0 });
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count FROM billing_effective_entitlement_current
        WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).first()).toEqual({ count: 0 });
    expect(await testEnv.DB.prepare(
      `SELECT request_generation, attempts, not_before, lease_token, lease_expires_at
         FROM billing_reconciliation_jobs WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).first()).toEqual({
      request_generation: 1,
      attempts: 0,
      not_before: completedAt,
      lease_token: null,
      lease_expires_at: null,
    });
  });

  it("grants an account when any independently reconciled purchased lineage is active", async () => {
    await setAuthorityGates(true, true);
    const billingAccountId = "5f30c0de-0000-4000-8000-000000000107";
    await registerAccount(billingAccountId);
    const expired = transaction(billingAccountId, {
      transactionId: "210000000000060",
      originalTransactionId: "210000000000060",
      expiresDateMs: nowMs - 1_000,
    });
    const active = transaction(billingAccountId, {
      transactionId: "210000000000061",
      originalTransactionId: "210000000000061",
      productId: "jp.nekowidget.plus.annual",
    });
    await ingestAppleBillingNotification(
      notificationRequest("header.multiple_lineage_expired.signature"),
      testEnv,
      async () => notification(
        "1ab3d5f7-1234-4abc-8def-123456789160",
        expired,
      ),
    );
    await ingestAppleBillingNotification(
      notificationRequest("header.multiple_lineage_active.signature"),
      testEnv,
      async () => notification(
        "1ab3d5f7-1234-4abc-8def-123456789161",
        active,
      ),
    );
    const runAt = Math.floor(Date.now() / 1_000) + 30;
    await runBillingSubscriptionReconciliation(testEnv, async (originalTransactionId) => {
      return originalTransactionId === expired.originalTransactionId
        ? status(expired, 2)
        : status(active, 1);
    }, runAt);
    expect(await effectiveBillingEntitlement(
      testEnv,
      billingAccountId,
      runAt * 1_000,
    )).toMatchObject({
      status: "active",
      productId: active.productId,
      grantsPlus: true,
      provisional: false,
    });
  });

  it("leases one reconciliation at a time and backs off only an ordinary failure", async () => {
    await setAuthorityGates(true, true);
    const billingAccountId = "5f30c0de-0000-4000-8000-000000000105";
    await registerAccount(billingAccountId);
    const value = transaction(billingAccountId, {
      transactionId: "210000000000040",
      originalTransactionId: "210000000000040",
    });
    await ingestAppleBillingNotification(
      notificationRequest("header.lease_marker.signature"),
      testEnv,
      async () => notification(
        "1ab3d5f7-1234-4abc-8def-123456789140",
        value,
      ),
    );
    const runAt = Math.floor(Date.now() / 1_000) + 10;
    let started: (() => void) | undefined;
    let release: (() => void) | undefined;
    const startedPromise = new Promise<void>((resolve) => { started = resolve; });
    const releasePromise = new Promise<void>((resolve) => { release = resolve; });
    let fetches = 0;
    const first = runBillingSubscriptionReconciliation(testEnv, async () => {
      fetches += 1;
      started?.();
      await releasePromise;
      return status(value, 1);
    }, runAt);
    await startedPromise;
    await runBillingSubscriptionReconciliation(testEnv, async () => {
      fetches += 1;
      return status(value, 1);
    }, runAt);
    expect(fetches).toBe(1);
    release?.();
    await first;

    await requestBillingReconciliation(testEnv, value.originalTransactionId, runAt + 1);
    await runBillingSubscriptionReconciliation(testEnv, async () => {
      throw new ApiError(503, "ordinary_status_outage", "temporary");
    }, runAt + 1);
    expect(await testEnv.DB.prepare(
      `SELECT attempts, not_before, lease_token, last_error_code
         FROM billing_reconciliation_jobs WHERE original_transaction_id = ?`,
    ).bind(value.originalTransactionId).first()).toEqual({
      attempts: 1,
      not_before: runAt + 31,
      lease_token: null,
      last_error_code: "ordinary_status_outage",
    });
  });
});
