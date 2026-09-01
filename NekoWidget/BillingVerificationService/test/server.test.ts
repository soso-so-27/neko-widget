import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import test from "node:test";
import { Environment } from "@apple/app-store-server-library";
import {
  RetryableAppleVerificationError,
  type NormalizedBillingTransaction,
} from "../src/apple-transaction.js";
import {
  AppleNotificationHistoryConfigurationError,
  AppleNotificationHistoryCursorResetRequiredError,
} from "../src/apple-notification-history.js";
import type { VerificationServiceConfig } from "../src/config.js";
import {
  NOTIFICATION_HISTORY_PATH,
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
  BILLING_VERIFIER_HEADERS_TIMEOUT_MS,
  BILLING_VERIFIER_MAX_CONNECTIONS,
  BILLING_VERIFIER_MAX_HEADERS,
  BILLING_VERIFIER_MAX_INFLIGHT,
  BILLING_VERIFIER_MAX_REQUESTS_PER_SOCKET,
  BILLING_VERIFIER_REQUEST_TIMEOUT_MS,
  BILLING_VERIFIER_SOCKET_TIMEOUT_MS,
  createBillingVerificationServer,
  listen,
  type BillingAppleServices,
  type BillingVerifierRuntimeDependencies,
} from "../src/server.js";
import {
  BILLING_VERIFIER_NONCE_RETENTION_SECONDS,
  type BillingVerifierNonceStore,
} from "../src/nonce-store.js";

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

function inMemoryNonceStore(): BillingVerifierNonceStore {
  const claimed = new Set<string>();
  return {
    ready() { return true; },
    async claim(input) {
      const key = `${input.scope}:${input.nonce}`;
      if (claimed.has(key)) return "replayed";
      claimed.add(key);
      return "claimed";
    },
  };
}

function runtimeDependencies(
  nonceStore: BillingVerifierNonceStore = inMemoryNonceStore(),
  overrides: Partial<BillingVerifierRuntimeDependencies> = {},
): BillingVerifierRuntimeDependencies {
  return {
    nonceStore,
    onFatalDependencyTimeout() {},
    ...overrides,
  };
}

