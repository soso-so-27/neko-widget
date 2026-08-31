import {
  Environment,
  InAppOwnershipType,
  Type,
  VerificationException,
  VerificationStatus,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  type ResponseBodyV2DecodedPayload,
} from "@apple/app-store-server-library";
import {
  InvalidAppleTransactionError,
  normalizeVerifiedTransaction,
  type NormalizedBillingTransaction,
} from "./apple-transaction.js";
import type { VerificationServiceConfig } from "./config.js";

export interface NormalizedBillingRenewal {
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

export interface NormalizedAppleNotification {
  protocolVersion: 1;
  notificationUUID: string;
  notificationType: string;
  subtype: string | null;
  signedDateMs: number;
  environment: "Sandbox" | "Production";
  bundleId: string;
  status: 1 | 2 | 3 | 4 | 5 | null;
  relevant: boolean;
  transaction: NormalizedBillingTransaction | null;
  renewal: NormalizedBillingRenewal | null;
}

export class InvalidAppleNotificationError extends Error {}
export class RetryableAppleNotificationError extends Error {}

export interface SignedNotificationDecoder {
  verifyAndDecodeNotification(signedPayload: string): Promise<ResponseBodyV2DecodedPayload>;
  verifyAndDecodeTransaction(signedTransactionInfo: string): Promise<JWSTransactionDecodedPayload>;
  verifyAndDecodeRenewalInfo(signedRenewalInfo: string): Promise<JWSRenewalInfoDecodedPayload>;
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const uuidV4Pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const notificationNamePattern = /^[A-Z][A-Z0-9_]{0,63}$/u;
const transactionIdPattern = /^\d{1,32}$/u;
const maximumClockSkewMs = 5 * 60 * 1_000;

function positiveInteger(value: unknown): number | null {
  return Number.isSafeInteger(value) && (value as number) > 0 ? value as number : null;
}

function configuredEnvironment(
  config: Pick<VerificationServiceConfig, "environment">,
): "Sandbox" | "Production" {
  return config.environment === Environment.SANDBOX ? "Sandbox" : "Production";
}

function statusValue(value: unknown): 1 | 2 | 3 | 4 | 5 | null {
  return value === undefined ? null
    : value === 1 || value === 2 || value === 3 || value === 4 || value === 5
      ? value : null;
}

function generalTransactionIdentityValid(
  payload: JWSTransactionDecodedPayload,
  config: Pick<VerificationServiceConfig, "bundleId" | "environment">,
): boolean {
  return typeof payload.transactionId === "string"
    && transactionIdPattern.test(payload.transactionId)
    && typeof payload.originalTransactionId === "string"
    && transactionIdPattern.test(payload.originalTransactionId)
    && payload.bundleId === config.bundleId
    && payload.environment === config.environment
    && payload.type === Type.AUTO_RENEWABLE_SUBSCRIPTION;
}

export function normalizeVerifiedRenewal(
  payload: JWSRenewalInfoDecodedPayload,
  transaction: NormalizedBillingTransaction,
  config: Pick<VerificationServiceConfig, "environment" | "productIds">,
  nowMs = Date.now(),
): NormalizedBillingRenewal {
  const originalTransactionId = payload.originalTransactionId;
  const billingAccountId = payload.appAccountToken?.toLowerCase();
  const productId = payload.productId;
  const autoRenewProductId = payload.autoRenewProductId ?? null;
  const signedDateMs = positiveInteger(payload.signedDate);
  const gracePeriodExpiresDateMs = payload.gracePeriodExpiresDate === undefined
    ? null : positiveInteger(payload.gracePeriodExpiresDate);
  const renewalDateMs = payload.renewalDate === undefined
    ? null : positiveInteger(payload.renewalDate);
  const autoRenewStatus = payload.autoRenewStatus === undefined
    ? null : payload.autoRenewStatus;
  const isInBillingRetryPeriod = payload.isInBillingRetryPeriod ?? null;
  if (
    originalTransactionId !== transaction.originalTransactionId
    || billingAccountId !== transaction.billingAccountId
    || productId !== transaction.productId
    || typeof productId !== "string"
    || !config.productIds.has(productId)
    || (autoRenewProductId !== null && !config.productIds.has(autoRenewProductId))
    || payload.environment !== config.environment
    || signedDateMs === null
    || signedDateMs > nowMs + maximumClockSkewMs
    || (autoRenewStatus !== null && autoRenewStatus !== 0 && autoRenewStatus !== 1)
    || (payload.isInBillingRetryPeriod !== undefined
      && typeof payload.isInBillingRetryPeriod !== "boolean")
    || (payload.gracePeriodExpiresDate !== undefined && gracePeriodExpiresDateMs === null)
    || (payload.renewalDate !== undefined && renewalDateMs === null)
  ) {
    throw new InvalidAppleNotificationError();
  }
  return {
    originalTransactionId,
    billingAccountId,
    productId,
    autoRenewProductId,
    autoRenewStatus,
    isInBillingRetryPeriod,
    gracePeriodExpiresDateMs,
    renewalDateMs,
    signedDateMs,
    environment: configuredEnvironment(config),
  };
}

export function normalizeVerifiedNotification(
  payload: ResponseBodyV2DecodedPayload,
  decodedTransaction: JWSTransactionDecodedPayload | null,
  decodedRenewal: JWSRenewalInfoDecodedPayload | null,
  config: Pick<
    VerificationServiceConfig,
    "bundleId" | "environment" | "appAppleId" | "subscriptionGroupId" | "productIds"
  >,
  nowMs = Date.now(),
): NormalizedAppleNotification {
  const notificationUUID = payload.notificationUUID?.toLowerCase();
  const notificationType = payload.notificationType;
  const subtype = payload.subtype ?? null;
  const signedDateMs = positiveInteger(payload.signedDate);
  const data = payload.data;
  if (
    typeof notificationUUID !== "string" || !uuidPattern.test(notificationUUID)
    || typeof notificationType !== "string" || !notificationNamePattern.test(notificationType)
    || (subtype !== null && (typeof subtype !== "string" || !notificationNamePattern.test(subtype)))
    || payload.version !== "2.0"
    || signedDateMs === null
    || signedDateMs > nowMs + maximumClockSkewMs
  ) throw new InvalidAppleNotificationError();

  if (data === undefined) {
    if (decodedTransaction !== null || decodedRenewal !== null) {
      throw new InvalidAppleNotificationError();
    }
    return {
      protocolVersion: 1,
      notificationUUID,
      notificationType,
      subtype,
      signedDateMs,
      environment: configuredEnvironment(config),
      bundleId: config.bundleId,
      status: null,
      relevant: false,
      transaction: null,
      renewal: null,
    };
  }

  const status = statusValue(data.status);
  if (
    data.bundleId !== config.bundleId
    || data.environment !== config.environment
    || (config.environment === Environment.PRODUCTION && data.appAppleId !== config.appAppleId)
    || (data.status !== undefined && status === null)
    || (data.signedTransactionInfo === undefined) !== (decodedTransaction === null)
    || (data.signedRenewalInfo === undefined) !== (decodedRenewal === null)
  ) throw new InvalidAppleNotificationError();

  if (decodedTransaction === null) {
    return {
      protocolVersion: 1,
      notificationUUID,
      notificationType,
      subtype,
      signedDateMs,
      environment: configuredEnvironment(config),
      bundleId: config.bundleId,
      status,
      relevant: false,
      transaction: null,
      renewal: null,
    };
  }
  if (!generalTransactionIdentityValid(decodedTransaction, config)) {
    throw new InvalidAppleNotificationError();
  }
  const relevant = typeof decodedTransaction.productId === "string"
    && config.productIds.has(decodedTransaction.productId)
    && decodedTransaction.subscriptionGroupIdentifier === config.subscriptionGroupId
    && decodedTransaction.inAppOwnershipType === InAppOwnershipType.PURCHASED
    // A legitimate Apple transaction can predate appAccountToken adoption.
    // It is signed, but cannot be linked to one of our pseudonymous accounts;
    // acknowledge it as unrelated instead of causing endless Apple retries.
    && typeof decodedTransaction.appAccountToken === "string"
    && uuidV4Pattern.test(decodedTransaction.appAccountToken);
  if (!relevant) {
    return {
      protocolVersion: 1,
      notificationUUID,
      notificationType,
      subtype,
      signedDateMs,
      environment: configuredEnvironment(config),
      bundleId: config.bundleId,
      status,
      relevant: false,
      transaction: null,
      renewal: null,
    };
  }

  let transaction: NormalizedBillingTransaction;
  try {
    transaction = normalizeVerifiedTransaction(decodedTransaction, config, nowMs);
  } catch (error) {
    if (error instanceof InvalidAppleTransactionError) throw new InvalidAppleNotificationError();
    throw error;
  }
  const renewal = decodedRenewal === null
    ? null : normalizeVerifiedRenewal(decodedRenewal, transaction, config, nowMs);
  return {
    protocolVersion: 1,
    notificationUUID,
    notificationType,
    subtype,
    signedDateMs,
    environment: configuredEnvironment(config),
    bundleId: config.bundleId,
    status,
    relevant: true,
    transaction,
    renewal,
  };
}

export class AppleNotificationVerifier {
  constructor(
    private readonly config: VerificationServiceConfig,
    private readonly verifier: SignedNotificationDecoder,
  ) {}

  async verify(signedPayload: string): Promise<NormalizedAppleNotification> {
    try {
      const payload = await this.verifier.verifyAndDecodeNotification(signedPayload);
      const transactionJWS = payload.data?.signedTransactionInfo;
      const renewalJWS = payload.data?.signedRenewalInfo;
      const decodedTransaction = transactionJWS === undefined
        ? null : await this.verifier.verifyAndDecodeTransaction(transactionJWS);
      const decodedRenewal = renewalJWS === undefined
        ? null : await this.verifier.verifyAndDecodeRenewalInfo(renewalJWS);
      return normalizeVerifiedNotification(
        payload,
        decodedTransaction,
        decodedRenewal,
        this.config,
      );
    } catch (error) {
      if (error instanceof InvalidAppleNotificationError) throw error;
      if (
        error instanceof VerificationException
        && error.status !== VerificationStatus.RETRYABLE_VERIFICATION_FAILURE
      ) throw new InvalidAppleNotificationError();
      throw new RetryableAppleNotificationError();
    }
  }
}
