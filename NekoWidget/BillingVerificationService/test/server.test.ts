import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import test from "node:test";
import { Environment } from "@apple/app-store-server-library";
import {
  RetryableAppleVerificationError,
  type NormalizedBillingTransaction,
} from "../src/apple-transaction.js";
import type { VerificationServiceConfig } from "../src/config.js";
import {
  PROTOCOL_VERSION,
  bodySHA256,
  requestTranscript,
  responseTranscript,
  signTranscript,
  verifyTranscript,
} from "../src/internal-auth.js";
import { createBillingVerificationServer } from "../src/server.js";

const sharedSecret = Buffer.from(
  "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
  "base64url",
);
const config: VerificationServiceConfig = {
  port: 8080,
  sharedSecret,
  rootCertificates: [Buffer.alloc(256, 1)],
  environment: Environment.SANDBOX,
  bundleId: "jp.nekowidget.app",
  subscriptionGroupId: "20999999",
  productIds: new Set(["jp.nekowidget.plus.monthly", "jp.nekowidget.plus.annual"]),
};

function transaction(): NormalizedBillingTransaction {
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

async function withServer(
  verify: (signedTransactionInfo: string) => Promise<NormalizedBillingTransaction>,
  run: (origin: string) => Promise<void>,
): Promise<void> {
  const server = createBillingVerificationServer(config, { verify });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const port = (server.address() as AddressInfo).port;
  try {
    await run(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => error === undefined ? resolve() : reject(error));
    });
  }
}

async function signedRequest(origin: string, signatureOverride?: string): Promise<{
  nonce: string;
  response: Response;
}> {
  const body = Buffer.from(JSON.stringify({
    protocolVersion: 1,
    signedTransactionInfo: "header.payload.signature",
  }));
  const timestamp = Math.floor(Date.now() / 1_000);
  const nonce = "8PHy8_T19vf4-fr7_P3-_w";
  const signature = signatureOverride ?? signTranscript(
    sharedSecret,
    requestTranscript(timestamp, nonce, bodySHA256(body)),
  );
  return {
    nonce,
    response: await fetch(`${origin}/internal/v1/apple-transactions/verify`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Neko-Billing-Protocol-Version": String(PROTOCOL_VERSION),
        "Neko-Billing-Timestamp": String(timestamp),
        "Neko-Billing-Nonce": nonce,
        "Neko-Billing-Signature": signature,
      },
      body,
    }),
  };
}

test("authenticates the Worker and signs a normalized verifier response", async () => {
  let calls = 0;
  const expected = transaction();
  await withServer(async (jws) => {
    calls += 1;
    assert.equal(jws, "header.payload.signature");
    return expected;
  }, async (origin) => {
    const { nonce, response } = await signedRequest(origin);
    assert.equal(response.status, 200);
    const body = Buffer.from(await response.arrayBuffer());
    const signature = response.headers.get("neko-billing-response-signature") ?? "";
    assert.equal(verifyTranscript(
      sharedSecret,
      signature,
      responseTranscript(nonce, response.status, bodySHA256(body)),
    ), true);
    assert.deepEqual(JSON.parse(body.toString("utf8")), expected);
  });
  assert.equal(calls, 1);
});

test("rejects bad internal authentication before invoking Apple verification", async () => {
  let calls = 0;
  await withServer(async () => {
    calls += 1;
    return transaction();
  }, async (origin) => {
    const { response } = await signedRequest(origin, "A".repeat(43));
    assert.equal(response.status, 401);
    assert.equal(response.headers.get("neko-billing-response-signature"), null);
  });
  assert.equal(calls, 0);
});

test("returns an authenticated retryable error when Apple verification is unavailable", async () => {
  await withServer(async () => {
    throw new RetryableAppleVerificationError();
  }, async (origin) => {
    const { nonce, response } = await signedRequest(origin);
    assert.equal(response.status, 503);
    const body = Buffer.from(await response.arrayBuffer());
    assert.equal(JSON.parse(body.toString("utf8")).error.code,
      "apple_verification_temporarily_unavailable");
    assert.equal(verifyTranscript(
      sharedSecret,
      response.headers.get("neko-billing-response-signature") ?? "",
      responseTranscript(nonce, response.status, bodySHA256(body)),
    ), true);
  });
});
