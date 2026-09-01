import { describe, expect, it } from "vitest";

import {
  fetchAppleSubscriptionStatusViaService,
  verifyAppleNotificationViaService,
} from "../src/billing-apple-client";
import {
  BILLING_NOTIFICATION_VERIFIER_PATH,
  BILLING_SUBSCRIPTION_STATUS_PATH,
  billingVerifierRequestTranscript,
  billingVerifierResponseTranscript,
  bodySHA256,
  signBillingVerifierTranscript,
  verifyBillingVerifierTranscript,
} from "../src/billing-verifier-protocol";
import type { Env } from "../src/env";

const secret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const testEnv = {
  ENVIRONMENT: "local",
  BILLING_VERIFIER_ORIGIN: "http://127.0.0.1:8080",
  BILLING_VERIFIER_ACCESS_CLIENT_ID: "staging-verifier.access",
  BILLING_VERIFIER_ACCESS_CLIENT_SECRET: "staging-access-secret",
  BILLING_VERIFIER_SHARED_SECRET: secret,
  BILLING_BUNDLE_ID: "jp.nekowidget.app",
  BILLING_STORE_ENVIRONMENT: "Sandbox",
  BILLING_SUBSCRIPTION_GROUP_ID: "20999999",
  BILLING_MONTHLY_PRODUCT_ID: "jp.nekowidget.plus.monthly",
  BILLING_ANNUAL_PRODUCT_ID: "jp.nekowidget.plus.annual",
} as unknown as Env;

function transaction() {
  const now = Date.now();
  return {
    protocolVersion: 1,
    transactionId: "200000000000001",
    originalTransactionId: "200000000000001",
    billingAccountId: "5f30c0de-0000-4000-8000-000000000001",
    productId: "jp.nekowidget.plus.monthly",
    subscriptionGroupId: "20999999",
    bundleId: "jp.nekowidget.app",
    environment: "Sandbox",
    ownershipType: "PURCHASED",
    transactionReason: "PURCHASE",
    purchaseDateMs: now - 1_000,
    originalPurchaseDateMs: now - 1_000,
    expiresDateMs: now + 2_592_000_000,
    signedDateMs: now,
    revocationDateMs: null,
    revocationReason: null,
    isUpgraded: false,
  };
}

function renewal() {
  const value = transaction();
  return {
    originalTransactionId: value.originalTransactionId,
    billingAccountId: value.billingAccountId,
    productId: value.productId,
    autoRenewProductId: value.productId,
    autoRenewStatus: 1,
    isInBillingRetryPeriod: false,
    gracePeriodExpiresDateMs: null,
    renewalDateMs: value.expiresDateMs,
    signedDateMs: value.signedDateMs,
    environment: "Sandbox",
  };
}

function authenticatedFetch(
  expectedPath: string,
  expectedBody: Record<string, unknown>,
  responseValue: unknown,
): typeof fetch {
  return async (input, init) => {
    expect(String(input)).toBe(`http://127.0.0.1:8080${expectedPath}`);
    const headers = new Headers(init?.headers);
    expect(headers.get("cf-access-client-id")).toBe("staging-verifier.access");
    expect(headers.get("cf-access-client-secret")).toBe("staging-access-secret");
    const timestamp = Number(headers.get("neko-billing-timestamp"));
    const nonce = headers.get("neko-billing-nonce") ?? "";
    const body = init?.body as Uint8Array;
    expect(JSON.parse(new TextDecoder().decode(body))).toEqual(expectedBody);
    expect(await verifyBillingVerifierTranscript(
      secret,
      headers.get("neko-billing-signature") ?? "",
      billingVerifierRequestTranscript(timestamp, nonce, await bodySHA256(body)),
    )).toBe(true);
    const responseBody = new TextEncoder().encode(JSON.stringify(responseValue));
    const responseSignature = await signBillingVerifierTranscript(
      secret,
      billingVerifierResponseTranscript(nonce, 200, await bodySHA256(responseBody)),
    );
    return new Response(responseBody, {
      status: 200,
      headers: { "Neko-Billing-Response-Signature": responseSignature },
    });
  };
}

describe("Worker Apple billing service clients", () => {
  it("authenticates and strictly revalidates a normalized V2 notification", async () => {
    const response = {
      protocolVersion: 1,
      notificationUUID: "b113ede5-4eba-4e06-8a9d-3b21243041a7",
      notificationType: "DID_RENEW",
      subtype: null,
      signedDateMs: Date.now(),
      environment: "Sandbox",
      bundleId: "jp.nekowidget.app",
      status: 1,
      relevant: true,
      transaction: transaction(),
      renewal: renewal(),
    };
    const value = await verifyAppleNotificationViaService(
      "header.payload.signature",
      testEnv,
      authenticatedFetch(
        BILLING_NOTIFICATION_VERIFIER_PATH,
        { protocolVersion: 1, signedPayload: "header.payload.signature" },
        response,
      ),
    );
    expect(value.notificationUUID).toBe(response.notificationUUID);
    expect(value.transaction?.billingAccountId).toBe(transaction().billingAccountId);
  });

  it("authenticates and strictly revalidates Subscription Status authority", async () => {
    const response = {
      protocolVersion: 1,
      requestedTransactionId: "200000000000001",
      environment: "Sandbox",
      bundleId: "jp.nekowidget.app",
      fetchedAtMs: Date.now(),
      items: [{
        status: 4,
        originalTransactionId: "200000000000001",
        transaction: transaction(),
        renewal: { ...renewal(), isInBillingRetryPeriod: true },
      }],
    };
    const value = await fetchAppleSubscriptionStatusViaService(
      "200000000000001",
      testEnv,
      authenticatedFetch(
        BILLING_SUBSCRIPTION_STATUS_PATH,
        { protocolVersion: 1, originalTransactionId: "200000000000001" },
        response,
      ),
    );
    expect(value.items[0]?.status).toBe(4);
    expect(value.items[0]?.renewal.isInBillingRetryPeriod).toBe(true);
  });

  it("rejects signed responses with extra raw material or lineage mismatch", async () => {
    const rawLeak = {
      protocolVersion: 1,
      notificationUUID: "b113ede5-4eba-4e06-8a9d-3b21243041a7",
      notificationType: "TEST",
      subtype: null,
      signedDateMs: Date.now(),
      environment: "Sandbox",
      bundleId: "jp.nekowidget.app",
      status: null,
      relevant: false,
      transaction: null,
      renewal: null,
      signedPayload: "must-not-cross",
    };
    await expect(verifyAppleNotificationViaService(
      "header.payload.signature",
      testEnv,
      authenticatedFetch(
        BILLING_NOTIFICATION_VERIFIER_PATH,
        { protocolVersion: 1, signedPayload: "header.payload.signature" },
        rawLeak,
      ),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response" });

    const mismatch = {
      protocolVersion: 1,
      requestedTransactionId: "200000000000001",
      environment: "Sandbox",
      bundleId: "jp.nekowidget.app",
      fetchedAtMs: Date.now(),
      items: [{
        status: 1,
        originalTransactionId: "200000000000002",
        transaction: transaction(),
        renewal: renewal(),
      }],
    };
    await expect(fetchAppleSubscriptionStatusViaService(
      "200000000000001",
      testEnv,
      authenticatedFetch(
        BILLING_SUBSCRIPTION_STATUS_PATH,
        { protocolVersion: 1, originalTransactionId: "200000000000001" },
        mismatch,
      ),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response" });
  });
});
