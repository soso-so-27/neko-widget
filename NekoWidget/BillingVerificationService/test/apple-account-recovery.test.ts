import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { Environment, InAppOwnershipType, TransactionReason, Type, type AppTransaction, type JWSTransactionDecodedPayload } from "@apple/app-store-server-library";
import { AppleAccountRecoveryVerifier } from "../src/apple-account-recovery.js";
import { InvalidAppleTransactionError } from "../src/apple-transaction.js";
import type { VerificationServiceConfig } from "../src/config.js";

const account = "5f30c0de-0000-4000-8000-000000000001";
const verificationId = "123e4567-e89b-12d3-a456-426614174000";
const nonce = "123e4567-e89b-12d3-a456-426614174001";
const stableId = "opaque-app-id:ABC";
const proof = createHash("sha384").update(`${nonce}${verificationId}`, "ascii").digest("base64");
const config: VerificationServiceConfig = {
  port: 1, sharedSecret: Buffer.alloc(32), rootCertificates: [Buffer.alloc(256)],
  environment: Environment.SANDBOX, bundleId: "jp.nekowidget.app",
  subscriptionGroupId: "20999999", productIds: new Set(["jp.nekowidget.plus.monthly"]),
};

function pair(overrides: Record<string, unknown> = {}) {
  const now = Date.now();
  const app: AppTransaction = {
    receiptType: Environment.SANDBOX, bundleId: config.bundleId,
    receiptCreationDate: now, appTransactionId: stableId,
    deviceVerification: proof, deviceVerificationNonce: nonce,
  };
  const transaction = {
    transactionId: "200000000000001", originalTransactionId: "200000000000001",
    appAccountToken: account, appTransactionId: stableId,
    productId: "jp.nekowidget.plus.monthly", subscriptionGroupIdentifier: "20999999",
    bundleId: config.bundleId, environment: Environment.SANDBOX,
    type: Type.AUTO_RENEWABLE_SUBSCRIPTION, inAppOwnershipType: InAppOwnershipType.PURCHASED,
    transactionReason: TransactionReason.PURCHASE, purchaseDate: now - 1_000,
    originalPurchaseDate: now - 1_000, expiresDate: now + 60_000, signedDate: now,
    deviceVerification: proof, deviceVerificationNonce: nonce, ...overrides,
  } as JWSTransactionDecodedPayload & { deviceVerification: string; deviceVerificationNonce: string };
  return { app, transaction };
}

function verifier(values = pair()) {
  return new AppleAccountRecoveryVerifier(config, {
    async verifyAndDecodeAppTransaction() { return values.app; },
    async verifyAndDecodeTransaction() { return values.transaction; },
  });
}

const input = {
  signedAppTransactionInfo: "a.b.c", signedTransactionInfo: "d.e.f",
  deviceVerificationId: verificationId, expectedAppTransactionId: stableId,
  expectedTransactionId: "200000000000001", expectedOriginalTransactionId: "200000000000001",
  billingAccountId: account,
};

test("binds two verified JWS payloads and both device proofs", async () => {
  const result = await verifier().verify(input);
  assert.match(result.appTransactionIdHash, /^[A-Za-z0-9_-]{43}$/u);
  assert.equal(result.transaction.billingAccountId, account);
});

test("fails closed for a missing transaction proof or mismatched stable ID", async () => {
  await assert.rejects(verifier(pair({ deviceVerification: undefined })).verify(input), InvalidAppleTransactionError);
  await assert.rejects(verifier(pair({ appTransactionId: "other" })).verify(input), InvalidAppleTransactionError);
  await assert.rejects(verifier().verify({ ...input, expectedAppTransactionId: "other" }), InvalidAppleTransactionError);
});

test("fails closed for Family Shared, revoked, upgraded, or malformed receipt evidence", async () => {
  for (const overrides of [
    { inAppOwnershipType: InAppOwnershipType.FAMILY_SHARED },
    { revocationDate: Date.now() - 1 }, { isUpgraded: true },
  ]) await assert.rejects(verifier(pair(overrides)).verify(input), InvalidAppleTransactionError);
  const invalidReceipt = pair(); invalidReceipt.app.receiptCreationDate = 0;
  await assert.rejects(verifier(invalidReceipt).verify(input), InvalidAppleTransactionError);
});
