import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import {
  APIError,
  APIException,
  Environment,
  type NotificationHistoryResponse,
} from "@apple/app-store-server-library";
import {
  AppleNotificationHistoryConfigurationError,
  AppleNotificationHistoryCursorResetRequiredError,
  AppleNotificationHistoryService,
  InvalidAppleNotificationHistoryError,
  RetryableAppleNotificationHistoryError,
  type AppleNotificationHistoryProvider,
} from "../src/apple-notification-history.js";
import type { NormalizedAppleNotification } from "../src/apple-notification.js";
import type { VerificationServiceConfig } from "../src/config.js";

const config: VerificationServiceConfig = {
  port: 8080,
  sharedSecret: Buffer.alloc(32, 1),
  rootCertificates: [Buffer.alloc(256, 1)],
  environment: Environment.SANDBOX,
  bundleId: "jp.nekowidget.app",
  subscriptionGroupId: "20999999",
  productIds: new Set(["jp.nekowidget.plus.monthly", "jp.nekowidget.plus.annual"]),
};

function notification(
  notificationUUID = "b113ede5-4eba-4e06-8a9d-3b21243041a7",
  environment: "Sandbox" | "Production" = "Sandbox",
): NormalizedAppleNotification {
  return {
    protocolVersion: 1,
    notificationUUID,
    notificationType: "TEST",
    subtype: null,
    signedDateMs: Date.now(),
    environment,
    bundleId: config.bundleId,
    status: null,
    relevant: false,
    transaction: null,
    renewal: null,
  };
}

function provider(response: NotificationHistoryResponse): AppleNotificationHistoryProvider {
  return { async getNotificationHistory() { return response; } };
}

test("fetches one unfiltered page and returns only normalized notifications and hashes", async () => {
  const nowMs = Date.now();
  const signedPayload = "header.payload.signature";
  let capturedToken: string | null | undefined;
  let capturedRequest: unknown;
  const historyProvider: AppleNotificationHistoryProvider = {
    async getNotificationHistory(token, request) {
      capturedToken = token;
      capturedRequest = request;
      return {
        paginationToken: "next-page-token",
        hasMore: true,
        notificationHistory: [{
          signedPayload,
          sendAttempts: [{ attemptDate: nowMs, sendAttemptResult: "SUCCESS" }],
        }],
      };
    },
  };
  const verified = notification();
  const service = new AppleNotificationHistoryService(
    config,
    { async verify(value) { assert.equal(value, signedPayload); return verified; } },
    historyProvider,
  );
  const page = await service.get({
    startDateMs: nowMs - 60_000,
    endDateMs: nowMs,
    paginationToken: null,
  }, nowMs);

  assert.equal(capturedToken, null);
  assert.deepEqual(capturedRequest, { startDate: nowMs - 60_000, endDate: nowMs });
  assert.equal(Object.hasOwn(capturedRequest as object, "onlyFailures"), false);
  assert.match(page.nextPaginationToken ?? "", /^nh1\./u);
  assert.equal(page.nextPaginationToken?.includes("next-page-token"), false);
  assert.equal(page.records.length, 1);
  assert.equal(page.records[0]?.payloadHash,
    createHash("sha256").update(signedPayload, "ascii").digest("base64url"));
  assert.deepEqual(page.records[0]?.notification, verified);
  const serialized = JSON.stringify(page);
  assert.equal(serialized.includes(signedPayload), false);
  assert.equal(serialized.includes("sendAttempts"), false);

  await service.get({
    startDateMs: nowMs - 60_000,
    endDateMs: nowMs,
    paginationToken: page.nextPaginationToken,
  }, nowMs);
  assert.equal(capturedToken, "next-page-token");
});