let nonceSequence = 0;
function nextNonce(): string {
  nonceSequence += 1;
  const bytes = Buffer.alloc(16);
  bytes.writeUInt32BE(nonceSequence, 12);
  return bytes.toString("base64url");
}

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
  nonceStore: BillingVerifierNonceStore = inMemoryNonceStore(),
  dependencyOverrides: Partial<BillingVerifierRuntimeDependencies> = {},
): Promise<void> {
  const server = createBillingVerificationServer(
    serverConfig,
    runtimeDependencies(nonceStore, dependencyOverrides),
    { verify },
    services,
  );
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
  const nonce = nextNonce();
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
}>;
async function signedRequest(
  origin: string,
  signatureOverride: string | undefined,
  nonceOverride: string,
): Promise<{ nonce: string; response: Response }>;
async function signedRequest(
  origin: string,
  signatureOverride?: string,
  nonceOverride = "8PHy8_T19vf4-fr7_P3-_w",
): Promise<{ nonce: string; response: Response }> {
  const body = Buffer.from(JSON.stringify({
    protocolVersion: 1,
    signedTransactionInfo: "header.payload.signature",
  }));
  const timestamp = Math.floor(Date.now() / 1_000);
  const nonce = nonceOverride;
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

test("claims an authenticated nonce for the full clock-skew window", async () => {
  const claims: Parameters<BillingVerifierNonceStore["claim"]>[0][] = [];
  const nonceStore: BillingVerifierNonceStore = {
    ready() { return true; },
    async claim(input) {
      claims.push(input);
      return "claimed";
    },
  };
  await withServer(async () => transaction(), async (origin) => {
    const { response } = await signedRequest(origin);
    assert.equal(response.status, 200);
  }, config, {}, nonceStore);
  assert.equal(claims.length, 1);
  assert.equal(claims[0]?.scope, "nwb:verifier:v1:Sandbox:jp.nekowidget.app");
  assert.equal(claims[0]?.retentionSeconds, BILLING_VERIFIER_NONCE_RETENTION_SECONDS);
  assert.equal(BILLING_VERIFIER_NONCE_RETENTION_SECONDS, 601);
});

test("rejects a signed replay before invoking Apple twice", async () => {
  let calls = 0;
  await withServer(async () => {
    calls += 1;
    return transaction();
  }, async (origin) => {
    const first = await signedRequest(origin);
    assert.equal(first.response.status, 200);
    const second = await signedRequest(origin);
    assert.equal(second.response.status, 503);
    const body = await assertSignedResponse(second.response, second.nonce) as {
      error: { code: string };
    };
    assert.equal(body.error.code, "billing_verifier_replayed_request");
  });
  assert.equal(calls, 1);
});

test("allows only one concurrent request with the same signed nonce", async () => {
  let calls = 0;
  let release: (() => void) | undefined;
  const blocked = new Promise<void>((resolve) => { release = resolve; });
  await withServer(async () => {
    calls += 1;
    await blocked;
    return transaction();
  }, async (origin) => {
    const firstPromise = signedRequest(origin);
    await new Promise((resolve) => setImmediate(resolve));
    const second = await signedRequest(origin);
    assert.equal(second.response.status, 503);
    const secondBody = await assertSignedResponse(second.response, second.nonce) as {
      error: { code: string };
    };
    assert.equal(secondBody.error.code, "billing_verifier_replayed_request");
    release?.();
    assert.equal((await firstPromise).response.status, 200);
  });
  assert.equal(calls, 1);
});

test("fails closed when the shared nonce store is unavailable", async () => {
  let calls = 0;
  const unavailable: BillingVerifierNonceStore = {
    ready() { return false; },
    async claim() { throw new Error("unavailable"); },
  };
  await withServer(async () => {
    calls += 1;
    return transaction();
  }, async (origin) => {
    const { nonce, response } = await signedRequest(origin);
    assert.equal(response.status, 503);
    const body = await assertSignedResponse(response, nonce) as { error: { code: string } };
    assert.equal(body.error.code, "billing_verifier_nonce_store_unavailable");
  }, config, {}, unavailable);
  assert.equal(calls, 0);
});

test("does not touch the nonce store when authentication fails", async () => {
  let claims = 0;
  const nonceStore: BillingVerifierNonceStore = {
    ready() { return true; },
    async claim() {
      claims += 1;
      return "claimed";
    },
  };
  await withServer(async () => transaction(), async (origin) => {
    const { response } = await signedRequest(origin, "A".repeat(43));
    assert.equal(response.status, 401);
  }, config, {}, nonceStore);
  assert.equal(claims, 0);
});

test("applies bounded HTTP server limits", () => {
  const server = createBillingVerificationServer(
    config,
    runtimeDependencies(),
    { async verify() { return transaction(); } },
  );
  assert.equal(server.headersTimeout, BILLING_VERIFIER_HEADERS_TIMEOUT_MS);
  assert.equal(server.requestTimeout, BILLING_VERIFIER_REQUEST_TIMEOUT_MS);
  assert.equal(server.timeout, BILLING_VERIFIER_SOCKET_TIMEOUT_MS);
  assert.equal(server.maxHeadersCount, BILLING_VERIFIER_MAX_HEADERS);
  assert.equal(server.maxConnections, BILLING_VERIFIER_MAX_CONNECTIONS);
  assert.equal(server.maxRequestsPerSocket, BILLING_VERIFIER_MAX_REQUESTS_PER_SOCKET);
  server.close();
});

test("the executable listener binds only to loopback", async () => {
  const listener = await listen(
    { ...config, port: 0 },
    runtimeDependencies(),
    { async verify() { return transaction(); } },
  );
  try {
    assert.equal(listener.host, "127.0.0.1");
    const response = await fetch(`http://${listener.host}:${listener.port}/health`);
    assert.equal(response.status, 200);
  } finally {
    await listener.close();
  }
});

test("health fails closed while the shared nonce store is not ready", async () => {
  const nonceStore: BillingVerifierNonceStore = {
    ready() { return false; },
    async claim() { throw new Error("unavailable"); },
  };
  const listener = await listen(
    { ...config, port: 0 },
    runtimeDependencies(nonceStore),
    { async verify() { return transaction(); } },
  );
  try {
    const response = await fetch(`http://${listener.host}:${listener.port}/health`);
    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { status: "unavailable", protocolVersion: 1 });
  } finally {
    await listener.close();
  }
});

test("rejects Apple work above the bounded concurrency limit", async () => {
  let calls = 0;
  const releases: (() => void)[] = [];
  await withServer(async () => {
    calls += 1;
    await new Promise<void>((resolve) => { releases.push(resolve); });
    return transaction();
  }, async (origin) => {
    const active = Array.from({ length: BILLING_VERIFIER_MAX_INFLIGHT }, () => (
      signedRequest(origin, undefined, nextNonce())
    ));
    while (calls < BILLING_VERIFIER_MAX_INFLIGHT) {
      await new Promise((resolve) => setImmediate(resolve));
    }
    const overflow = await signedRequest(origin, undefined, nextNonce());
    assert.equal(overflow.response.status, 503);
    const body = await assertSignedResponse(overflow.response, overflow.nonce) as {
      error: { code: string };
    };
    assert.equal(body.error.code, "billing_verifier_busy");
    releases.forEach((release) => release());
    const completed = await Promise.all(active);
    assert.deepEqual(completed.map(({ response }) => response.status), [200, 200, 200, 200]);
  });
  assert.equal(calls, BILLING_VERIFIER_MAX_INFLIGHT);
});

