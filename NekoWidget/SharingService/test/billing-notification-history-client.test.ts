import { describe, expect, it } from "vitest";

import {
  fetchAppleNotificationHistoryPageViaService,
} from "../src/billing-apple-client";
import {
  AppleNotificationHistoryConfigurationBlockedError,
  AppleNotificationHistoryCursorResetRequiredError,
  AppleNotificationHistoryDisabledError,
  InvalidAppleNotificationHistoryError,
} from "../src/billing-verifier-client";
import {
  BILLING_NOTIFICATION_HISTORY_PATH,
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

const nowMs = Date.now();
const request = {
  startDateMs: nowMs - 60_000,
  endDateMs: nowMs,
  paginationToken: null,
} as const;
const nextCursor = `nh1.fixture.${"A".repeat(43)}`;

function transaction() {
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
    purchaseDateMs: nowMs - 1_000,
    originalPurchaseDateMs: nowMs - 1_000,
    expiresDateMs: nowMs + 2_592_000_000,
    signedDateMs: nowMs,
    revocationDateMs: null,
    revocationReason: null,
    isUpgraded: false,
  };
}

function notification() {
  return {
    protocolVersion: 1,
    notificationUUID: "b113ede5-4eba-4e06-8a9d-3b21243041a7",
    notificationType: "DID_RENEW",
    subtype: null,
    signedDateMs: nowMs,
    environment: "Sandbox",
    bundleId: "jp.nekowidget.app",
    status: 1,
    relevant: true,
    transaction: transaction(),
    renewal: {
      originalTransactionId: "200000000000001",
      billingAccountId: "5f30c0de-0000-4000-8000-000000000001",
      productId: "jp.nekowidget.plus.monthly",
      autoRenewProductId: "jp.nekowidget.plus.monthly",
      autoRenewStatus: 1,
      isInBillingRetryPeriod: false,
      gracePeriodExpiresDateMs: null,
      renewalDateMs: nowMs + 2_592_000_000,
      signedDateMs: nowMs,
      environment: "Sandbox",
    },
  };
}

function page(overrides: Record<string, unknown> = {}) {
  return {
    protocolVersion: 1,
    requestedStartDateMs: request.startDateMs,
    requestedEndDateMs: request.endDateMs,
    environment: "Sandbox",
    bundleId: "jp.nekowidget.app",
    hasMore: true,
    nextPaginationToken: nextCursor,
    records: [{
      payloadHash: "B".repeat(43),
      notification: notification(),
    }],
    ...overrides,
  };
}

interface SignedFetchOptions {
  status?: number;
  corruptSignature?: boolean;
  rawResponseBody?: string;
  expectedRequest?: Record<string, unknown>;
}

function authenticatedFetch(
  responseValue: unknown,
  options: SignedFetchOptions = {},
): typeof fetch {
  return async (input, init) => {
    expect(String(input)).toBe(`http://127.0.0.1:8080${BILLING_NOTIFICATION_HISTORY_PATH}`);
    expect(init?.method).toBe("POST");
    expect(init?.redirect).toBe("error");
    const headers = new Headers(init?.headers);
    expect(headers.get("cf-access-client-id")).toBe("staging-verifier.access");
    expect(headers.get("cf-access-client-secret")).toBe("staging-access-secret");
    const timestamp = Number(headers.get("neko-billing-timestamp"));
    const nonce = headers.get("neko-billing-nonce") ?? "";
    const body = init?.body as Uint8Array;
    expect(JSON.parse(new TextDecoder().decode(body))).toEqual(options.expectedRequest ?? {
      protocolVersion: 1,
      startDateMs: request.startDateMs,
      endDateMs: request.endDateMs,
      paginationToken: null,
    });
    expect(await verifyBillingVerifierTranscript(
      secret,
      headers.get("neko-billing-signature") ?? "",
      billingVerifierRequestTranscript(timestamp, nonce, await bodySHA256(body)),
    )).toBe(true);

    const status = options.status ?? 200;
    const responseBody = new TextEncoder().encode(
      options.rawResponseBody ?? JSON.stringify(responseValue),
    );
    const responseSignature = options.corruptSignature === true
      ? "A".repeat(43)
      : await signBillingVerifierTranscript(
        secret,
        billingVerifierResponseTranscript(nonce, status, await bodySHA256(responseBody)),
      );
    return new Response(responseBody, {
      status,
      headers: { "Neko-Billing-Response-Signature": responseSignature },
    });
  };
}