test("binds each pagination cursor to its original period and app identity", async () => {
  const nowMs = Date.now();
  let calls = 0;
  const service = new AppleNotificationHistoryService(
    config,
    { async verify() { return notification(); } },
    {
      async getNotificationHistory() {
        calls += 1;
        return {
          hasMore: true,
          paginationToken: "apple-next-token",
          notificationHistory: [],
        };
      },
    },
  );
  const first = await service.get({
    startDateMs: nowMs - 60_000,
    endDateMs: nowMs,
    paginationToken: null,
  }, nowMs);
  assert.equal(calls, 1);
  assert.notEqual(first.nextPaginationToken, null);

  for (const input of [
    {
      startDateMs: nowMs - 60_001,
      endDateMs: nowMs,
      paginationToken: first.nextPaginationToken,
    },
    {
      startDateMs: nowMs - 60_000,
      endDateMs: nowMs - 1,
      paginationToken: first.nextPaginationToken,
    },
    {
      startDateMs: nowMs - 60_000,
      endDateMs: nowMs,
      paginationToken: `${first.nextPaginationToken?.slice(0, -1)}A`,
    },
  ]) {
    await assert.rejects(
      () => service.get(input, nowMs),
      AppleNotificationHistoryCursorResetRequiredError,
    );
  }
  assert.equal(calls, 1);

  const otherApp = new AppleNotificationHistoryService(
    { ...config, bundleId: "jp.nekowidget.other" },
    { async verify() { return notification(); } },
    {
      async getNotificationHistory() {
        calls += 1;
        return { hasMore: false, notificationHistory: [] };
      },
    },
  );
  await assert.rejects(
    () => otherApp.get({
      startDateMs: nowMs - 60_000,
      endDateMs: nowMs,
      paginationToken: first.nextPaginationToken,
    }, nowMs),
    AppleNotificationHistoryCursorResetRequiredError,
  );
  assert.equal(calls, 1);
});

test("rejects unknown response and item fields without relying on the library validator", async () => {
  const nowMs = Date.now();
  const input = { startDateMs: nowMs - 60_000, endDateMs: nowMs, paginationToken: null };
  const verifier = { async verify() { return notification(); } };
  const extraTopLevel = new AppleNotificationHistoryService(config, verifier, provider({
    hasMore: false,
    notificationHistory: [],
    unexpected: true,
  } as NotificationHistoryResponse));
  await assert.rejects(() => extraTopLevel.get(input, nowMs),
    InvalidAppleNotificationHistoryError);

  const invalidItem = new AppleNotificationHistoryService(config, verifier, provider({
    hasMore: false,
    notificationHistory: [{ signedPayload: 7, unexpected: true } as never],
  }));
  await assert.rejects(() => invalidItem.get(input, nowMs),
    InvalidAppleNotificationHistoryError);

  const missingNextToken = new AppleNotificationHistoryService(config, verifier, provider({
    hasMore: true,
    notificationHistory: [],
  }));
  await assert.rejects(() => missingNextToken.get(input, nowMs),
    InvalidAppleNotificationHistoryError);

  const oversizedPage = new AppleNotificationHistoryService(config, verifier, provider({
    hasMore: false,
    notificationHistory: Array.from({ length: 21 }, (_, index) => ({
      signedPayload: `header.payload${index}.signature`,
    })),
  }));
  await assert.rejects(() => oversizedPage.get(input, nowMs),
    InvalidAppleNotificationHistoryError);
});

test("validates Sandbox retention and future bounds before calling Apple", async () => {
  const nowMs = Date.now();
  let calls = 0;
  const historyProvider: AppleNotificationHistoryProvider = {
    async getNotificationHistory() {
      calls += 1;
      return { hasMore: false, notificationHistory: [] };
    },
  };
  const service = new AppleNotificationHistoryService(
    config,
    { async verify() { return notification(); } },
    historyProvider,
  );
  await assert.rejects(() => service.get({
    startDateMs: nowMs - (30 * 24 * 60 * 60 * 1_000) - 1,
    endDateMs: nowMs,
    paginationToken: null,
  }, nowMs), InvalidAppleNotificationHistoryError);
  await assert.rejects(() => service.get({
    startDateMs: nowMs - 1_000,
    endDateMs: nowMs + (5 * 60 * 1_000) + 1,
    paginationToken: null,
  }, nowMs), InvalidAppleNotificationHistoryError);
  assert.equal(calls, 0);
});

