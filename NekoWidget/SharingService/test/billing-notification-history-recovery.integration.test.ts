import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import {
  type AppleNotificationHistoryPageRequest,
  type VerifiedAppleNotificationHistoryPage,
  type VerifiedAppleNotificationHistoryRecord,
} from "../src/billing-apple-client";
import { ingestVerifiedAppleBillingNotification } from "../src/billing-authority";
import { runAppleNotificationHistoryRecovery } from "../src/billing-notification-history-recovery";
import {
  beginAppleNotificationHistoryRecovery,
  getAppleNotificationHistoryRecoveryState,
} from "../src/billing-notification-history-state";
import {
  AppleNotificationHistoryConfigurationBlockedError,
  AppleNotificationHistoryCursorResetRequiredError,
} from "../src/billing-verifier-client";
import type { Env } from "../src/env";

const testEnv = env as unknown as Env;
const verifierSecret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const nextCursor = `nh1.integration.${"A".repeat(43)}`;

function recoveryEnv(upperEnabled: boolean): Env {
  return {
    DB: testEnv.DB,
    ENVIRONMENT: "local",
    BILLING_APPLE_NOTIFICATION_HISTORY_RECOVERY_RUNTIME_ENABLED:
      upperEnabled ? "YES" : "NO",
    BILLING_VERIFIER_ORIGIN: "http://127.0.0.1:8080",
    BILLING_VERIFIER_SHARED_SECRET: verifierSecret,
    BILLING_BUNDLE_ID: "jp.nekowidget.app",
    BILLING_STORE_ENVIRONMENT: "Sandbox",
    BILLING_SUBSCRIPTION_GROUP_ID: "20999999",
    BILLING_MONTHLY_PRODUCT_ID: "jp.nekowidget.plus.monthly",
    BILLING_ANNUAL_PRODUCT_ID: "jp.nekowidget.plus.annual",
  } as unknown as Env;
}

async function setHistoryLowerGate(enabled: boolean): Promise<void> {
  const row = await testEnv.DB.prepare(
    `SELECT generation, apple_notification_history_recovery_enabled
       FROM billing_runtime_gate WHERE singleton = 1`,
  ).first<{
    generation: number;
    apple_notification_history_recovery_enabled: number;
  }>();
  if (row === null) throw new Error("missing billing runtime gate");
  const target = enabled ? 1 : 0;
  if (row.apple_notification_history_recovery_enabled === target) return;
  const result = await testEnv.DB.prepare(
    `UPDATE billing_runtime_gate
        SET generation = generation + 1,
            apple_notification_history_recovery_enabled = ?,
            updated_at = unixepoch()
      WHERE singleton = 1 AND generation = ?`,
  ).bind(target, row.generation).run();
  if (result.meta.changes !== 1) throw new Error("history lower gate CAS failed");
}

function historyRecord(index: number): VerifiedAppleNotificationHistoryRecord {
  const suffix = String(index).padStart(12, "0");
  return {
    payloadHash: String.fromCharCode(65 + index).repeat(43),
    notification: {
      notificationUUID: `b113ede5-4eba-4e06-8a9d-${suffix}`,
      notificationType: "TEST",
      subtype: null,
      signedDateMs: Date.now(),
      environment: "Sandbox",
      bundleId: "jp.nekowidget.app",
      status: null,
      relevant: false,
      transaction: null,
      renewal: null,
    },
  };
}

function page(
  request: AppleNotificationHistoryPageRequest,
  records: VerifiedAppleNotificationHistoryRecord[],
  hasMore: boolean,
  cursor: string | null,
): VerifiedAppleNotificationHistoryPage {
  return {
    requestedStartDateMs: request.startDateMs,
    requestedEndDateMs: request.endDateMs,
    environment: "Sandbox",
    bundleId: "jp.nekowidget.app",
    hasMore,
    nextPaginationToken: cursor,
    records,
  };
}

