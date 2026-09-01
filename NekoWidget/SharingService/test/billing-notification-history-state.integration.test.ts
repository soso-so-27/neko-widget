import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import {
  appleNotificationReconciliationCauseStatement,
  ensureAppleNotificationReconciliationCause,
} from "../src/billing-notification-reconciliation-cause";
import {
  beginAppleNotificationHistoryRecovery,
  blockAppleNotificationHistoryRecovery,
  claimAppleNotificationHistoryRecovery,
  commitAppleNotificationHistoryPage,
  getAppleNotificationHistoryRecoveryState,
  resetAppleNotificationHistoryCursor,
  retryAppleNotificationHistoryRecovery,
  type AppleNotificationHistoryRecoveryClaim,
} from "../src/billing-notification-history-state";
import { base64urlEncode } from "../src/encoding";
import type { Env } from "../src/env";

const testEnv = env as unknown as Env;

function randomBase64url(bytes: number): string {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64urlEncode(value);
}

async function setHistoryGate(enabled: boolean): Promise<number> {
  const row = await testEnv.DB.prepare(
    `SELECT generation, apple_notification_history_recovery_enabled
       FROM billing_runtime_gate WHERE singleton = 1`,
  ).first<{ generation: number; apple_notification_history_recovery_enabled: number }>();
  if (row === null) throw new Error("missing billing runtime gate");
  const target = enabled ? 1 : 0;
  if (row.apple_notification_history_recovery_enabled === target) return row.generation;
  const changed = await testEnv.DB.prepare(
    `UPDATE billing_runtime_gate
        SET generation = generation + 1,
            apple_notification_history_recovery_enabled = ?,
            updated_at = unixepoch()
      WHERE singleton = 1 AND generation = ?`,
  ).bind(target, row.generation).run();
  if (changed.meta.changes !== 1) throw new Error("history gate CAS failed");
  return row.generation + 1;
}

async function seedLineage(
  billingAccountId: string,
  originalTransactionId: string,
  storeEnvironment: "Sandbox" | "Production" = "Sandbox",
  subscriptionGroupId = "20999999",
): Promise<void> {
  await testEnv.DB.batch([
    testEnv.DB.prepare(
      "INSERT OR IGNORE INTO billing_accounts(id) VALUES (?)",
    ).bind(billingAccountId),
    testEnv.DB.prepare(
      `INSERT INTO billing_transaction_lineages(
         original_transaction_id, billing_account_id, environment,
         subscription_group_id
       ) VALUES (?, ?, ?, ?)`,
    ).bind(
      originalTransactionId,
      billingAccountId,
      storeEnvironment,
      subscriptionGroupId,
    ),
  ]);
}

function transactionEventStatement(
  billingAccountId: string,
  originalTransactionId: string,
  storeEnvironment: "Sandbox" | "Production" = "Sandbox",
  subscriptionGroupId = "20999999",
): D1PreparedStatement {
  const nowMs = Date.now();
  return testEnv.DB.prepare(
    `INSERT INTO billing_transaction_events(
       event_fingerprint, transaction_id, original_transaction_id,
       billing_account_id, submitted_by_billing_key_id, source,
       product_id, subscription_group_id, environment, ownership_type,
       transaction_reason, purchase_date_ms, original_purchase_date_ms,
       expires_date_ms, signed_date_ms, revocation_date_ms,
       revocation_reason, is_upgraded
     ) VALUES (?, ?, ?, ?, NULL, 'apple_notification',
       'jp.nekowidget.plus.monthly', ?, ?, 'PURCHASED', 'RENEWAL',
       ?, ?, ?, ?, NULL, NULL, 0)`,
  ).bind(
    randomBase64url(32),
    originalTransactionId,
    originalTransactionId,
    billingAccountId,
    subscriptionGroupId,
    storeEnvironment,
    nowMs - 1_000,
    nowMs - 1_000,
    nowMs + 86_400_000,
    nowMs,
  );
}