test("uses the Production 180-day history window", async () => {
  const nowMs = Date.now();
  let calls = 0;
  const productionConfig: VerificationServiceConfig = {
    ...config,
    environment: Environment.PRODUCTION,
    appAppleId: 6_801_962_436,
  };
  const service = new AppleNotificationHistoryService(
    productionConfig,
    { async verify() { return notification(undefined, "Production"); } },
    {
      async getNotificationHistory() {
        calls += 1;
        return { hasMore: false, notificationHistory: [] };
      },
    },
  );
  await service.get({
    startDateMs: nowMs - (31 * 24 * 60 * 60 * 1_000),
    endDateMs: nowMs,
    paginationToken: null,
  }, nowMs);
  await assert.rejects(() => service.get({
    startDateMs: nowMs - (180 * 24 * 60 * 60 * 1_000) - 1,
    endDateMs: nowMs,
    paginationToken: null,
  }, nowMs), InvalidAppleNotificationHistoryError);
  assert.equal(calls, 1);
});

test("rejects a verified notification from another environment", async () => {
  const nowMs = Date.now();
  const service = new AppleNotificationHistoryService(
    config,
    { async verify() { return notification(undefined, "Production"); } },
    provider({
      hasMore: false,
      notificationHistory: [{ signedPayload: "header.payload.signature" }],
    }),
  );
  await assert.rejects(() => service.get({
    startDateMs: nowMs - 60_000,
    endDateMs: nowMs,
    paginationToken: null,
  }, nowMs), InvalidAppleNotificationHistoryError);
});

test("rejects duplicate payload hashes and notification UUIDs within a page", async () => {
  const nowMs = Date.now();
  const input = { startDateMs: nowMs - 60_000, endDateMs: nowMs, paginationToken: null };
  const duplicatePayload = new AppleNotificationHistoryService(
    config,
    { async verify() { return notification(); } },
    provider({
      hasMore: false,
      notificationHistory: [
        { signedPayload: "same.payload.signature" },
        { signedPayload: "same.payload.signature" },
      ],
    }),
  );
  await assert.rejects(() => duplicatePayload.get(input, nowMs),
    InvalidAppleNotificationHistoryError);

  const duplicateUUID = new AppleNotificationHistoryService(
    config,
    { async verify() { return notification(); } },
    provider({
      hasMore: false,
      notificationHistory: [
        { signedPayload: "first.payload.signature" },
        { signedPayload: "second.payload.signature" },
      ],
    }),
  );
  await assert.rejects(() => duplicateUUID.get(input, nowMs),
    InvalidAppleNotificationHistoryError);
});

test("classifies Apple history API failures for safe cursor recovery", async () => {
  const nowMs = Date.now();
  const input = { startDateMs: nowMs - 60_000, endDateMs: nowMs, paginationToken: null };
  const serviceFor = (error: APIException) => new AppleNotificationHistoryService(
    config,
    { async verify() { return notification(); } },
    { async getNotificationHistory() { throw error; } },
  );

  for (const apiError of [
    APIError.INVALID_PAGINATION_TOKEN,
    APIError.PAGINATION_TOKEN_EXPIRED,
  ]) {
    await assert.rejects(
      () => serviceFor(new APIException(400, apiError)).get(input, nowMs),
      AppleNotificationHistoryCursorResetRequiredError,
    );
  }
  for (const status of [401, 403, 404]) {
    await assert.rejects(
      () => serviceFor(new APIException(status)).get(input, nowMs),
      AppleNotificationHistoryConfigurationError,
    );
  }
  await assert.rejects(
    () => serviceFor(new APIException(400, APIError.START_DATE_TOO_FAR_IN_PAST))
      .get(input, nowMs),
    InvalidAppleNotificationHistoryError,
  );
  for (const status of [429, 500]) {
    await assert.rejects(
      () => serviceFor(new APIException(status)).get(input, nowMs),
      RetryableAppleNotificationHistoryError,
    );
  }
});
