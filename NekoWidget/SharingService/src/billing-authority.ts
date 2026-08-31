import {
  fetchAppleSubscriptionStatusViaService,
  verifyAppleNotificationViaService,
  type VerifiedAppleNotification,
  type VerifiedSubscriptionStatus,
  type VerifiedSubscriptionStatusItem,
} from "./billing-apple-client";
import {
  BILLING_PROTOCOL_VERSION,
  storeVerifiedTransaction,
} from "./billing";
import { requestBillingReconciliation } from "./billing-reconciliation-queue";
import { randomBase64url, sha256Base64url } from "./encoding";
import { ApiError } from "./errors";
import type { Env } from "./env";
import { parseJsonBody, readBody } from "./http";
import { exactKeys, stringField } from "./validation";

const maximumSignedNotificationBytes = 60 * 1024;
const reconciliationLimit = 8;
const leaseSeconds = 120;
const periodicReconciliationSeconds = 24 * 60 * 60;

interface BillingAuthorityGateRow {
  apple_notification_ingestion_enabled: 0 | 1;
  subscription_reconciliation_enabled: 0 | 1;
}

interface NotificationReplayRow {
  payload_hash: string;
  relevance: "ignored" | "unmatched" | "linked";
  original_transaction_id: string | null;
}

interface ReconciliationJobRow {
  original_transaction_id: string;
  request_generation: number;
  attempts: number;
}

interface LineageRow {
  billing_account_id: string;
  environment: "Sandbox" | "Production";
  subscription_group_id: string;
}

export type AppleNotificationVerifier = (
  signedPayload: string,
  env: Env,
) => Promise<VerifiedAppleNotification>;

export type AppleSubscriptionStatusFetcher = (
  originalTransactionId: string,
  env: Env,
) => Promise<VerifiedSubscriptionStatus>;

async function loadGate(env: Env): Promise<BillingAuthorityGateRow | null> {
  try {
    return await env.DB.prepare(
      `SELECT apple_notification_ingestion_enabled,
              subscription_reconciliation_enabled
         FROM billing_runtime_gate WHERE singleton = 1`,
    ).first<BillingAuthorityGateRow>();
  } catch {
    return null;
  }
}

async function notificationReplay(
  env: Env,
  notificationUUID: string,
): Promise<NotificationReplayRow | null> {
  return env.DB.prepare(
    `SELECT payload_hash, relevance, original_transaction_id
       FROM billing_apple_notification_events WHERE notification_uuid = ?`,
  ).bind(notificationUUID).first<NotificationReplayRow>();
}

async function resumeNotificationReplay(
  env: Env,
  existing: NotificationReplayRow,
  payloadHash: string,
): Promise<Response> {
  if (existing.payload_hash !== payloadHash) {
    throw new ApiError(
      409,
      "apple_notification_conflict",
      "The App Store notification conflicts with recorded data.",
    );
  }
  if (existing.relevance === "linked" && existing.original_transaction_id !== null) {
    await requestBillingReconciliation(env, existing.original_transaction_id);
  }
  return new Response(null, { status: 204 });
}