function notificationEventStatement(
  notificationUUID: string,
  originalTransactionId: string,
  billingAccountId: string,
  relevance: "linked" | "unmatched" = "linked",
  payloadHash = randomBase64url(32),
  signedDateMs = Date.now(),
): D1PreparedStatement {
  return testEnv.DB.prepare(
    `INSERT INTO billing_apple_notification_events(
       notification_uuid, payload_hash, notification_type, subtype,
       signed_date_ms, environment, apple_status, relevance,
       transaction_id, original_transaction_id, billing_account_id
     ) VALUES (?, ?, 'DID_RENEW', NULL, ?, 'Sandbox', 1, ?, ?, ?, ?)`,
  ).bind(
    notificationUUID,
    payloadHash,
    signedDateMs,
    relevance,
    originalTransactionId,
    originalTransactionId,
    billingAccountId,
  );
}

function ignoredNotificationEventStatement(
  notificationUUID: string,
  payloadHash: string,
  storeEnvironment: "Sandbox" | "Production",
  signedDateMs: number,
): D1PreparedStatement {
  return testEnv.DB.prepare(
    `INSERT INTO billing_apple_notification_events(
       notification_uuid, payload_hash, notification_type, subtype,
       signed_date_ms, environment, apple_status, relevance,
       transaction_id, original_transaction_id, billing_account_id
     ) VALUES (?, ?, 'TEST', NULL, ?, ?, NULL, 'ignored', NULL, NULL, NULL)`,
  ).bind(notificationUUID, payloadHash, signedDateMs, storeEnvironment);
}

