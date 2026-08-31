import {
  APIException,
  AppStoreServerAPIClient,
  Environment,
  Status,
  VerificationException,
  VerificationStatus,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  type StatusResponse,
} from "@apple/app-store-server-library";
import {
  InvalidAppleTransactionError,
  normalizeVerifiedTransaction,
  type NormalizedBillingTransaction,
} from "./apple-transaction.js";
import {
  InvalidAppleNotificationError,
  normalizeVerifiedRenewal,
  type NormalizedBillingRenewal,
  type SignedNotificationDecoder,
} from "./apple-notification.js";
import type { VerificationServiceConfig } from "./config.js";

export interface NormalizedSubscriptionStatusItem {
  status: 1 | 2 | 3 | 4 | 5;
  originalTransactionId: string;
  transaction: NormalizedBillingTransaction;
  renewal: NormalizedBillingRenewal;
}

export interface NormalizedSubscriptionStatus {
  protocolVersion: 1;
  requestedTransactionId: string;
  environment: "Sandbox" | "Production";
  bundleId: string;
  fetchedAtMs: number;
  items: NormalizedSubscriptionStatusItem[];
}

export class InvalidAppleSubscriptionStatusError extends Error {}
export class RetryableAppleSubscriptionStatusError extends Error {}

export interface SubscriptionStatusProvider {
  getAllSubscriptionStatuses(transactionId: string): Promise<StatusResponse>;
}

const transactionIdPattern = /^\d{1,32}$/u;

function normalizedStatus(value: unknown): 1 | 2 | 3 | 4 | 5 | null {
  return value === Status.ACTIVE
    || value === Status.EXPIRED
    || value === Status.BILLING_RETRY
    || value === Status.BILLING_GRACE_PERIOD
    || value === Status.REVOKED
    ? value : null;
}

export async function normalizeSubscriptionStatus(
  response: StatusResponse,
  requestedTransactionId: string,
  verifier: Pick<
    SignedNotificationDecoder,
    "verifyAndDecodeTransaction" | "verifyAndDecodeRenewalInfo"
  >,
  config: VerificationServiceConfig,
  nowMs = Date.now(),
): Promise<NormalizedSubscriptionStatus> {
  if (
    !transactionIdPattern.test(requestedTransactionId)
    || response.bundleId !== config.bundleId
    || response.environment !== config.environment
    || (config.environment === Environment.PRODUCTION && response.appAppleId !== config.appAppleId)
    || !Array.isArray(response.data)
  ) throw new InvalidAppleSubscriptionStatusError();

  const items: NormalizedSubscriptionStatusItem[] = [];
  for (const group of response.data) {
    if (group.subscriptionGroupIdentifier !== config.subscriptionGroupId) continue;
    if (!Array.isArray(group.lastTransactions)) {
      throw new InvalidAppleSubscriptionStatusError();
    }
    for (const item of group.lastTransactions) {
      const status = normalizedStatus(item.status);
      if (
        status === null
        || typeof item.originalTransactionId !== "string"
        || !transactionIdPattern.test(item.originalTransactionId)
        || typeof item.signedTransactionInfo !== "string"
        || typeof item.signedRenewalInfo !== "string"
      ) throw new InvalidAppleSubscriptionStatusError();
      let decodedTransaction: JWSTransactionDecodedPayload;
      let decodedRenewal: JWSRenewalInfoDecodedPayload;
      try {
        [decodedTransaction, decodedRenewal] = await Promise.all([
          verifier.verifyAndDecodeTransaction(item.signedTransactionInfo),
          verifier.verifyAndDecodeRenewalInfo(item.signedRenewalInfo),
        ]);
      } catch (error) {
        if (
          error instanceof VerificationException
          && error.status !== VerificationStatus.RETRYABLE_VERIFICATION_FAILURE
        ) throw new InvalidAppleSubscriptionStatusError();
        throw new RetryableAppleSubscriptionStatusError();
      }
      let transaction: NormalizedBillingTransaction;
      let renewal: NormalizedBillingRenewal;
      try {
        transaction = normalizeVerifiedTransaction(decodedTransaction, config, nowMs);
        renewal = normalizeVerifiedRenewal(decodedRenewal, transaction, config, nowMs);
      } catch (error) {
        if (
          error instanceof InvalidAppleTransactionError
          || error instanceof InvalidAppleNotificationError
        ) throw new InvalidAppleSubscriptionStatusError();
        throw error;
      }
      if (
        item.originalTransactionId !== transaction.originalTransactionId
        || renewal.originalTransactionId !== transaction.originalTransactionId
      ) throw new InvalidAppleSubscriptionStatusError();
      items.push({
        status,
        originalTransactionId: item.originalTransactionId,
        transaction,
        renewal,
      });
    }
  }
  if (!items.some((item) => item.originalTransactionId === requestedTransactionId)) {
    throw new InvalidAppleSubscriptionStatusError();
  }
  return {
    protocolVersion: 1,
    requestedTransactionId,
    environment: config.environment === Environment.SANDBOX ? "Sandbox" : "Production",
    bundleId: config.bundleId,
    fetchedAtMs: nowMs,
    items,
  };
}

export class AppleSubscriptionStatusService {
  private readonly provider: SubscriptionStatusProvider;

  constructor(
    private readonly config: VerificationServiceConfig,
    private readonly verifier: Pick<
      SignedNotificationDecoder,
      "verifyAndDecodeTransaction" | "verifyAndDecodeRenewalInfo"
    >,
    provider?: SubscriptionStatusProvider,
  ) {
    const api = config.serverAPI;
    if (provider !== undefined) {
      this.provider = provider;
    } else if (api !== undefined) {
      this.provider = new AppStoreServerAPIClient(
        api.signingKey,
        api.keyId,
        api.issuerId,
        config.bundleId,
        config.environment,
      );
    } else {
      this.provider = {
        async getAllSubscriptionStatuses() {
          throw new RetryableAppleSubscriptionStatusError();
        },
      };
    }
  }

  async get(transactionId: string): Promise<NormalizedSubscriptionStatus> {
    let response: StatusResponse;
    try {
      response = await this.provider.getAllSubscriptionStatuses(transactionId);
    } catch (error) {
      if (error instanceof InvalidAppleSubscriptionStatusError) throw error;
      if (error instanceof APIException && error.httpStatusCode >= 400 && error.httpStatusCode < 500
        && error.httpStatusCode !== 429) {
        throw new InvalidAppleSubscriptionStatusError();
      }
      throw new RetryableAppleSubscriptionStatusError();
    }
    return normalizeSubscriptionStatus(
      response,
      transactionId,
      this.verifier,
      this.config,
    );
  }
}
