import assert from "node:assert/strict";
import test from "node:test";
import {
  Environment,
  InAppOwnershipType,
  TransactionReason,
  Type,
  VerificationException,
  VerificationStatus,
  type JWSTransactionDecodedPayload,
} from "@apple/app-store-server-library";
import {
  AppleTransactionVerifier,
  InvalidAppleTransactionError,
  RetryableAppleVerificationError,
  normalizeVerifiedTransaction,
} from "../src/apple-transaction.js";
import type { VerificationServiceConfig } from "../src/config.js";

const now = 1_788_163_200_000;
const config: Pick<
  VerificationServiceConfig,
  "bundleId" | "environment" | "subscriptionGroupId" | "productIds"
> = {
  bundleId: "jp.nekowidget.app",
  environment: Environment.SANDBOX,
  subscriptionGroupId: "20999999",
  productIds: new Set(["jp.nekowidget.plus.monthly", "jp.nekowidget.plus.annual"]),
};

function transaction(
  overrides: Partial<JWSTransactionDecodedPayload> = {},
): JWSTransactionDecodedPayload {
  return {
    transactionId: "200000000000001",
    originalTransactionId: "200000000000001",
    appAccountToken: "5F30C0DE-0000-4000-8000-000000000001",
    productId: "jp.nekowidget.plus.monthly",
    subscriptionGroupIdentifier: "20999999",
    bundleId: "jp.nekowidget.app",
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

test("normalizes a reviewed auto-renewable subscription without granting a window", () => {
  const result = normalizeVerifiedTransaction(transaction(), config, now);
  assert.equal(result.billingAccountId, "5f30c0de-0000-4000-8000-000000000001");
  assert.equal(result.ownershipType, "PURCHASED");
  assert.equal(result.isUpgraded, false);
  assert.equal(result.revocationDateMs, null);
});

test("preserves upgrade and revocation facts for non-entitling audit", () => {
  const result = normalizeVerifiedTransaction(transaction({
    isUpgraded: true,
    revocationDate: now - 500,
    revocationReason: 1,
  }), config, now);
  assert.equal(result.ownershipType, "PURCHASED");
  assert.equal(result.isUpgraded, true);
  assert.equal(result.revocationReason, 1);
});

test("rejects missing account token and every product identity mismatch", () => {
  const missingAccountToken = transaction();
  delete missingAccountToken.appAccountToken;
  for (const payload of [
    missingAccountToken,
    transaction({ bundleId: "com.example.other" }),
    transaction({ environment: Environment.PRODUCTION }),
    transaction({ productId: "jp.nekowidget.other" }),
    transaction({ subscriptionGroupIdentifier: "other" }),
    transaction({ type: Type.NON_CONSUMABLE }),
    transaction({ inAppOwnershipType: InAppOwnershipType.FAMILY_SHARED }),
    transaction({ signedDate: now + 300_001 }),
  ]) {
    assert.throws(
      () => normalizeVerifiedTransaction(payload, config, now),
      InvalidAppleTransactionError,
    );
  }
});

test("accepts independently optional signed revocation facts", () => {
  assert.deepEqual(
    normalizeVerifiedTransaction(transaction({ revocationDate: now - 500 }), config, now),
    expectObject({ revocationDateMs: now - 500, revocationReason: null }),
  );
  assert.deepEqual(
    normalizeVerifiedTransaction(transaction({ revocationReason: 0 }), config, now),
    expectObject({ revocationDateMs: null, revocationReason: 0 }),
  );
});

function expectObject(
  values: Partial<ReturnType<typeof normalizeVerifiedTransaction>>,
): ReturnType<typeof normalizeVerifiedTransaction> {
  return { ...normalizeVerifiedTransaction(transaction(), config, now), ...values };
}

test("treats an unknown verifier failure as retryable", async () => {
  const serviceConfig: VerificationServiceConfig = {
    port: 8080,
    sharedSecret: Buffer.alloc(32),
    rootCertificates: [Buffer.alloc(256)],
    environment: Environment.SANDBOX,
    bundleId: config.bundleId,
    subscriptionGroupId: config.subscriptionGroupId,
    productIds: config.productIds,
  };
  const verifier = new AppleTransactionVerifier(serviceConfig, {
    async verifyAndDecodeTransaction() {
      throw new Error("dependency failure");
    },
  });
  await assert.rejects(
    verifier.verify("header.payload.signature"),
    RetryableAppleVerificationError,
  );
});

test("maps official verification failures without hiding retryable OCSP failures", async () => {
  const serviceConfig: VerificationServiceConfig = {
    port: 8080,
    sharedSecret: Buffer.alloc(32),
    rootCertificates: [Buffer.alloc(256)],
    environment: Environment.SANDBOX,
    bundleId: config.bundleId,
    subscriptionGroupId: config.subscriptionGroupId,
    productIds: config.productIds,
  };
  const service = (status: VerificationStatus) => new AppleTransactionVerifier(serviceConfig, {
    async verifyAndDecodeTransaction() {
      throw new VerificationException(status);
    },
  });
  await assert.rejects(
    service(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE)
      .verify("header.payload.signature"),
    RetryableAppleVerificationError,
  );
  await assert.rejects(
    service(VerificationStatus.INVALID_CERTIFICATE).verify("header.payload.signature"),
    InvalidAppleTransactionError,
  );
});
