import {
  Environment,
  InAppOwnershipType,
  SignedDataVerifier,
  TransactionReason,
  Type,
  VerificationException,
  VerificationStatus,
  type JWSTransactionDecodedPayload,
} from "@apple/app-store-server-library";
import type { VerificationServiceConfig } from "./config.js";

export interface NormalizedBillingTransaction {
  protocolVersion: 1;
  transactionId: string;
  originalTransactionId: string;
  billingAccountId: string;
  productId: string;
  subscriptionGroupId: string;
  bundleId: string;
  environment: "Sandbox" | "Production";
  ownershipType: "PURCHASED";
  transactionReason: "PURCHASE" | "RENEWAL";
  purchaseDateMs: number;
  originalPurchaseDateMs: number;
  expiresDateMs: number;
  signedDateMs: number;
  revocationDateMs: number | null;
  revocationReason: 0 | 1 | null;
  isUpgraded: boolean;
}

export class InvalidAppleTransactionError extends Error {}
export class RetryableAppleVerificationError extends Error {}

interface SignedTransactionDecoder {
  verifyAndDecodeTransaction(signedTransactionInfo: string): Promise<JWSTransactionDecodedPayload>;
}

const transactionIdPattern = /^\d{1,32}$/u;
const uuidV4Pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const maximumClockSkewMs = 5 * 60 * 1_000;

function positiveSafeInteger(value: unknown): number | null {
  return Number.isSafeInteger(value) && (value as number) > 0 ? value as number : null;
}

export function normalizeVerifiedTransaction(
  payload: JWSTransactionDecodedPayload,
  config: Pick<
    VerificationServiceConfig,
    "bundleId" | "environment" | "subscriptionGroupId" | "productIds"
  >,
  nowMs = Date.now(),
): NormalizedBillingTransaction {
  const transactionId = payload.transactionId;
  const originalTransactionId = payload.originalTransactionId;
  const rawBillingAccountId = payload.appAccountToken;
  const billingAccountId = rawBillingAccountId?.toLowerCase();
  const productId = payload.productId;
  const subscriptionGroupId = payload.subscriptionGroupIdentifier;
  const purchaseDateMs = positiveSafeInteger(payload.purchaseDate);
  const originalPurchaseDateMs = positiveSafeInteger(payload.originalPurchaseDate);
  const expiresDateMs = positiveSafeInteger(payload.expiresDate);
  const signedDateMs = positiveSafeInteger(payload.signedDate);
  const revocationDateMs = payload.revocationDate === undefined
    ? null : positiveSafeInteger(payload.revocationDate);
  const revocationReason = payload.revocationReason === undefined
    ? null : payload.revocationReason;
  const ownershipType = payload.inAppOwnershipType;
  const transactionReason = payload.transactionReason;
  if (
    typeof transactionId !== "string" || !transactionIdPattern.test(transactionId)
    || typeof originalTransactionId !== "string" || !transactionIdPattern.test(originalTransactionId)
    || typeof billingAccountId !== "string" || !uuidV4Pattern.test(billingAccountId)
    || typeof productId !== "string" || !config.productIds.has(productId)
    || subscriptionGroupId !== config.subscriptionGroupId
    || payload.bundleId !== config.bundleId
    || payload.environment !== config.environment
    || payload.type !== Type.AUTO_RENEWABLE_SUBSCRIPTION
    || ownershipType !== InAppOwnershipType.PURCHASED
    || (transactionReason !== TransactionReason.PURCHASE
      && transactionReason !== TransactionReason.RENEWAL)
    || purchaseDateMs === null
    || originalPurchaseDateMs === null
    || expiresDateMs === null
    || signedDateMs === null
    || signedDateMs > nowMs + maximumClockSkewMs
    || purchaseDateMs > signedDateMs + maximumClockSkewMs
    || originalPurchaseDateMs > purchaseDateMs + maximumClockSkewMs
    || expiresDateMs <= purchaseDateMs
    || (payload.revocationDate !== undefined && revocationDateMs === null)
    || (revocationReason !== null && revocationReason !== 0 && revocationReason !== 1)
  ) {
    throw new InvalidAppleTransactionError();
  }
  return {
    protocolVersion: 1,
    transactionId,
    originalTransactionId,
    billingAccountId,
    productId,
    subscriptionGroupId: config.subscriptionGroupId,
    bundleId: config.bundleId,
    environment: config.environment === Environment.SANDBOX ? "Sandbox" : "Production",
    ownershipType,
    transactionReason,
    purchaseDateMs,
    originalPurchaseDateMs,
    expiresDateMs,
    signedDateMs,
    revocationDateMs,
    revocationReason,
    isUpgraded: payload.isUpgraded === true,
  };
}

export class AppleTransactionVerifier {
  private readonly verifier: SignedTransactionDecoder;

  constructor(
    private readonly config: VerificationServiceConfig,
    verifier?: SignedTransactionDecoder,
  ) {
    this.verifier = verifier ?? new SignedDataVerifier(
      config.rootCertificates,
      true,
      config.environment,
      config.bundleId,
      config.appAppleId,
    );
  }

  async verify(signedTransactionInfo: string): Promise<NormalizedBillingTransaction> {
    let payload: JWSTransactionDecodedPayload;
    try {
      payload = await this.verifier.verifyAndDecodeTransaction(signedTransactionInfo);
    } catch (error) {
      if (
        error instanceof VerificationException
        && error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE
      ) {
        throw new RetryableAppleVerificationError();
      }
      if (error instanceof VerificationException) throw new InvalidAppleTransactionError();
      throw new RetryableAppleVerificationError();
    }
    return normalizeVerifiedTransaction(payload, this.config);
  }
}
