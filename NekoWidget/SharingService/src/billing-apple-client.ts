import {
  callBillingVerifierService,
  loadVerifierConfig,
  normalizeVerifiedBillingTransaction,
  type VerifiedBillingTransaction,
  type VerifierConfig,
} from "./billing-verifier-client";
import {
  BILLING_NOTIFICATION_VERIFIER_PATH,
  BILLING_SUBSCRIPTION_STATUS_PATH,
  BILLING_VERIFIER_PROTOCOL_VERSION,
} from "./billing-verifier-protocol";
import { ApiError } from "./errors";
import type { Env } from "./env";

export interface VerifiedBillingRenewal {
  originalTransactionId: string;
  billingAccountId: string;
  productId: string;
  autoRenewProductId: string | null;
  autoRenewStatus: 0 | 1 | null;
  isInBillingRetryPeriod: boolean | null;
  gracePeriodExpiresDateMs: number | null;
  renewalDateMs: number | null;
  signedDateMs: number;
  environment: "Sandbox" | "Production";
}

export interface VerifiedAppleNotification {
  notificationUUID: string;
  notificationType: string;
  subtype: string | null;
  signedDateMs: number;
  environment: "Sandbox" | "Production";
  bundleId: string;
  status: 1 | 2 | 3 | 4 | 5 | null;
  relevant: boolean;
  transaction: VerifiedBillingTransaction | null;
  renewal: VerifiedBillingRenewal | null;
}

export interface VerifiedSubscriptionStatusItem {
  status: 1 | 2 | 3 | 4 | 5;
  originalTransactionId: string;
  transaction: VerifiedBillingTransaction;
  renewal: VerifiedBillingRenewal;
}

