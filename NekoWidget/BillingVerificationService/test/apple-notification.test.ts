import assert from "node:assert/strict";
import test from "node:test";
import {
  Environment,
  InAppOwnershipType,
  TransactionReason,
  Type,
  VerificationException,
  VerificationStatus,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  type ResponseBodyV2DecodedPayload,
} from "@apple/app-store-server-library";
import {
  AppleNotificationVerifier,
  InvalidAppleNotificationError,
  RetryableAppleNotificationError,
  normalizeVerifiedNotification,
} from "../src/apple-notification.js";
import type { VerificationServiceConfig } from "../src/config.js";

const now = 1_788_163_200_000;
const config: VerificationServiceConfig = {
  port: 8080,
  sharedSecret: Buffer.alloc(32),
  rootCertificates: [Buffer.alloc(256)],
  environment: Environment.SANDBOX,
  bundleId: "jp.nekowidget.app",
  subscriptionGroupId: "20999999",
  productIds: new Set(["jp.nekowidget.plus.monthly", "jp.nekowidget.plus.annual"]),
};

function transaction(
  overrides: Partial<JWSTransactionDecodedPayload> = {},
): JWSTransactionDecodedPayload {
  return {
    transactionId: "200000000000001",
    originalTransactionId: "200000000000001",
    appAccountToken: "5f30c0de-0000-4000-8000-000000000001",
    productId: "jp.nekowidget.plus.monthly",
    subscriptionGroupIdentifier: "20999999",
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
  };
}

function renewal(
  overrides: Partial<JWSRenewalInfoDecodedPayload> = {},
): JWSRenewalInfoDecodedPayload {
  return {
    originalTransactionId: "200000000000001",
    appAccountToken: "5f30c0de-0000-4000-8000-000000000001",
    productId: "jp.nekowidget.plus.monthly",
    autoRenewProductId: "jp.nekowidget.plus.monthly",
    autoRenewStatus: 1,
    isInBillingRetryPeriod: false,
    renewalDate: now + 2_592_000_000,
    signedDate: now,
    environment: Environment.SANDBOX,
    ...overrides,
  };
}

function notification(
  overrides: Partial<ResponseBodyV2DecodedPayload> = {},
): ResponseBodyV2DecodedPayload {
  return {
    notificationType: "DID_RENEW",
    notificationUUID: "b113ede5-4eba-4e06-8a9d-3b21243041a7",
    version: "2.0",
    signedDate: now,
    data: {
      appAppleId: 6_801_962_436,
      bundleId: config.bundleId,
      environment: Environment.SANDBOX,
      status: 1,
      signedTransactionInfo: "transaction.jws.value",
      signedRenewalInfo: "renewal.jws.value",
    },
    ...overrides,
  };
}

test("normalizes a relevant V2 notification only after outer and inner identity match", () => {
  const value = normalizeVerifiedNotification(
    notification(),
    transaction(),
    renewal(),
    config,
    now,
  );
  assert.equal(value.relevant, true);
  assert.equal(value.transaction?.billingAccountId,
    "5f30c0de-0000-4000-8000-000000000001");
  assert.equal(value.renewal?.autoRenewStatus, 1);
  assert.equal(value.status, 1);
});

test("acknowledges signed but unlinked or unrelated transactions without importing them", () => {
  const missingToken = transaction();
  delete missingToken.appAccountToken;
  const unrelated = transaction({ productId: "jp.nekowidget.other" });
  for (const decoded of [missingToken, unrelated]) {
    const value = normalizeVerifiedNotification(
      notification(),
      decoded,
      renewal(),
      config,
      now,
    );
    assert.equal(value.relevant, false);
    assert.equal(value.transaction, null);
    assert.equal(value.renewal, null);
  }
  const testPayload = notification({ notificationType: "TEST" });
  delete testPayload.data;
  const testNotification = normalizeVerifiedNotification(
    testPayload,
    null,
    null,
    config,
    now,
  );
  assert.equal(testNotification.relevant, false);
  assert.equal(testNotification.transaction, null);
});

test("rejects outer and inner identity mismatches", () => {
  assert.throws(() => normalizeVerifiedNotification(
    notification({ data: { ...notification().data, bundleId: "com.example.other" } }),
    transaction(),
    renewal(),
    config,
    now,
  ), InvalidAppleNotificationError);
  assert.throws(() => normalizeVerifiedNotification(
    notification(),
    transaction(),
    renewal({ originalTransactionId: "200000000000002" }),
    config,
    now,
  ), InvalidAppleNotificationError);
  assert.throws(() => normalizeVerifiedNotification(
    notification({ signedDate: now + 300_001 }),
    transaction(),
    renewal(),
    config,
    now,
  ), InvalidAppleNotificationError);
});

test("maps only official retryable verification failures to retry", async () => {
  const service = (status: VerificationStatus) => new AppleNotificationVerifier(config, {
    async verifyAndDecodeNotification() { throw new VerificationException(status); },
    async verifyAndDecodeTransaction() { return transaction(); },
    async verifyAndDecodeRenewalInfo() { return renewal(); },
  });
  await assert.rejects(
    service(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE)
      .verify("header.payload.signature"),
    RetryableAppleNotificationError,
  );
  await assert.rejects(
    service(VerificationStatus.INVALID_CERTIFICATE).verify("header.payload.signature"),
    InvalidAppleNotificationError,
  );
});