async function storeNotification(
  env: Env,
  value: VerifiedAppleNotification,
  payloadHash: string,
  relevance: "ignored" | "unmatched" | "linked",
): Promise<void> {
  const transaction = value.transaction;
  await env.DB.prepare(
    `INSERT INTO billing_apple_notification_events(
       notification_uuid, payload_hash, notification_type, subtype,
       signed_date_ms, environment, apple_status, relevance,
       transaction_id, original_transaction_id, billing_account_id
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    value.notificationUUID,
    payloadHash,
    value.notificationType,
    value.subtype,
    value.signedDateMs,
    value.environment,
    value.status,
    relevance,
    transaction?.transactionId ?? null,
    transaction?.originalTransactionId ?? null,
    transaction?.billingAccountId ?? null,
  ).run();
}

export async function ingestAppleBillingNotification(
  request: Request,
  env: Env,
  verify: AppleNotificationVerifier = verifyAppleNotificationViaService,
): Promise<Response> {
  if ((await loadGate(env))?.apple_notification_ingestion_enabled !== 1) {
    throw new ApiError(503, "billing_runtime_disabled", "Billing is temporarily unavailable.");
  }
  const body = await readBody(request, maximumSignedNotificationBytes + 1_024);
  const raw = parseJsonBody(request, body);
  // This is the public App Store endpoint. Apple sends exactly this one field;
  // protocolVersion is added only on our separately authenticated internal hop.
  exactKeys(raw, ["signedPayload"]);
  const signedPayload = stringField(raw, "signedPayload");
  if (
    signedPayload.length > maximumSignedNotificationBytes
    || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u.test(signedPayload)
  ) throw new ApiError(400, "invalid_apple_notification", "The App Store notification is invalid.");

  const payloadHash = await sha256Base64url(new TextEncoder().encode(signedPayload));
  const value = await verify(signedPayload, env);
  const existing = await notificationReplay(env, value.notificationUUID);
  if (existing !== null) return resumeNotificationReplay(env, existing, payloadHash);

  let relevance: "ignored" | "unmatched" | "linked" = "ignored";
  if (value.relevant && value.transaction !== null) {
    try {
      await storeVerifiedTransaction(env, value.transaction, { kind: "apple_notification" });
      relevance = "linked";
    } catch (error) {
      if (!(error instanceof ApiError)
        || (error.code !== "billing_account_not_registered"
          && error.code !== "billing_lineage_conflict")) throw error;
      relevance = "unmatched";
    }
  }
  try {
    await storeNotification(env, value, payloadHash, relevance);
  } catch {
    const raced = await notificationReplay(env, value.notificationUUID);
    if (raced === null) {
      throw new ApiError(
        503,
        "apple_notification_unavailable",
        "Billing is temporarily unavailable.",
      );
    }
    return resumeNotificationReplay(env, raced, payloadHash);
  }
  if (relevance === "linked" && value.transaction !== null) {
    await requestBillingReconciliation(env, value.transaction.originalTransactionId);
  }
  return new Response(null, { status: 204 });
}

function observationFingerprint(
  item: VerifiedSubscriptionStatusItem,
  fetchedAtMs: number,
): Promise<string> {
  const transaction = item.transaction;
  const renewal = item.renewal;
  return sha256Base64url(new TextEncoder().encode(JSON.stringify([
    BILLING_PROTOCOL_VERSION,
    "subscription_status_api",
    fetchedAtMs,
    item.status,
    item.originalTransactionId,
    transaction.transactionId,
    transaction.billingAccountId,
    transaction.productId,
    transaction.environment,
    transaction.expiresDateMs,
    transaction.revocationDateMs,
    transaction.revocationReason,
    transaction.isUpgraded,
    renewal.autoRenewProductId,
    renewal.autoRenewStatus,
    renewal.isInBillingRetryPeriod,
    renewal.gracePeriodExpiresDateMs,
    renewal.renewalDateMs,
    transaction.signedDateMs,
    renewal.signedDateMs,
  ])));
}

async function recordAuthorityObservations(
  env: Env,
  status: VerifiedSubscriptionStatus,
  lineage: LineageRow,
  originalTransactionId: string,
): Promise<boolean> {
  const matching = status.items.filter((item) =>
    item.originalTransactionId === originalTransactionId
    && item.transaction.billingAccountId === lineage.billing_account_id
    && item.transaction.environment === lineage.environment
    && item.transaction.subscriptionGroupId === lineage.subscription_group_id,
  );
  if (matching.length === 0) {
    throw new ApiError(
      409,
      "billing_authority_lineage_mismatch",
      "The App Store subscription status is invalid.",
    );
  }
  const statements: D1PreparedStatement[] = [];
  for (const item of matching) {
    const transaction = item.transaction;
    const renewal = item.renewal;
    statements.push(env.DB.prepare(
      `INSERT OR IGNORE INTO billing_subscription_authority_observations(
         observation_fingerprint, original_transaction_id, billing_account_id,
         environment, subscription_group_id, apple_status, transaction_id,
         product_id, expires_date_ms, revocation_date_ms, revocation_reason,
         is_upgraded, auto_renew_product_id, auto_renew_status,
         is_in_billing_retry_period, grace_period_expires_date_ms,
         renewal_date_ms, transaction_signed_date_ms, renewal_signed_date_ms,
         fetched_at_ms
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      await observationFingerprint(item, status.fetchedAtMs),
      originalTransactionId,
      lineage.billing_account_id,
      lineage.environment,
      lineage.subscription_group_id,
      item.status,
      transaction.transactionId,
      transaction.productId,
      transaction.expiresDateMs,
      transaction.revocationDateMs,
      transaction.revocationReason,
      transaction.isUpgraded ? 1 : 0,
      renewal.autoRenewProductId,
      renewal.autoRenewStatus,
      renewal.isInBillingRetryPeriod === null
        ? null : renewal.isInBillingRetryPeriod ? 1 : 0,
      renewal.gracePeriodExpiresDateMs,
      renewal.renewalDateMs,
      transaction.signedDateMs,
      renewal.signedDateMs,
      status.fetchedAtMs,
    ));
  }
  await env.DB.batch(statements);
  return matching.some((item) => item.status === 1 || item.status === 3 || item.status === 4);
}