export interface VerifiedSubscriptionStatus {
  requestedTransactionId: string;
  environment: "Sandbox" | "Production";
  bundleId: string;
  fetchedAtMs: number;
  items: VerifiedSubscriptionStatusItem[];
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const namePattern = /^[A-Z][A-Z0-9_]{0,63}$/u;
const transactionIdPattern = /^\d{1,32}$/u;

function invalid(): never {
  throw new ApiError(
    503,
    "billing_verifier_invalid_response",
    "Billing is temporarily unavailable.",
  );
}

function record(value: unknown): Record<string, unknown> {
  if (value === null || Array.isArray(value) || typeof value !== "object") return invalid();
  return value as Record<string, unknown>;
}

function exactFields(value: Record<string, unknown>, fields: readonly string[]): void {
  const actual = Object.keys(value).sort();
  const expected = [...fields].sort();
  if (actual.length !== expected.length
    || actual.some((field, index) => field !== expected[index])) invalid();
}

function positiveInteger(value: unknown): number | null {
  return Number.isSafeInteger(value) && (value as number) > 0 ? value as number : null;
}

function renewal(
  raw: unknown,
  transaction: VerifiedBillingTransaction,
  config: VerifierConfig,
): VerifiedBillingRenewal {
  const value = record(raw);
  exactFields(value, [
    "autoRenewProductId", "autoRenewStatus", "billingAccountId",
    "environment", "gracePeriodExpiresDateMs", "isInBillingRetryPeriod",
    "originalTransactionId", "productId", "renewalDateMs", "signedDateMs",
  ]);
  const autoRenewProductId = value.autoRenewProductId;
  const autoRenewStatus = value.autoRenewStatus;
  const billingRetry = value.isInBillingRetryPeriod;
  const grace = value.gracePeriodExpiresDateMs === null
    ? null : positiveInteger(value.gracePeriodExpiresDateMs);
  const renewalDate = value.renewalDateMs === null
    ? null : positiveInteger(value.renewalDateMs);
  const signedDateMs = positiveInteger(value.signedDateMs);
  if (
    value.originalTransactionId !== transaction.originalTransactionId
    || value.billingAccountId !== transaction.billingAccountId
    || value.productId !== transaction.productId
    || value.environment !== config.environment
    || (autoRenewProductId !== null
      && (typeof autoRenewProductId !== "string" || !config.productIds.has(autoRenewProductId)))
    || (autoRenewStatus !== null && autoRenewStatus !== 0 && autoRenewStatus !== 1)
    || (billingRetry !== null && typeof billingRetry !== "boolean")
    || (value.gracePeriodExpiresDateMs !== null && grace === null)
    || (value.renewalDateMs !== null && renewalDate === null)
    || signedDateMs === null
  ) return invalid();
  return {
    originalTransactionId: transaction.originalTransactionId,
    billingAccountId: transaction.billingAccountId,
    productId: transaction.productId,
    autoRenewProductId: autoRenewProductId as string | null,
    autoRenewStatus: autoRenewStatus as 0 | 1 | null,
    isInBillingRetryPeriod: billingRetry as boolean | null,
    gracePeriodExpiresDateMs: grace,
    renewalDateMs: renewalDate,
    signedDateMs,
    environment: config.environment,
  };
}

function notification(raw: unknown, config: VerifierConfig): VerifiedAppleNotification {
  const value = record(raw);
  exactFields(value, [
    "bundleId", "environment", "notificationType", "notificationUUID",
    "protocolVersion", "relevant", "renewal", "signedDateMs", "status",
    "subtype", "transaction",
  ]);
  const signedDateMs = positiveInteger(value.signedDateMs);
  const status = value.status;
  if (
    value.protocolVersion !== BILLING_VERIFIER_PROTOCOL_VERSION
    || typeof value.notificationUUID !== "string" || !uuidPattern.test(value.notificationUUID)
    || typeof value.notificationType !== "string" || !namePattern.test(value.notificationType)
    || (value.subtype !== null
      && (typeof value.subtype !== "string" || !namePattern.test(value.subtype)))
    || signedDateMs === null
    || value.environment !== config.environment
    || value.bundleId !== config.bundleId
    || (status !== null && status !== 1 && status !== 2 && status !== 3
      && status !== 4 && status !== 5)
    || typeof value.relevant !== "boolean"
  ) return invalid();
  if (value.relevant === false) {
    if (value.transaction !== null || value.renewal !== null) return invalid();
    return {
      notificationUUID: value.notificationUUID,
      notificationType: value.notificationType,
      subtype: value.subtype as string | null,
      signedDateMs,
      environment: config.environment,
      bundleId: config.bundleId,
      status: status as 1 | 2 | 3 | 4 | 5 | null,
      relevant: false,
      transaction: null,
      renewal: null,
    };
  }
  const transaction = normalizeVerifiedBillingTransaction(value.transaction, config);
  const normalizedRenewal = value.renewal === null
    ? null : renewal(value.renewal, transaction, config);
  return {
    notificationUUID: value.notificationUUID,
    notificationType: value.notificationType,
    subtype: value.subtype as string | null,
    signedDateMs,
    environment: config.environment,
    bundleId: config.bundleId,
    status: status as 1 | 2 | 3 | 4 | 5 | null,
    relevant: true,
    transaction,
    renewal: normalizedRenewal,
  };
}

function subscriptionStatus(raw: unknown, config: VerifierConfig): VerifiedSubscriptionStatus {
  const value = record(raw);
  exactFields(value, [
    "bundleId", "environment", "fetchedAtMs", "items",
    "protocolVersion", "requestedTransactionId",
  ]);
  const fetchedAtMs = positiveInteger(value.fetchedAtMs);
  if (
    value.protocolVersion !== BILLING_VERIFIER_PROTOCOL_VERSION
    || typeof value.requestedTransactionId !== "string"
    || !transactionIdPattern.test(value.requestedTransactionId)
    || value.environment !== config.environment
    || value.bundleId !== config.bundleId
    || fetchedAtMs === null
    || !Array.isArray(value.items)
    || value.items.length < 1
    || value.items.length > 32
  ) return invalid();
  const items = value.items.map((rawItem): VerifiedSubscriptionStatusItem => {
    const item = record(rawItem);
    exactFields(item, ["originalTransactionId", "renewal", "status", "transaction"]);
    if (
      (item.status !== 1 && item.status !== 2 && item.status !== 3
        && item.status !== 4 && item.status !== 5)
      || typeof item.originalTransactionId !== "string"
      || !transactionIdPattern.test(item.originalTransactionId)
    ) return invalid();
    const transaction = normalizeVerifiedBillingTransaction(item.transaction, config);
    if (transaction.originalTransactionId !== item.originalTransactionId) return invalid();
    return {
      status: item.status,
      originalTransactionId: item.originalTransactionId,
      transaction,
      renewal: renewal(item.renewal, transaction, config),
    };
  });
  if (!items.some((item) => item.originalTransactionId === value.requestedTransactionId)) {
    return invalid();
  }
  return {
    requestedTransactionId: value.requestedTransactionId,
    environment: config.environment,
    bundleId: config.bundleId,
    fetchedAtMs,
    items,
  };
}

export async function verifyAppleNotificationViaService(
  signedPayload: string,
  env: Env,
  fetchImpl: typeof fetch = fetch,
): Promise<VerifiedAppleNotification> {
  const raw = await callBillingVerifierService(
    BILLING_NOTIFICATION_VERIFIER_PATH,
    { protocolVersion: BILLING_VERIFIER_PROTOCOL_VERSION, signedPayload },
    env,
    fetchImpl,
  );
  return notification(raw, loadVerifierConfig(env));
}

export async function fetchAppleSubscriptionStatusViaService(
  originalTransactionId: string,
  env: Env,
  fetchImpl: typeof fetch = fetch,
): Promise<VerifiedSubscriptionStatus> {
  if (!transactionIdPattern.test(originalTransactionId)) return invalid();
  const raw = await callBillingVerifierService(
    BILLING_SUBSCRIPTION_STATUS_PATH,
    { protocolVersion: BILLING_VERIFIER_PROTOCOL_VERSION, originalTransactionId },
    env,
    fetchImpl,
  );
  return subscriptionStatus(raw, loadVerifierConfig(env));
}