describe("Worker Apple notification history client", () => {
  it("authenticates both directions and returns only a strictly normalized page", async () => {
    const result = await fetchAppleNotificationHistoryPageViaService(
      request,
      testEnv,
      authenticatedFetch(page()),
    );
    expect(result).toMatchObject({
      requestedStartDateMs: request.startDateMs,
      requestedEndDateMs: request.endDateMs,
      environment: "Sandbox",
      bundleId: "jp.nekowidget.app",
      hasMore: true,
      nextPaginationToken: nextCursor,
    });
    expect(result.records).toHaveLength(1);
    expect(result.records[0]?.payloadHash).toBe("B".repeat(43));
    expect(result.records[0]?.notification.transaction?.billingAccountId)
      .toBe("5f30c0de-0000-4000-8000-000000000001");
    expect(JSON.stringify(result)).not.toContain("signedPayload");

    const continuedRequest = { ...request, paginationToken: nextCursor };
    const finalPage = await fetchAppleNotificationHistoryPageViaService(
      continuedRequest,
      testEnv,
      authenticatedFetch(
        page({ hasMore: false, nextPaginationToken: null }),
        {
          expectedRequest: {
            protocolVersion: 1,
            startDateMs: request.startDateMs,
            endDateMs: request.endDateMs,
            paginationToken: nextCursor,
          },
        },
      ),
    );
    expect(finalPage.hasMore).toBe(false);
    expect(finalPage.nextPaginationToken).toBeNull();

    await expect(fetchAppleNotificationHistoryPageViaService(
      continuedRequest,
      testEnv,
      authenticatedFetch(
        page({ nextPaginationToken: nextCursor }),
        {
          expectedRequest: {
            protocolVersion: 1,
            startDateMs: request.startDateMs,
            endDateMs: request.endDateMs,
            paginationToken: nextCursor,
          },
        },
      ),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response", status: 503 });
  });

  it("rejects raw JWS material, duplicate evidence, and response identity drift", async () => {
    const rawLeak = page({
      records: [{
        payloadHash: "B".repeat(43),
        notification: notification(),
        signedPayload: "header.payload.signature",
      }],
    });
    await expect(fetchAppleNotificationHistoryPageViaService(
      request,
      testEnv,
      authenticatedFetch(rawLeak),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response", status: 503 });

    const duplicateNotification = {
      ...notification(),
      notificationUUID: notification().notificationUUID,
    };
    await expect(fetchAppleNotificationHistoryPageViaService(
      request,
      testEnv,
      authenticatedFetch(page({
        records: [
          { payloadHash: "B".repeat(43), notification: notification() },
          { payloadHash: "C".repeat(43), notification: duplicateNotification },
        ],
      })),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response", status: 503 });

    await expect(fetchAppleNotificationHistoryPageViaService(
      request,
      testEnv,
      authenticatedFetch(page({ requestedEndDateMs: request.endDateMs - 1 })),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response", status: 503 });
  });

  it("preserves signed actionable history failures as typed classifications", async () => {
    const cases = [
      {
        status: 409,
        code: "apple_notification_history_cursor_reset_required",
        type: AppleNotificationHistoryCursorResetRequiredError,
        recovery: "reset-cursor",
      },
      {
        status: 503,
        code: "apple_notification_history_configuration_blocked",
        type: AppleNotificationHistoryConfigurationBlockedError,
        recovery: "operator-action-required",
      },
      {
        status: 503,
        code: "apple_notification_history_disabled",
        type: AppleNotificationHistoryDisabledError,
        recovery: "runtime-enable-required",
      },
      {
        status: 400,
        code: "invalid_apple_notification_history",
        type: InvalidAppleNotificationHistoryError,
        recovery: "reject-window",
      },
    ] as const;
    for (const item of cases) {
      try {
        await fetchAppleNotificationHistoryPageViaService(
          request,
          testEnv,
          authenticatedFetch({ error: { code: item.code } }, { status: item.status }),
        );
        expect.unreachable("history failure must throw");
      } catch (error) {
        expect(error).toBeInstanceOf(item.type);
        expect(error).toMatchObject({
          code: item.code,
          status: item.status,
          recovery: item.recovery,
        });
      }
    }
  });

  it("keeps transient failures retryable but rejects forged or unknown error envelopes", async () => {
    await expect(fetchAppleNotificationHistoryPageViaService(
      request,
      testEnv,
      authenticatedFetch(
        { error: { code: "billing_verifier_busy" } },
        { status: 503 },
      ),
    )).rejects.toMatchObject({ code: "billing_verifier_unavailable", status: 503 });

    await expect(fetchAppleNotificationHistoryPageViaService(
      request,
      testEnv,
      authenticatedFetch(
        { error: { code: "apple_notification_history_cursor_reset_required" } },
        { status: 409, corruptSignature: true },
      ),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response", status: 503 });

    await expect(fetchAppleNotificationHistoryPageViaService(
      request,
      testEnv,
      authenticatedFetch(
        { error: { code: "future_unreviewed_error" } },
        { status: 503 },
      ),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response", status: 503 });

    await expect(fetchAppleNotificationHistoryPageViaService(
      request,
      testEnv,
      authenticatedFetch(
        {},
        {
          status: 409,
          rawResponseBody: "{\"error\":{\"code\":\"apple_notification_history_cursor_reset_required\",\"code\":\"future_unreviewed_error\"}}",
        },
      ),
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response", status: 503 });
  });

  it("maps response stream failures to a closed verifier error", async () => {
    const brokenFetch: typeof fetch = async () => new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("{\"protocolVersion\":"));
        controller.error(new Error("body aborted"));
      },
    }), { status: 200 });
    await expect(fetchAppleNotificationHistoryPageViaService(
      request,
      testEnv,
      brokenFetch,
    )).rejects.toMatchObject({ code: "billing_verifier_invalid_response", status: 503 });
  });

  it("rejects malformed windows and cursors before any verifier call", async () => {
    let fetchCalls = 0;
    const unexpectedFetch: typeof fetch = async () => {
      fetchCalls += 1;
      throw new Error("must not fetch");
    };
    for (const invalidRequest of [
      { ...request, startDateMs: request.endDateMs },
      { ...request, endDateMs: Number.MAX_SAFE_INTEGER + 1 },
    ]) {
      await expect(fetchAppleNotificationHistoryPageViaService(
        invalidRequest,
        testEnv,
        unexpectedFetch,
      )).rejects.toMatchObject({ code: "invalid_apple_notification_history", status: 400 });
    }
    await expect(fetchAppleNotificationHistoryPageViaService(
      { ...request, paginationToken: "raw-apple-token" },
      testEnv,
      unexpectedFetch,
    )).rejects.toMatchObject({
      code: "apple_notification_history_cursor_reset_required",
      recovery: "reset-cursor",
      status: 409,
    });
    expect(fetchCalls).toBe(0);
  });
});
