import { createHash, createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { verifyAppleTransactionViaService } from "../src/billing-verifier-client";
import type { Env } from "../src/env";

// Offline transport rehearsal. These are deliberately public synthetic secrets,
// not Apple JWS signatures or a test of Cloudflare's deployed Access policy.
const environments = ["Production", "Sandbox"] as const;
type Store = typeof environments[number];
const profiles = Object.fromEntries(environments.map((store, index) => [store, {
  ENVIRONMENT: "production",
  BILLING_VERIFIER_TRANSPORT: "https-access",
  BILLING_VERIFIER_ORIGIN: `https://${index === 0 ? "production" : "review-sandbox"}.billing.test`,
  BILLING_VERIFIER_ACCESS_CLIENT_ID: `synthetic-${store}.access`,
  BILLING_VERIFIER_ACCESS_CLIENT_SECRET: `synthetic-only-${store}-access-secret`,
  BILLING_VERIFIER_SHARED_SECRET: Buffer.alloc(32, index + 17).toString("base64url"),
  BILLING_BUNDLE_ID: "jp.nekowidget.app",
  BILLING_STORE_ENVIRONMENT: store,
  BILLING_SUBSCRIPTION_GROUP_ID: "20999999",
  BILLING_MONTHLY_PRODUCT_ID: "jp.nekowidget.plus.monthly",
}])) as Record<Store, Env>;

const digest = (body: Uint8Array) => createHash("sha256").update(body).digest("base64url");
const sign = (key: string, fields: (string | number)[]) => createHmac("sha256", Buffer.from(key, "base64url"))
  .update(fields.join("\n")).digest("base64url");

function transaction(store: Store) {
  const now = Date.now();
  return {
    protocolVersion: 1, transactionId: "200000000000001", originalTransactionId: "200000000000001",
    billingAccountId: "5f30c0de-0000-4000-8000-000000000001",
    productId: "jp.nekowidget.plus.monthly", subscriptionGroupId: "20999999",
    bundleId: "jp.nekowidget.app", environment: store,
    ownershipType: "PURCHASED", transactionReason: "PURCHASE",
    purchaseDateMs: now - 1_000, originalPurchaseDateMs: now - 1_000,
    expiresDateMs: now + 86_400_000, signedDateMs: now,
    revocationDateMs: null, revocationReason: null, isUpgraded: false,
  };
}

function edge(options: { responseStore?: Store; wrongNonce?: boolean } = {}) {
  const admitted: Record<Store, number> = { Production: 0, Sandbox: 0 };
  let requests = 0;
  const fetchMock: typeof fetch = async (input, init) => {
    requests++;
    const url = new URL(String(input));
    const store = environments.find(value => profiles[value].BILLING_VERIFIER_ORIGIN === url.origin);
    expect(url.protocol).toBe("https:");
    expect(url.pathname).toBe("/internal/v1/apple-transactions/verify");
    expect(init?.method).toBe("POST");
    expect(init?.redirect).toBe("manual");
    if (!store) return new Response("denied", { status: 403 });
    const profile = profiles[store];
    const headers = new Headers(init?.headers);
    if (headers.get("CF-Access-Client-Id") !== profile.BILLING_VERIFIER_ACCESS_CLIENT_ID
      || headers.get("CF-Access-Client-Secret") !== profile.BILLING_VERIFIER_ACCESS_CLIENT_SECRET) {
      return new Response("denied", { status: 403 });
    }
    const body = init?.body as Uint8Array;
    const nonce = headers.get("Neko-Billing-Nonce") ?? "";
    const timestamp = Number(headers.get("Neko-Billing-Timestamp"));
    expect(Math.abs(Date.now() / 1_000 - timestamp)).toBeLessThan(5);
    expect(nonce).toMatch(/^[A-Za-z0-9_-]{22}$/u);
    const secret = profile.BILLING_VERIFIER_SHARED_SECRET!;
    if (headers.get("Neko-Billing-Signature") !== sign(secret,
      ["NWB1.VERIFIER.REQUEST", timestamp, nonce, digest(body)])) {
      return new Response("denied", { status: 403 });
    }
    expect(JSON.parse(new TextDecoder().decode(body))).toEqual({
      protocolVersion: 1, signedTransactionInfo: "synthetic.transaction.signature",
    });
    admitted[store]++;
    const responseBody = new TextEncoder().encode(JSON.stringify(transaction(options.responseStore ?? store)));
    return new Response(responseBody, { headers: {
      "Content-Type": "application/json",
      "Neko-Billing-Response-Signature": sign(secret,
        ["NWB1.VERIFIER.RESPONSE", options.wrongNonce ? "other-request" : nonce, 200, digest(responseBody)]),
    } });
  };
  return { fetchMock, admitted, requests: () => requests };
}

describe("production/reviewer Sandbox HTTPS preparation (offline only)", () => {
  it("uses distinct origins, Access credentials and HMAC keys for the same transaction/account IDs", async () => {
    for (const key of ["BILLING_VERIFIER_ORIGIN", "BILLING_VERIFIER_ACCESS_CLIENT_ID",
      "BILLING_VERIFIER_ACCESS_CLIENT_SECRET", "BILLING_VERIFIER_SHARED_SECRET"] as const) {
      expect(profiles.Production[key]).not.toBe(profiles.Sandbox[key]);
    }
    const mock = edge();
    for (const store of environments) {
      const result = await verifyAppleTransactionViaService("synthetic.transaction.signature", profiles[store], mock.fetchMock);
      expect(result.environment).toBe(store);
      expect(result.transactionId).toBe("200000000000001");
    }
    expect(mock.admitted).toEqual({ Production: 1, Sandbox: 1 });
  });

  it("does not contact a verifier when required configuration or HTTPS transport is missing", async () => {
    const mock = edge();
    for (const store of environments) {
      for (const name of ["BILLING_VERIFIER_ORIGIN", "BILLING_VERIFIER_ACCESS_CLIENT_ID",
        "BILLING_VERIFIER_ACCESS_CLIENT_SECRET", "BILLING_VERIFIER_SHARED_SECRET",
        "BILLING_STORE_ENVIRONMENT", "BILLING_BUNDLE_ID", "BILLING_MONTHLY_PRODUCT_ID"] as const) {
        await expect(verifyAppleTransactionViaService("synthetic.transaction.signature",
          { ...profiles[store], [name]: undefined }, mock.fetchMock)).rejects.toMatchObject({ code: "billing_configuration_unavailable" });
      }
      for (const origin of ["http://127.0.0.1:8080", "http://production.billing.test",
        "https://production.billing.test/path", "https://production.billing.test?override=1"]) {
        await expect(verifyAppleTransactionViaService("synthetic.transaction.signature",
          { ...profiles[store], BILLING_VERIFIER_ORIGIN: origin }, mock.fetchMock)).rejects.toThrow();
      }
      await expect(verifyAppleTransactionViaService("synthetic.transaction.signature",
        { ...profiles[store], BILLING_VERIFIER_TRANSPORT: "private-binding" }, mock.fetchMock)).rejects.toThrow();
    }
    expect(mock.requests()).toBe(0);
  });

  it("rejects an origin swap before either mock verifier admits the transaction", async () => {
    const mock = edge();
    for (const store of environments) {
      const other = store === "Production" ? "Sandbox" : "Production";
      await expect(verifyAppleTransactionViaService("synthetic.transaction.signature",
        { ...profiles[store], BILLING_VERIFIER_ORIGIN: profiles[other].BILLING_VERIFIER_ORIGIN! }, mock.fetchMock)).rejects.toThrow();
    }
    expect(mock.admitted).toEqual({ Production: 0, Sandbox: 0 });
  });

  it("rejects a cross-environment HMAC key even with the destination's Access credentials", async () => {
    const mock = edge();
    for (const store of environments) {
      const other = store === "Production" ? "Sandbox" : "Production";
      await expect(verifyAppleTransactionViaService("synthetic.transaction.signature",
        { ...profiles[store], BILLING_VERIFIER_SHARED_SECRET: profiles[other].BILLING_VERIFIER_SHARED_SECRET! }, mock.fetchMock)).rejects.toThrow();
    }
    expect(mock.admitted).toEqual({ Production: 0, Sandbox: 0 });
  });

  it("rejects authentically signed responses from the other store environment", async () => {
    for (const store of environments) {
      const other = store === "Production" ? "Sandbox" : "Production";
      await expect(verifyAppleTransactionViaService("synthetic.transaction.signature", profiles[store],
        edge({ responseStore: other }).fetchMock)).rejects.toMatchObject({ code: "billing_verifier_invalid_response" });
    }
  });

  it("rejects a signed response bound to a different request nonce", async () => {
    await expect(verifyAppleTransactionViaService("synthetic.transaction.signature", profiles.Production,
      edge({ wrongNonce: true }).fetchMock)).rejects.toMatchObject({ code: "billing_verifier_invalid_response" });
  });

  it("never follows Access login redirects or accepts unsigned Access denials", async () => {
    for (const status of [302, 403]) {
      let calls = 0;
      const mock: typeof fetch = async (_input, init) => {
        calls++;
        expect(init?.redirect).toBe("manual");
        return new Response(null, { status, headers: { Location: "https://other.billing.test/login" } });
      };
      await expect(verifyAppleTransactionViaService("synthetic.transaction.signature", profiles.Production, mock)).rejects.toThrow();
      expect(calls).toBe(1);
    }
  });
});
