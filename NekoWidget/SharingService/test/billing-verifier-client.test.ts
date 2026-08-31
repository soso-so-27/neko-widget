import { describe, expect, it } from "vitest";

import {
  BILLING_VERIFIER_PROTOCOL_VERSION,
  billingVerifierRequestTranscript,
  billingVerifierResponseTranscript,
  bodySHA256,
  signBillingVerifierTranscript,
  verifyBillingVerifierTranscript,
} from "../src/billing-verifier-protocol";
import {
  type VerifiedBillingTransaction,
  verifyAppleTransactionViaService,
} from "../src/billing-verifier-client";
import type { Env } from "../src/env";

const secret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const testEnv = {
  ENVIRONMENT: "local",
  BILLING_VERIFIER_ORIGIN: "http://billing-verifier.invalid",
  BILLING_VERIFIER_SHARED_SECRET: secret,
  BILLING_BUNDLE_ID: "jp.nekowidget.app",
  BILLING_STORE_ENVIRONMENT: "Sandbox",
  BILLING_SUBSCRIPTION_GROUP_ID: "20999999",
  BILLING_MONTHLY_PRODUCT_ID: "jp.nekowidget.plus.monthly",
  BILLING_ANNUAL_PRODUCT_ID: "jp.nekowidget.plus.annual",
} as unknown as Env;

function transaction(
  overrides: Partial<VerifiedBillingTransaction> = {},
): VerifiedBillingTransaction & { protocolVersion: 1 } {
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
    ...overrides,
  };
}

function verifierFetch(
  responseValue: unknown,
  options: { corruptSignature?: boolean; status?: number } = {},
): typeof fetch {
  return async (input, init) => {
    expect(String(input)).toBe(
      "http://billing-verifier.invalid/internal/v1/apple-transactions/verify",
    );
    expect(init?.method).toBe("POST");
    expect(init?.redirect).toBe("error");
    const headers = new Headers(init?.headers);
    expect(headers.get("neko-billing-protocol-version"))
      .toBe(String(BILLING_VERIFIER_PROTOCOL_VERSION));
    const timestamp = Number(headers.get("neko-billing-timestamp"));
    const nonce = headers.get("neko-billing-nonce") ?? "";
    const signature = headers.get("neko-billing-signature") ?? "";
    const requestBody = init?.body as Uint8Array;
    expect(await verifyBillingVerifierTranscript(
      secret,
      signature,
      billingVerifierRequestTranscript(
        timestamp,
        nonce,
        await bodySHA256(requestBody),
      ),
    )).toBe(true);
    expect(JSON.parse(new TextDecoder().decode(requestBody))).toEqual({
      protocolVersion: 1,
      signedTransactionInfo: "header.payload.signature",
    });

    const status = options.status ?? 200;
    const responseBody = new TextEncoder().encode(JSON.stringify(responseValue));
    const responseSignature = options.corruptSignature
      ? "A".repeat(43)
      : await signBillingVerifierTranscript(
        secret,
        billingVerifierResponseTranscript(nonce, status, await bodySHA256(responseBody)),
      );
    return new Response(responseBody, {
      status,
      headers: {
        "Content-Type": "application/json",
        "Neko-Billing-Response-Signature": responseSignature,
      },
    });
  };
}

describe("Worker to Apple verifier client", () => {
  it("authenticates both directions and revalidates normalized identity", async () => {
    const expected = transaction();
    const { protocolVersion: _ignored, ...normalized } = expected;
    expect(await verifyAppleTransactionViaService(
      "header.payload.signature",
      testEnv,
      verifierFetch(expected),
    )).toEqual(normalized);
  });

  it("rejects a forged response and a signed product mismatch", async () => {
    await expect(verifyAppleTransactionViaService(
      "header.payload.signature",
      testEnv,
      verifierFetch(transaction(), { corruptSignature: true }),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response", status: 503 });
    await expect(verifyAppleTransactionViaService(
      "header.payload.signature",
      testEnv,
      verifierFetch(transaction({ productId: "jp.nekowidget.unreviewed" })),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response", status: 503 });
  });

  it("keeps a signed verifier outage retryable", async () => {
    await expect(verifyAppleTransactionViaService(
      "header.payload.signature",
      testEnv,
      verifierFetch(
        { error: { code: "apple_verification_temporarily_unavailable" } },
        { status: 503 },
      ),
    )).rejects.toMatchObject({ code: "billing_verifier_unavailable", status: 503 });
  });
});
