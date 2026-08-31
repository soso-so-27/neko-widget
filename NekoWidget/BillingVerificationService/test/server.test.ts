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
  SUBSCRIPTION_STATUS_PATH,
  VERIFY_NOTIFICATION_PATH,
  bodySHA256,
  requestTranscript,
  responseTranscript,
  signTranscript,
  verifyTranscript,
} from "../src/internal-auth.js";
import {
  createBillingVerificationServer,
  type BillingAppleServices,
} from "../src/server.js";

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
  serverConfig: VerificationServiceConfig = config,
  services: BillingAppleServices = {},
): Promise<void> {
  const server = createBillingVerificationServer(serverConfig, { verify }, services);
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

async function signedInternalRequest(
  origin: string,
  path: string,
  value: Record<string, unknown>,
): Promise<{ nonce: string; response: Response }> {
  const body = Buffer.from(JSON.stringify(value));
  const timestamp = Math.floor(Date.now() / 1_000);
  const nonce = "4pKv7Kqzb_sLLmA3k6Pn5A";
  return {
    nonce,
    response: await fetch(`${origin}${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Neko-Billing-Protocol-Version": String(PROTOCOL_VERSION),
        "Neko-Billing-Timestamp": String(timestamp),
        "Neko-Billing-Nonce": nonce,
        "Neko-Billing-Signature": signTranscript(
          sharedSecret,
          requestTranscript(timestamp, nonce, bodySHA256(body)),
        ),
      },
      body,
    }),
  };
}

async function assertSignedResponse(
  response: Response,
  nonce: string,
): Promise<unknown> {
  const body = Buffer.from(await response.arrayBuffer());
  assert.equal(verifyTranscript(
    sharedSecret,
    response.headers.get("neko-billing-response-signature") ?? "",
    responseTranscript(nonce, response.status, bodySHA256(body)),
  ), true);
  return JSON.parse(body.toString("utf8"));
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

test("keeps notification and subscription-status endpoints independently gated", async () => {
  let notificationCalls = 0;
  let statusCalls = 0;
  const services: BillingAppleServices = {
    notificationVerifier: {
      async verify() {
        notificationCalls += 1;
        return {
          protocolVersion: 1,
          notificationUUID: "b113ede5-4eba-4e06-8a9d-3b21243041a7",
          notificationType: "TEST",
          subtype: null,
          signedDateMs: Date.now(),
          environment: "Sandbox",
          bundleId: config.bundleId,
          status: null,
          relevant: false,
          transaction: null,
          renewal: null,
        };
      },
    },
    subscriptionStatusService: {
      async get(originalTransactionId) {
        statusCalls += 1;
        const value = transaction();
        return {
          protocolVersion: 1,
          requestedTransactionId: originalTransactionId,
          environment: "Sandbox",
          bundleId: config.bundleId,
          fetchedAtMs: Date.now(),
          items: [{
            status: 1,
            originalTransactionId,
            transaction: value,
            renewal: {
              originalTransactionId,
              billingAccountId: value.billingAccountId,
              productId: value.productId,
              autoRenewProductId: value.productId,
              autoRenewStatus: 1,
              isInBillingRetryPeriod: false,
              gracePeriodExpiresDateMs: null,
              renewalDateMs: value.expiresDateMs,
              signedDateMs: value.signedDateMs,
              environment: "Sandbox",
            },
          }],
        };
      },
    },
  };
  await withServer(async () => transaction(), async (origin) => {
    const disabledNotification = await signedInternalRequest(
      origin,
      VERIFY_NOTIFICATION_PATH,
      { protocolVersion: 1, signedPayload: "header.payload.signature" },
    );
    assert.equal(disabledNotification.response.status, 503);
    await assertSignedResponse(disabledNotification.response, disabledNotification.nonce);
    const disabledStatus = await signedInternalRequest(
      origin,
      SUBSCRIPTION_STATUS_PATH,
      { protocolVersion: 1, originalTransactionId: "200000000000001" },
    );
    assert.equal(disabledStatus.response.status, 503);
    await assertSignedResponse(disabledStatus.response, disabledStatus.nonce);
  }, config, services);
  assert.equal(notificationCalls, 0);
  assert.equal(statusCalls, 0);

  const enabledConfig: VerificationServiceConfig = {
    ...config,
    notificationVerificationEnabled: true,
    subscriptionStatusEnabled: true,
  };
  await withServer(async () => transaction(), async (origin) => {
    const notificationResponse = await signedInternalRequest(
      origin,
      VERIFY_NOTIFICATION_PATH,
      { protocolVersion: 1, signedPayload: "header.payload.signature" },
    );
    assert.equal(notificationResponse.response.status, 200);
    const body = await assertSignedResponse(
      notificationResponse.response,
      notificationResponse.nonce,
    ) as { notificationUUID: string; relevant: boolean };
    assert.equal(body.notificationUUID, "b113ede5-4eba-4e06-8a9d-3b21243041a7");
    assert.equal(body.relevant, false);
  }, enabledConfig, services);
  assert.equal(notificationCalls, 1);
  assert.equal(statusCalls, 0);

  await withServer(async () => transaction(), async (origin) => {
    const statusResponse = await signedInternalRequest(
      origin,
      SUBSCRIPTION_STATUS_PATH,
      { protocolVersion: 1, originalTransactionId: "200000000000001" },
    );
    assert.equal(statusResponse.response.status, 200);
    const body = await assertSignedResponse(statusResponse.response, statusResponse.nonce);
    assert.equal((body as { requestedTransactionId: string }).requestedTransactionId,
      "200000000000001");
  }, enabledConfig, services);
  assert.equal(statusCalls, 1);
});
