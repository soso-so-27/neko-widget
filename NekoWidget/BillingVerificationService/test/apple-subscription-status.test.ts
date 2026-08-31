import assert from "node:assert/strict";
import test from "node:test";
import {
  APIException,
  Environment,
  InAppOwnershipType,
  Status,
  TransactionReason,
  Type,
  VerificationException,
  VerificationStatus,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  type StatusResponse,
} from "@apple/app-store-server-library";
import {
  AppleSubscriptionStatusService,
  InvalidAppleSubscriptionStatusError,
  RetryableAppleSubscriptionStatusError,
  normalizeSubscriptionStatus,
} from "../src/apple-subscription-status.js";
import type { VerificationServiceConfig } from "../src/config.js";

const now = 1_788_163_200_000;
const account = "5f30c0de-0000-4000-8000-000000000001";
const config: VerificationServiceConfig = {
  port: 8080,
  sharedSecret: Buffer.alloc(32),
  rootCertificates: [Buffer.alloc(256)],
  environment: Environment.SANDBOX,
  bundleId: "jp.nekowidget.app",
  subscriptionGroupId: "20999999",
  productIds: new Set(["jp.nekowidget.plus.monthly", "jp.nekowidget.plus.annual"]),
};

function transaction(id: string, overrides: Partial<JWSTransactionDecodedPayload> = {}) {
  return {
    transactionId: id,
    originalTransactionId: id,
    appAccountToken: account,
    productId: "jp.nekowidget.plus.monthly",
    subscriptionGroupIdentifier: config.subscriptionGroupId,
    bundleId: config.bundleId,
    environment: Environment.SANDBOX,
    type: Type.AUTO_RENEWABLE_SUBSCRIPTION,
    inAppOwnershipType: InAppOwnershipType.PURCHASED,
    transactionReason: TransactionReason.PURCHASE,
    purchaseDate: now - 1_000,
    originalPurchaseDate: now - 1_000,
    expiresDate: now + 2_592_000_000,
    signedDate: now,
    ...overrides,
  } satisfies JWSTransactionDecodedPayload;
}

function renewal(id: string, overrides: Partial<JWSRenewalInfoDecodedPayload> = {}) {
  return {
    originalTransactionId: id,
    appAccountToken: account,
    productId: "jp.nekowidget.plus.monthly",
    autoRenewProductId: "jp.nekowidget.plus.monthly",
    autoRenewStatus: 1,
    isInBillingRetryPeriod: false,
    signedDate: now,
    environment: Environment.SANDBOX,
    ...overrides,
  } satisfies JWSRenewalInfoDecodedPayload;
}

function response(ids: Array<{ id: string; status: Status }>): StatusResponse {
  return {
    environment: Environment.SANDBOX,
    bundleId: config.bundleId,
    data: [{
      subscriptionGroupIdentifier: config.subscriptionGroupId,
      lastTransactions: ids.map(({ id, status }) => ({
        status,
        originalTransactionId: id,
        signedTransactionInfo: `transaction.${id}.jws`,
        signedRenewalInfo: `renewal.${id}.jws`,
      })),
    }],
  };
}

function decoder() {
  return {
    async verifyAndDecodeTransaction(jws: string) {
      const id = jws.split(".")[1] ?? "";
      return transaction(id, id.endsWith("3") ? {
        revocationDate: now,
        revocationReason: 1,
      } : {});
    },
    async verifyAndDecodeRenewalInfo(jws: string) {
      const id = jws.split(".")[1] ?? "";
      return renewal(id, id.endsWith("2") ? {
        isInBillingRetryPeriod: true,
        gracePeriodExpiresDate: now + 86_400_000,
      } : {});
    },
  };
}

test("normalizes active, grace-period, and revoked authority observations", async () => {
  const requestedTransactionId = "200000000000001";
  const ids = [
    { id: requestedTransactionId, status: Status.ACTIVE },
    { id: "200000000000002", status: Status.BILLING_GRACE_PERIOD },
    { id: "200000000000003", status: Status.REVOKED },
    { id: "200000000000004", status: Status.BILLING_RETRY },
    { id: "200000000000005", status: Status.EXPIRED },
  ];
  const value = await normalizeSubscriptionStatus(
    response(ids),
    requestedTransactionId,
    decoder(),
    config,
    now,
  );
  assert.deepEqual(value.items.map((item) => item.status), [1, 4, 5, 3, 2]);
  assert.equal(value.items[1]?.renewal.isInBillingRetryPeriod, true);
  assert.equal(value.items[2]?.transaction.revocationReason, 1);
});

test("rejects a response that does not contain the requested verified lineage", async () => {
  await assert.rejects(normalizeSubscriptionStatus(
    response([{ id: "200000000000002", status: Status.ACTIVE }]),
    "200000000000001",
    decoder(),
    config,
    now,
  ), InvalidAppleSubscriptionStatusError);
});

test("maps inner JWS verification failures without hiding retryable OCSP errors", async () => {
  const failingDecoder = (status: VerificationStatus) => ({
    async verifyAndDecodeTransaction() { throw new VerificationException(status); },
    async verifyAndDecodeRenewalInfo() { return renewal("200000000000001"); },
  });
  const input = response([{ id: "200000000000001", status: Status.ACTIVE }]);
  await assert.rejects(normalizeSubscriptionStatus(
    input,
    "200000000000001",
    failingDecoder(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE),
    config,
    now,
  ), RetryableAppleSubscriptionStatusError);
  await assert.rejects(normalizeSubscriptionStatus(
    input,
    "200000000000001",
    failingDecoder(VerificationStatus.INVALID_CERTIFICATE),
    config,
    now,
  ), InvalidAppleSubscriptionStatusError);
});

test("classifies App Store API failures for controlled retry", async () => {
  const service = (error: Error) => new AppleSubscriptionStatusService(
    config,
    decoder(),
    { async getAllSubscriptionStatuses() { throw error; } },
  );
  await assert.rejects(
    service(new APIException(500)).get("200000000000001"),
    RetryableAppleSubscriptionStatusError,
  );
  await assert.rejects(
    service(new APIException(400)).get("200000000000001"),
    InvalidAppleSubscriptionStatusError,
  );
});