async function releaseSuccessfulLease(
  env: Env,
  job: ReconciliationJobRow,
  leaseToken: string,
  now: number,
  keepPeriodic: boolean,
): Promise<void> {
  const completed = keepPeriodic
    ? await env.DB.prepare(
      `UPDATE billing_reconciliation_jobs
          SET attempts = 0, not_before = ?, lease_token = NULL,
              lease_expires_at = NULL, last_error_code = NULL,
              updated_at = unixepoch()
        WHERE original_transaction_id = ? AND lease_token = ?
          AND request_generation = ?`,
    ).bind(
      now + periodicReconciliationSeconds,
      job.original_transaction_id,
      leaseToken,
      job.request_generation,
    ).run()
    : await env.DB.prepare(
      `DELETE FROM billing_reconciliation_jobs
        WHERE original_transaction_id = ? AND lease_token = ?
          AND request_generation = ?`,
    ).bind(job.original_transaction_id, leaseToken, job.request_generation).run();
  if (completed.meta.changes === 0) {
    await env.DB.prepare(
      `UPDATE billing_reconciliation_jobs
          SET attempts = 0, not_before = ?, lease_token = NULL,
              lease_expires_at = NULL, last_error_code = NULL,
              updated_at = unixepoch()
        WHERE original_transaction_id = ? AND lease_token = ?`,
    ).bind(now, job.original_transaction_id, leaseToken).run();
  }
}

async function releaseFailedLease(
  env: Env,
  job: ReconciliationJobRow,
  leaseToken: string,
  now: number,
  errorCode: string,
): Promise<void> {
  const attempts = Math.min(20, job.attempts + 1);
  const delay = attempts >= 20
    ? 86_400 : Math.min(3_600, 30 * (2 ** Math.min(attempts - 1, 7)));
  const updated = await env.DB.prepare(
    `UPDATE billing_reconciliation_jobs
        SET attempts = ?, not_before = ?, lease_token = NULL,
            lease_expires_at = NULL, last_error_code = ?,
            updated_at = unixepoch()
      WHERE original_transaction_id = ? AND lease_token = ?
        AND request_generation = ?`,
  ).bind(
    attempts,
    now + delay,
    errorCode,
    job.original_transaction_id,
    leaseToken,
    job.request_generation,
  ).run();
  if (updated.meta.changes === 0) {
    // A newer notification arrived while this request was in flight. Preserve
    // that request and make it immediately eligible instead of applying the
    // stale request's retry delay.
    await env.DB.prepare(
      `UPDATE billing_reconciliation_jobs
          SET attempts = 0, not_before = ?, lease_token = NULL,
              lease_expires_at = NULL, last_error_code = NULL,
              updated_at = unixepoch()
        WHERE original_transaction_id = ? AND lease_token = ?`,
    ).bind(now, job.original_transaction_id, leaseToken).run();
  }
}

export async function runBillingSubscriptionReconciliation(
  env: Env,
  fetchStatus: AppleSubscriptionStatusFetcher = fetchAppleSubscriptionStatusViaService,
  now = Math.floor(Date.now() / 1_000),
): Promise<void> {
  const gate = await loadGate(env);
  if (gate?.subscription_reconciliation_enabled !== 1) return;
  const jobs = await env.DB.prepare(
    `SELECT original_transaction_id, request_generation, attempts
       FROM billing_reconciliation_jobs
      WHERE not_before <= ?
        AND (lease_expires_at IS NULL OR lease_expires_at <= ?)
      ORDER BY not_before ASC, requested_at ASC, original_transaction_id ASC
      LIMIT ?`,
  ).bind(now, now, reconciliationLimit).all<ReconciliationJobRow>();

  for (const job of jobs.results) {
    const leaseToken = randomBase64url(16);
    const claimed = await env.DB.prepare(
      `UPDATE billing_reconciliation_jobs
          SET lease_token = ?, lease_expires_at = ?, updated_at = unixepoch()
        WHERE original_transaction_id = ? AND request_generation = ?
          AND not_before <= ?
          AND (lease_expires_at IS NULL OR lease_expires_at <= ?)`,
    ).bind(
      leaseToken,
      now + leaseSeconds,
      job.original_transaction_id,
      job.request_generation,
      now,
      now,
    ).run();
    if (claimed.meta.changes !== 1) continue;

    try {
      const lineage = await env.DB.prepare(
        `SELECT billing_account_id, environment, subscription_group_id
           FROM billing_transaction_lineages WHERE original_transaction_id = ?`,
      ).bind(job.original_transaction_id).first<LineageRow>();
      if (lineage === null) {
        throw new ApiError(409, "billing_lineage_missing", "Billing is temporarily unavailable.");
      }
      const status = await fetchStatus(job.original_transaction_id, env);
      const keepPeriodic = await recordAuthorityObservations(
        env,
        status,
        lineage,
        job.original_transaction_id,
      );
      await releaseSuccessfulLease(env, job, leaseToken, now, keepPeriodic);
    } catch (error) {
      const code = error instanceof ApiError
        ? error.code.replace(/[^a-z0-9_]/gu, "_").slice(0, 64)
        : "billing_reconciliation_unavailable";
      await releaseFailedLease(env, job, leaseToken, now, code);
    }
  }
}