test("marks the instance fatal when an Apple dependency exceeds its hard deadline", async () => {
  let fatalTimeouts = 0;
  await withServer(async () => new Promise<NormalizedBillingTransaction>(() => {}),
    async (origin) => {
      const { nonce, response } = await signedRequest(origin);
      assert.equal(response.status, 503);
      const body = await assertSignedResponse(response, nonce) as { error: { code: string } };
      assert.equal(body.error.code, "apple_verification_temporarily_unavailable");
    },
    config,
    {},
    inMemoryNonceStore(),
    {
      operationTimeoutMs: 10,
      onFatalDependencyTimeout() { fatalTimeouts += 1; },
    });
  assert.equal(fatalTimeouts, 1);
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

test("keeps notification history private, exact, and independently gated", async () => {
  const nowMs = Date.now();
  let calls = 0;
  const services: BillingAppleServices = {
    notificationHistoryService: {
      async get(input) {
        calls += 1;
        return {
          protocolVersion: 1,
          requestedStartDateMs: input.startDateMs,
          requestedEndDateMs: input.endDateMs,
          environment: "Sandbox",
          bundleId: config.bundleId,
          hasMore: true,
          nextPaginationToken: `nh1.fixture.${"A".repeat(43)}`,
          records: [{
            payloadHash: "A".repeat(43),
            notification: {
              protocolVersion: 1,
              notificationUUID: "b113ede5-4eba-4e06-8a9d-3b21243041a7",
              notificationType: "TEST",
              subtype: null,
              signedDateMs: nowMs,
              environment: "Sandbox",
              bundleId: config.bundleId,
              status: null,
              relevant: false,
              transaction: null,
              renewal: null,
            },
          }],
        };
      },
    },
  };
  const value = {
    protocolVersion: 1,
    startDateMs: nowMs - 60_000,
    endDateMs: nowMs,
    paginationToken: null,
  };

  await withServer(async () => transaction(), async (origin) => {
    const disabled = await signedInternalRequest(origin, NOTIFICATION_HISTORY_PATH, value);
    assert.equal(disabled.response.status, 503);
    const body = await assertSignedResponse(disabled.response, disabled.nonce) as {
      error: { code: string };
    };
    assert.equal(body.error.code, "apple_notification_history_disabled");
  }, config, services);
  assert.equal(calls, 0);

  const enabledConfig: VerificationServiceConfig = {
    ...config,
    notificationHistoryEnabled: true,
  };
  await withServer(async () => transaction(), async (origin) => {
    const unauthorized = await fetch(`${origin}${NOTIFICATION_HISTORY_PATH}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(value),
    });
    assert.equal(unauthorized.status, 401);
    assert.equal(unauthorized.headers.get("neko-billing-response-signature"), null);
    assert.equal(calls, 0);

    const malformed = await signedInternalRequest(origin, NOTIFICATION_HISTORY_PATH, {
      ...value,
      onlyFailures: true,
    });
    assert.equal(malformed.response.status, 400);
    const malformedBody = await assertSignedResponse(malformed.response, malformed.nonce) as {
      error: { code: string };
    };
    assert.equal(malformedBody.error.code, "invalid_apple_notification_history");
    assert.equal(calls, 0);

    const result = await signedInternalRequest(origin, NOTIFICATION_HISTORY_PATH, value);
    assert.equal(result.response.status, 200);
    const body = await assertSignedResponse(result.response, result.nonce) as {
      nextPaginationToken: string;
      records: { payloadHash: string; notification: { notificationUUID: string } }[];
    };
    assert.match(body.nextPaginationToken, /^nh1\./u);
    assert.equal(body.nextPaginationToken.includes("next-page-token"), false);
    assert.equal(body.records[0]?.payloadHash, "A".repeat(43));
    assert.equal(body.records[0]?.notification.notificationUUID,
      "b113ede5-4eba-4e06-8a9d-3b21243041a7");
  }, enabledConfig, services);
  assert.equal(calls, 1);
});

test("returns signed, actionable notification history recovery errors", async () => {
  const nowMs = Date.now();
  const value = {
    protocolVersion: 1,
    startDateMs: nowMs - 60_000,
    endDateMs: nowMs,
    paginationToken: "cursor",
  };
  const enabledConfig: VerificationServiceConfig = {
    ...config,
    notificationHistoryEnabled: true,
  };
  const cases = [
    {
      error: new AppleNotificationHistoryCursorResetRequiredError(),
      status: 409,
      code: "apple_notification_history_cursor_reset_required",
    },
    {
      error: new AppleNotificationHistoryConfigurationError(),
      status: 503,
      code: "apple_notification_history_configuration_blocked",
    },
  ];

  for (const item of cases) {
    const services: BillingAppleServices = {
      notificationHistoryService: {
        async get() { throw item.error; },
      },
    };
    await withServer(async () => transaction(), async (origin) => {
      const result = await signedInternalRequest(origin, NOTIFICATION_HISTORY_PATH, value);
      assert.equal(result.response.status, item.status);
      const body = await assertSignedResponse(result.response, result.nonce) as {
        error: { code: string };
      };
      assert.equal(body.error.code, item.code);
    }, enabledConfig, services);
  }
});