describe.sequential("Apple notification history durable recovery state", () => {
  it("starts closed and queues each immutable notification cause exactly once", async () => {
    expect(await testEnv.DB.prepare(
      `SELECT apple_notification_history_recovery_enabled
         FROM billing_runtime_gate WHERE singleton = 1`,
    ).first()).toEqual({ apple_notification_history_recovery_enabled: 0 });
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      generation: 0,
      state: "idle",
      paginationCursor: null,
      leaseToken: null,
      claimedGateGeneration: null,
    });

    const account = "17b8ac72-0000-4000-8000-000000000101";
    const original = "220000000000101";
    const uuid = "21b3d5f7-1234-4abc-8def-123456789101";
    await seedLineage(account, original);
    await transactionEventStatement(account, original).run();
    await notificationEventStatement(uuid, original, account).run();

    expect(await ensureAppleNotificationReconciliationCause(
      testEnv,
      uuid,
      original,
    )).toBe(true);
    const queued = await testEnv.DB.prepare(
      `SELECT request_generation
         FROM billing_reconciliation_jobs WHERE original_transaction_id = ?`,
    ).bind(original).first<{ request_generation: number }>();
    expect(queued).toEqual({ request_generation: 1 });

    expect(await ensureAppleNotificationReconciliationCause(
      testEnv,
      uuid,
      original,
    )).toBe(false);
    expect(await testEnv.DB.prepare(
      `SELECT request_generation
         FROM billing_reconciliation_jobs WHERE original_transaction_id = ?`,
    ).bind(original).first()).toEqual({ request_generation: 1 });

    // An event that was initially unmatched may add its cause only after its
    // normalized lineage becomes available; the event itself remains immutable.
    const unmatchedAccount = "17b8ac72-0000-4000-8000-000000000102";
    const unmatchedOriginal = "220000000000102";
    const unmatchedUUID = "21b3d5f7-1234-4abc-8def-123456789102";
    await notificationEventStatement(
      unmatchedUUID,
      unmatchedOriginal,
      unmatchedAccount,
      "unmatched",
    ).run();
    await expect(ensureAppleNotificationReconciliationCause(
      testEnv,
      unmatchedUUID,
      unmatchedOriginal,
    )).rejects.toThrow();
    await seedLineage(unmatchedAccount, unmatchedOriginal);
    await expect(ensureAppleNotificationReconciliationCause(
      testEnv,
      unmatchedUUID,
      unmatchedOriginal,
    )).rejects.toThrow();
    await transactionEventStatement(unmatchedAccount, unmatchedOriginal).run();
    expect(await ensureAppleNotificationReconciliationCause(
      testEnv,
      unmatchedUUID,
      unmatchedOriginal,
    )).toBe(true);
    await expect(ensureAppleNotificationReconciliationCause(
      testEnv,
      uuid,
      unmatchedOriginal,
    )).rejects.toThrow();

    const conflictEventAccount = "17b8ac72-0000-4000-8000-000000000105";
    const conflictLineageAccount = conflictEventAccount;
    const conflictOriginal = "220000000000105";
    const conflictUUID = "21b3d5f7-1234-4abc-8def-123456789105";
    await notificationEventStatement(
      conflictUUID,
      conflictOriginal,
      conflictEventAccount,
      "unmatched",
    ).run();
    await seedLineage(
      conflictLineageAccount,
      conflictOriginal,
      "Sandbox",
      "other.subscription.group",
    );
    await expect(ensureAppleNotificationReconciliationCause(
      testEnv,
      conflictUUID,
      conflictOriginal,
    )).rejects.toThrow();

    await expect(testEnv.DB.prepare(
      `UPDATE billing_apple_notification_reconciliation_causes
          SET requested_at = requested_at + 1 WHERE notification_uuid = ?`,
    ).bind(uuid).run()).rejects.toThrow();
    await expect(testEnv.DB.prepare(
      "DELETE FROM billing_apple_notification_reconciliation_causes WHERE notification_uuid = ?",
    ).bind(uuid).run()).rejects.toThrow();
  });

  it("atomically commits normalized page writes before advancing the opaque cursor", async () => {
    const now = Math.floor(Date.now() / 1_000);
    const frozenStart = (now - 3_600) * 1_000;
    const frozenEnd = now * 1_000;
    expect(await beginAppleNotificationHistoryRecovery(testEnv, {
      expectedGeneration: 0,
      storeEnvironment: "Sandbox",
      bundleId: "jp.nekowidget.app",
      frozenStartDateMs: frozenStart,
      frozenEndDateMs: frozenEnd,
    }, now)).toBe(true);
    expect(await claimAppleNotificationHistoryRecovery(testEnv, now)).toBeNull();
    const gateGeneration = await setHistoryGate(true);

    const firstClaim = await claimAppleNotificationHistoryRecovery(testEnv, now);
    expect(firstClaim).not.toBeNull();
    expect(firstClaim).toMatchObject({
      generation: 1,
      gateGeneration,
      frozenStartDateMs: frozenStart,
      frozenEndDateMs: frozenEnd,
      paginationCursor: null,
      nextPageIndex: 1,
    });

    const account = "17b8ac72-0000-4000-8000-000000000103";
    const original = "220000000000103";
    const uuid = "21b3d5f7-1234-4abc-8def-123456789103";
    await seedLineage(account, original);
    await transactionEventStatement(account, original).run();
    const nextCursor = "nh1.opaque-verifier-bound-page.two-signature";
    const payloadHash = randomBase64url(32);
    await expect(commitAppleNotificationHistoryPage(testEnv, firstClaim!, {
      hasMore: true,
      nextPaginationCursor: nextCursor,
      records: [{ notificationUUID: uuid, payloadHash }],
    }, now)).rejects.toThrow();
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count
         FROM billing_apple_notification_history_page_commits WHERE generation = 1`,
    ).first()).toEqual({ count: 0 });

    const outOfWindowUUID = "21b3d5f7-1234-4abc-8def-123456789107";
    const outOfWindowHash = randomBase64url(32);
    await testEnv.DB.batch([
      notificationEventStatement(
        outOfWindowUUID,
        original,
        account,
        "linked",
        outOfWindowHash,
        frozenStart - 1,
      ),
      appleNotificationReconciliationCauseStatement(
        testEnv,
        outOfWindowUUID,
        original,
      ),
    ]);
    await expect(commitAppleNotificationHistoryPage(testEnv, firstClaim!, {
      hasMore: true,
      nextPaginationCursor: nextCursor,
      records: [{ notificationUUID: outOfWindowUUID, payloadHash: outOfWindowHash }],
    }, now)).rejects.toThrow();

    const wrongEnvironmentUUID = "21b3d5f7-1234-4abc-8def-123456789108";
    const wrongEnvironmentHash = randomBase64url(32);
    await ignoredNotificationEventStatement(
      wrongEnvironmentUUID,
      wrongEnvironmentHash,
      "Production",
      frozenEnd - 1,
    ).run();
    await expect(commitAppleNotificationHistoryPage(testEnv, firstClaim!, {
      hasMore: true,
      nextPaginationCursor: nextCursor,
      records: [{ notificationUUID: wrongEnvironmentUUID, payloadHash: wrongEnvironmentHash }],
    }, now)).rejects.toThrow();

    await testEnv.DB.batch([
      notificationEventStatement(
        uuid,
        original,
        account,
        "linked",
        payloadHash,
        frozenEnd - 1,
      ),
      appleNotificationReconciliationCauseStatement(testEnv, uuid, original),
    ]);
    await commitAppleNotificationHistoryPage(testEnv, firstClaim!, {
      hasMore: true,
      nextPaginationCursor: nextCursor,
      records: [{ notificationUUID: uuid, payloadHash }],
    }, now);

    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "ready",
      generation: 1,
      paginationCursor: nextCursor,
      committedPageCount: 1,
      committedRecordCount: 1,
      leaseToken: null,
      claimedGateGeneration: null,
    });
    expect(await testEnv.DB.prepare(
      `SELECT request_generation
         FROM billing_reconciliation_jobs WHERE original_transaction_id = ?`,
    ).bind(original).first()).toEqual({ request_generation: 2 });

    const secondClaim = await claimAppleNotificationHistoryRecovery(testEnv, now);
    expect(secondClaim).toMatchObject({ paginationCursor: nextCursor, nextPageIndex: 2 });
    await expect(commitAppleNotificationHistoryPage(testEnv, secondClaim!, {
      hasMore: true,
      nextPaginationCursor: nextCursor,
      records: [],
    }, now)).rejects.toThrow();
    const thirdCursor = "nh1.opaque-verifier-bound-page.three-signature";
    await commitAppleNotificationHistoryPage(testEnv, secondClaim!, {
      hasMore: true,
      nextPaginationCursor: thirdCursor,
      records: [],
    }, now);
    const thirdClaim = await claimAppleNotificationHistoryRecovery(testEnv, now);
    expect(thirdClaim).toMatchObject({ paginationCursor: thirdCursor, nextPageIndex: 3 });
    await expect(commitAppleNotificationHistoryPage(testEnv, thirdClaim!, {
      hasMore: true,
      nextPaginationCursor: nextCursor,
      records: [],
    }, now)).rejects.toThrow();
    await commitAppleNotificationHistoryPage(testEnv, thirdClaim!, {
      hasMore: false,
      nextPaginationCursor: null,
      records: [],
    }, now);
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "completed",
      paginationCursor: null,
      committedPageCount: 3,
      committedRecordCount: 1,
      completedAt: now,
    });
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_apple_notification_history_page_finalizations",
    ).first()).toEqual({ count: 3 });

    const audits = await testEnv.DB.prepare(
      "SELECT * FROM billing_apple_notification_history_page_commits ORDER BY page_index",
    ).all<Record<string, unknown>>();
    expect(JSON.stringify(audits.results)).not.toContain(nextCursor);
    for (const table of [
      "billing_apple_notification_history_recovery",
      "billing_apple_notification_history_page_commits",
      "billing_apple_notification_history_page_records",
      "billing_apple_notification_history_page_finalizations",
      "billing_apple_notification_reconciliation_causes",
    ]) {
      const columns = await testEnv.DB.prepare(
        `PRAGMA table_info(${table})`,
      ).all<{ name: string }>();
      expect(columns.results.map((column) => column.name).join(" "))
        .not.toMatch(/raw_jws|signed_payload|signed_transaction|signed_renewal/iu);
    }
  });

  it("rolls back page data on a gate-generation change and bounds cursor restarts", async () => {
    const now = Math.floor(Date.now() / 1_000);
    const completed = await getAppleNotificationHistoryRecoveryState(testEnv);
    expect(await beginAppleNotificationHistoryRecovery(testEnv, {
      expectedGeneration: completed.generation,
      storeEnvironment: "Sandbox",
      bundleId: "jp.nekowidget.app",
      frozenStartDateMs: (now - 7_200) * 1_000,
      frozenEndDateMs: now * 1_000,
    }, now)).toBe(true);
    const staleGateClaim = await claimAppleNotificationHistoryRecovery(testEnv, now);
    expect(staleGateClaim).not.toBeNull();

    await setHistoryGate(false);
    await setHistoryGate(true);
    const account = "17b8ac72-0000-4000-8000-000000000104";
    const original = "220000000000104";
    const uuid = "21b3d5f7-1234-4abc-8def-123456789104";
    await seedLineage(account, original);
    const payloadHash = randomBase64url(32);
    await notificationEventStatement(
      uuid,
      original,
      account,
      "linked",
      payloadHash,
      now * 1_000 - 1,
    ).run();
    await expect(commitAppleNotificationHistoryPage(testEnv, staleGateClaim!, {
      hasMore: false,
      nextPaginationCursor: null,
      records: [{ notificationUUID: uuid, payloadHash }],
    }, now)).rejects.toThrow();
    expect(await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_apple_notification_events WHERE notification_uuid = ?",
    ).bind(uuid).first()).toEqual({ count: 1 });
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count
         FROM billing_apple_notification_history_page_commits WHERE generation = ?`,
    ).bind(staleGateClaim!.generation).first()).toEqual({ count: 0 });
    expect(await testEnv.DB.prepare(
      `SELECT COUNT(*) AS count
         FROM billing_apple_notification_history_page_records WHERE generation = ?`,
    ).bind(staleGateClaim!.generation).first()).toEqual({ count: 0 });

    expect(await retryAppleNotificationHistoryRecovery(
      testEnv,
      staleGateClaim!,
      "gate_generation_changed",
      now,
    )).toBe(true);
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "retry_wait",
      attempts: 1,
      notBefore: now + 30,
    });
    expect(await claimAppleNotificationHistoryRecovery(testEnv, now + 29)).toBeNull();

    let claim = await claimAppleNotificationHistoryRecovery(testEnv, now + 30);
    expect(claim).not.toBeNull();
    for (let resetCount = 1; resetCount <= 3; resetCount += 1) {
      expect(await resetAppleNotificationHistoryCursor(
        testEnv,
        claim!,
        now + 30,
      )).toBe("reset");
      expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
        state: "ready",
        cursorResetCount: resetCount,
        paginationCursor: null,
        committedPageCount: 0,
        committedRecordCount: 0,
      });
      claim = await claimAppleNotificationHistoryRecovery(testEnv, now + 30);
      expect(claim).not.toBeNull();
    }
    expect(await resetAppleNotificationHistoryCursor(
      testEnv,
      claim!,
      now + 30,
    )).toBe("blocked");
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "blocked",
      cursorResetCount: 3,
      lastErrorCode: "apple_notification_history_cursor_reset_exhausted",
    });
  });

  it("rejects expired and stolen leases without committing a page", async () => {
    const now = Math.floor(Date.now() / 1_000);
    const past = now - 1_000;
    const blocked = await getAppleNotificationHistoryRecoveryState(testEnv);
    expect(await beginAppleNotificationHistoryRecovery(testEnv, {
      expectedGeneration: blocked.generation,
      storeEnvironment: "Sandbox",
      bundleId: "jp.nekowidget.app",
      frozenStartDateMs: (now - 10_800) * 1_000,
      frozenEndDateMs: now * 1_000,
    }, past)).toBe(true);
    const expired = await claimAppleNotificationHistoryRecovery(testEnv, past);
    expect(expired).not.toBeNull();
    await expect(commitAppleNotificationHistoryPage(testEnv, expired!, {
      hasMore: false,
      nextPaginationCursor: null,
      records: [],
    }, past)).rejects.toThrow();
    const current = await claimAppleNotificationHistoryRecovery(testEnv, now);
    expect(current).not.toBeNull();
    expect(current!.leaseToken).not.toBe(expired!.leaseToken);
    expect(await retryAppleNotificationHistoryRecovery(
      testEnv,
      expired!,
      "expired_history_lease",
      now,
    )).toBe(false);
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "leased",
      leaseToken: current!.leaseToken,
      committedPageCount: 0,
      paginationCursor: null,
    });

    const stolen: AppleNotificationHistoryRecoveryClaim = {
      ...current!,
      leaseToken: "AAAAAAAAAAAAAAAAAAAAAA",
    };
    await expect(commitAppleNotificationHistoryPage(testEnv, stolen, {
      hasMore: false,
      nextPaginationCursor: null,
      records: [],
    }, now)).rejects.toThrow();
    expect(await getAppleNotificationHistoryRecoveryState(testEnv)).toMatchObject({
      state: "leased",
      leaseToken: current!.leaseToken,
      committedPageCount: 0,
    });
    expect(await blockAppleNotificationHistoryRecovery(
      testEnv,
      current!,
      "manual_test_cleanup",
      now,
    )).toBe(true);
    await expect(testEnv.DB.prepare(
      "DELETE FROM billing_apple_notification_history_recovery WHERE singleton = 1",
    ).run()).rejects.toThrow();
  });
});