describe.sequential("Apple notification history recovery orchestration", () => {
  it("does not fetch while either independent runtime gate is closed", async () => {
    const now = Math.floor(Date.now() / 1_000);
    let fetchCalls = 0;
    const fetchPage = async (): Promise<VerifiedAppleNotificationHistoryPage> => {
      fetchCalls += 1;
      throw new Error("closed gates must stop before fetch");
    };

    await runAppleNotificationHistoryRecovery(recoveryEnv(false), fetchPage, undefined, now, now);
    expect(fetchCalls).toBe(0);

    await setHistoryLowerGate(true);
    await runAppleNotificationHistoryRecovery(recoveryEnv(false), fetchPage, undefined, now, now);
    expect(fetchCalls).toBe(0);

    await setHistoryLowerGate(false);
    await runAppleNotificationHistoryRecovery(recoveryEnv(true), fetchPage, undefined, now, now);
    expect(fetchCalls).toBe(0);
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "idle",
      committedPageCount: 0,
    });
  });

  it("fetches one page per run and carries one frozen interval through pagination", async () => {
    await setHistoryLowerGate(true);
    const now = Math.floor(Date.now() / 1_000);
    const requests: AppleNotificationHistoryPageRequest[] = [];
    const fetchPage = async (
      request: AppleNotificationHistoryPageRequest,
    ): Promise<VerifiedAppleNotificationHistoryPage> => {
      requests.push({ ...request });
      return requests.length === 1
        ? page(request, [], true, nextCursor)
        : page(request, [], false, null);
    };

    await runAppleNotificationHistoryRecovery(
      recoveryEnv(true),
      fetchPage,
      undefined,
      now,
      now,
    );
    expect(requests).toHaveLength(1);
    expect(requests[0]?.paginationToken).toBeNull();
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "ready",
      paginationCursor: nextCursor,
      committedPageCount: 1,
    });

    await runAppleNotificationHistoryRecovery(
      recoveryEnv(true),
      fetchPage,
      undefined,
      now,
      now,
    );
    expect(requests).toHaveLength(2);
    expect(requests[1]).toEqual({
      startDateMs: requests[0]?.startDateMs,
      endDateMs: requests[0]?.endDateMs,
      paginationToken: nextCursor,
    });
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "completed",
      paginationCursor: null,
      committedPageCount: 2,
      committedRecordCount: 0,
    });
  });

  it("retries an unchanged page after partial ingest and replays its durable ledger safely", async () => {
    const now = Math.floor(Date.now() / 1_000) + 900;
    const records = [historyRecord(1), historyRecord(2)];
    const requests: AppleNotificationHistoryPageRequest[] = [];
    const fetchPage = async (
      request: AppleNotificationHistoryPageRequest,
    ): Promise<VerifiedAppleNotificationHistoryPage> => {
      requests.push({ ...request });
      return page(request, records, false, null);
    };
    let failSecondRecord = true;
    const ingestRecord = async (
      value: Env,
      record: VerifiedAppleNotificationHistoryRecord,
    ): Promise<void> => {
      if (record.payloadHash === records[1]?.payloadHash && failSecondRecord) {
        failSecondRecord = false;
        throw new Error("synthetic second-record interruption");
      }
      await ingestVerifiedAppleBillingNotification(
        value,
        record.notification,
        record.payloadHash,
      );
    };

    await runAppleNotificationHistoryRecovery(
      recoveryEnv(true),
      fetchPage,
      ingestRecord,
      now,
      now,
    );
    expect(requests).toHaveLength(1);
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "retry_wait",
      paginationCursor: null,
      committedPageCount: 0,
      committedRecordCount: 0,
      attempts: 1,
      notBefore: now + 30,
    });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_apple_notification_events",
    ).first()).toEqual({ count: 1 });

    await runAppleNotificationHistoryRecovery(
      recoveryEnv(true),
      fetchPage,
      ingestRecord,
      now + 30,
      now + 30,
    );
    expect(requests).toHaveLength(2);
    expect(requests[1]).toEqual(requests[0]);
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "completed",
      paginationCursor: null,
      committedPageCount: 1,
      committedRecordCount: 2,
      attempts: 0,
    });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_apple_notification_events",
    ).first()).toEqual({ count: 2 });
  });

  it("blocks permanent failures and does not retry them", async () => {
    const now = Math.floor(Date.now() / 1_000) + 1_800;
    let fetchCalls = 0;
    const fetchPage = async (): Promise<VerifiedAppleNotificationHistoryPage> => {
      fetchCalls += 1;
      throw new AppleNotificationHistoryConfigurationBlockedError();
    };
    await runAppleNotificationHistoryRecovery(
      recoveryEnv(true),
      fetchPage,
      undefined,
      now,
      now,
    );
    expect(fetchCalls).toBe(1);
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "blocked",
      lastErrorCode: "apple_notification_history_configuration_blocked",
      committedPageCount: 0,
      committedRecordCount: 0,
    });

    await runAppleNotificationHistoryRecovery(
      recoveryEnv(true),
      fetchPage,
      undefined,
      now + 30,
      now + 30,
    );
    expect(fetchCalls).toBe(1);
  });

  it("restarts the same frozen interval three times before blocking cursor reset", async () => {
    const now = Math.floor(Date.now() / 1_000) + 2_700;
    const blocked = await getAppleNotificationHistoryRecoveryState(testEnv);
    const frozenStartDateMs = (now - 3_600) * 1_000;
    const frozenEndDateMs = now * 1_000;
    expect(await beginAppleNotificationHistoryRecovery(testEnv, {
      expectedGeneration: blocked.generation,
      storeEnvironment: "Sandbox",
      bundleId: "jp.nekowidget.app",
      frozenStartDateMs,
      frozenEndDateMs,
    }, now)).toBe(true);

    const requests: AppleNotificationHistoryPageRequest[] = [];
    const fetchPage = async (
      request: AppleNotificationHistoryPageRequest,
    ): Promise<VerifiedAppleNotificationHistoryPage> => {
      requests.push({ ...request });
      throw new AppleNotificationHistoryCursorResetRequiredError();
    };
    for (let attempt = 0; attempt < 4; attempt += 1) {
      await runAppleNotificationHistoryRecovery(
        recoveryEnv(true),
        fetchPage,
        undefined,
        now,
        now,
      );
    }

    expect(requests).toHaveLength(4);
    expect(requests).toEqual(Array.from({ length: 4 }, () => ({
      startDateMs: frozenStartDateMs,
      endDateMs: frozenEndDateMs,
      paginationToken: null,
    })));
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "blocked",
      frozenStartDateMs,
      frozenEndDateMs,
      paginationCursor: null,
      committedPageCount: 0,
      committedRecordCount: 0,
      cursorResetCount: 3,
      lastErrorCode: "apple_notification_history_cursor_reset_exhausted",
    });
  });
});
