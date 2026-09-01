import { randomBase64url, sha256Base64url } from "./encoding";
import type { Env } from "./env";

export const APPLE_NOTIFICATION_HISTORY_LEASE_SECONDS = 120;
export const APPLE_NOTIFICATION_HISTORY_MAX_CURSOR_RESETS = 3;

export type AppleNotificationHistoryRecoveryStateName =
  | "idle"
  | "ready"
  | "leased"
  | "retry_wait"
  | "completed"
  | "blocked";

export type AppleStoreEnvironment = "Sandbox" | "Production";

interface RecoveryRow {
  generation: number;
  state: AppleNotificationHistoryRecoveryStateName;
  store_environment: AppleStoreEnvironment | null;
  bundle_id: string | null;
  frozen_start_date_ms: number | null;
  frozen_end_date_ms: number | null;
  pagination_cursor: string | null;
  committed_page_count: number;
  committed_record_count: number;
  cursor_reset_count: number;
  attempts: number;
  not_before: number;
  lease_token: string | null;
  lease_expires_at: number | null;
  claimed_gate_generation: number | null;
  last_error_code: string | null;
  started_at: number | null;
  completed_at: number | null;
  updated_at: number;
}

export interface AppleNotificationHistoryRecoveryState {
  generation: number;
  state: AppleNotificationHistoryRecoveryStateName;
  storeEnvironment: AppleStoreEnvironment | null;
  bundleId: string | null;
  frozenStartDateMs: number | null;
  frozenEndDateMs: number | null;
  paginationCursor: string | null;
  committedPageCount: number;
  committedRecordCount: number;
  cursorResetCount: number;
  attempts: number;
  notBefore: number;
  leaseToken: string | null;
  leaseExpiresAt: number | null;
  claimedGateGeneration: number | null;
  lastErrorCode: string | null;
  startedAt: number | null;
  completedAt: number | null;
  updatedAt: number;
}

export interface BeginAppleNotificationHistoryRecoveryInput {
  expectedGeneration: number;
  storeEnvironment: AppleStoreEnvironment;
  bundleId: string;
  frozenStartDateMs: number;
  frozenEndDateMs: number;
}

export interface AppleNotificationHistoryRecoveryClaim {
  generation: number;
  gateGeneration: number;
  leaseToken: string;
  leaseExpiresAt: number;
  storeEnvironment: AppleStoreEnvironment;
  bundleId: string;
  frozenStartDateMs: number;
  frozenEndDateMs: number;
  paginationCursor: string | null;
  nextPageIndex: number;
  committedRecordCount: number;
  cursorResetCount: number;
  attempts: number;
}

export interface CommitAppleNotificationHistoryPageInput {
  hasMore: boolean;
  nextPaginationCursor: string | null;
  /** References to normalized events that are already durable in D1. */
  records: readonly {
    notificationUUID: string;
    payloadHash: string;
  }[];
}

const recoverySelect = `
  SELECT generation, state, store_environment, bundle_id,
         frozen_start_date_ms, frozen_end_date_ms, pagination_cursor,
         committed_page_count, committed_record_count, cursor_reset_count,
         attempts, not_before, lease_token, lease_expires_at,
         claimed_gate_generation,
         last_error_code, started_at, completed_at, updated_at
    FROM billing_apple_notification_history_recovery
   WHERE singleton = 1`;

const opaqueCursorPattern = /^[\x21-\x7e]{1,4096}$/u;
const bundleIdPattern = /^(?=.{3,255}$)(?=.*\.)[A-Za-z0-9.-]+$/u;
const errorCodePattern = /^[a-z0-9_]{1,64}$/u;
const notificationUUIDPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const payloadHashPattern = /^[A-Za-z0-9_-]{43}$/u;
const maximumFrozenWindowMs: Record<AppleStoreEnvironment, number> = {
  Sandbox: 30 * 24 * 60 * 60 * 1_000,
  Production: 180 * 24 * 60 * 60 * 1_000,
};

function safeNonNegativeInteger(value: number, field: string): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new TypeError(`${field} must be a non-negative safe integer`);
  }
}

function safePositiveInteger(value: number, field: string): void {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new TypeError(`${field} must be a positive safe integer`);
  }
}

function validOpaqueCursor(value: string): boolean {
  // Treat this as an opaque capability. Bounds and printable ASCII are the
  // only Worker-side checks; signature and app/window binding belong to the
  // isolated verifier.
  return opaqueCursorPattern.test(value);
}

function mapRecoveryRow(row: RecoveryRow): AppleNotificationHistoryRecoveryState {
  return {
    generation: row.generation,
    state: row.state,
    storeEnvironment: row.store_environment,
    bundleId: row.bundle_id,
    frozenStartDateMs: row.frozen_start_date_ms,
    frozenEndDateMs: row.frozen_end_date_ms,
    paginationCursor: row.pagination_cursor,
    committedPageCount: row.committed_page_count,
    committedRecordCount: row.committed_record_count,
    cursorResetCount: row.cursor_reset_count,
    attempts: row.attempts,
    notBefore: row.not_before,
    leaseToken: row.lease_token,
    leaseExpiresAt: row.lease_expires_at,
    claimedGateGeneration: row.claimed_gate_generation,
    lastErrorCode: row.last_error_code,
    startedAt: row.started_at,
    completedAt: row.completed_at,
    updatedAt: row.updated_at,
  };
}

export async function getAppleNotificationHistoryRecoveryState(
  env: Pick<Env, "DB">,
): Promise<AppleNotificationHistoryRecoveryState> {
  const row = await env.DB.prepare(recoverySelect).first<RecoveryRow>();
  if (row === null) throw new Error("missing Apple notification history recovery state");
  return mapRecoveryRow(row);
}

export async function beginAppleNotificationHistoryRecovery(
  env: Pick<Env, "DB">,
  input: BeginAppleNotificationHistoryRecoveryInput,
  now = Math.floor(Date.now() / 1_000),
): Promise<boolean> {
  safeNonNegativeInteger(input.expectedGeneration, "expectedGeneration");
  safePositiveInteger(input.frozenStartDateMs, "frozenStartDateMs");
  safePositiveInteger(input.frozenEndDateMs, "frozenEndDateMs");
  safePositiveInteger(now, "now");
  if (input.storeEnvironment !== "Sandbox" && input.storeEnvironment !== "Production") {
    throw new TypeError("storeEnvironment is invalid");
  }
  if (
    input.frozenStartDateMs >= input.frozenEndDateMs
    || input.frozenEndDateMs - input.frozenStartDateMs
      > maximumFrozenWindowMs[input.storeEnvironment]
  ) {
    throw new TypeError("the frozen notification history window is invalid");
  }
  if (!bundleIdPattern.test(input.bundleId)) {
    throw new TypeError("bundleId is invalid");
  }
  const result = await env.DB.prepare(
    `UPDATE billing_apple_notification_history_recovery
        SET generation = generation + 1,
            state = 'ready',
            store_environment = ?, bundle_id = ?,
            frozen_start_date_ms = ?, frozen_end_date_ms = ?,
            pagination_cursor = NULL,
            committed_page_count = 0, committed_record_count = 0,
            cursor_reset_count = 0, attempts = 0,
            not_before = ?, lease_token = NULL, lease_expires_at = NULL,
            claimed_gate_generation = NULL,
            last_error_code = NULL, started_at = ?, completed_at = NULL,
            updated_at = unixepoch()
      WHERE singleton = 1 AND generation = ?
        AND state IN ('idle', 'completed', 'blocked')`,
  ).bind(
    input.storeEnvironment,
    input.bundleId,
    input.frozenStartDateMs,
    input.frozenEndDateMs,
    now,
    now,
    input.expectedGeneration,
  ).run();
  return result.meta.changes === 1;
}

export async function releaseExpiredAppleNotificationHistoryLease(
  env: Pick<Env, "DB">,
  now = Math.floor(Date.now() / 1_000),
): Promise<boolean> {
  safePositiveInteger(now, "now");
  const released = await env.DB.prepare(
    `UPDATE billing_apple_notification_history_recovery
        SET state = 'ready', not_before = ?,
            lease_token = NULL, lease_expires_at = NULL,
            claimed_gate_generation = NULL,
            last_error_code = NULL, updated_at = unixepoch()
      WHERE singleton = 1 AND state = 'leased'
        AND (lease_expires_at <= ? OR lease_expires_at <= unixepoch())`,
  ).bind(now, now).run();
  return released.meta.changes === 1;
}

export async function claimAppleNotificationHistoryRecovery(
  env: Pick<Env, "DB">,
  now = Math.floor(Date.now() / 1_000),
): Promise<AppleNotificationHistoryRecoveryClaim | null> {
  safePositiveInteger(now, "now");
  // A Worker can disappear after claiming and before releasing. Reopen only an
  // expired lease; the old token is cleared before a new claim is selected, so
  // any late response remains fenced from page/event/cursor commit.
  await releaseExpiredAppleNotificationHistoryLease(env, now);
  const candidate = await env.DB.prepare(
    `${recoverySelect}
       AND state IN ('ready', 'retry_wait')
       AND not_before <= ?`,
  ).bind(now).first<RecoveryRow>();
  if (
    candidate === null
    || candidate.store_environment === null
    || candidate.bundle_id === null
    || candidate.frozen_start_date_ms === null
    || candidate.frozen_end_date_ms === null
  ) return null;

  const gate = await env.DB.prepare(
    `SELECT generation
       FROM billing_runtime_gate
      WHERE singleton = 1
        AND apple_notification_history_recovery_enabled = 1`,
  ).first<{ generation: number }>();
  if (gate === null) return null;

  const leaseToken = randomBase64url(16);
  const leaseExpiresAt = now + APPLE_NOTIFICATION_HISTORY_LEASE_SECONDS;
  const claimed = await env.DB.prepare(
    `UPDATE billing_apple_notification_history_recovery
        SET state = 'leased', lease_token = ?, lease_expires_at = ?,
            claimed_gate_generation = ?,
            last_error_code = NULL, updated_at = unixepoch()
      WHERE singleton = 1 AND generation = ?
        AND state IN ('ready', 'retry_wait') AND not_before <= ?
        AND EXISTS (
          SELECT 1 FROM billing_runtime_gate AS gate
           WHERE gate.singleton = 1
             AND gate.apple_notification_history_recovery_enabled = 1
             AND gate.generation = ?
        )`,
  ).bind(
    leaseToken,
    leaseExpiresAt,
    gate.generation,
    candidate.generation,
    now,
    gate.generation,
  ).run();
  if (claimed.meta.changes !== 1) return null;
  return {
    generation: candidate.generation,
    gateGeneration: gate.generation,
    leaseToken,
    leaseExpiresAt,
    storeEnvironment: candidate.store_environment,
    bundleId: candidate.bundle_id,
    frozenStartDateMs: candidate.frozen_start_date_ms,
    frozenEndDateMs: candidate.frozen_end_date_ms,
    paginationCursor: candidate.pagination_cursor,
    nextPageIndex: candidate.committed_page_count + 1,
    committedRecordCount: candidate.committed_record_count,
    cursorResetCount: candidate.cursor_reset_count,
    attempts: candidate.attempts,
  };
}

async function cursorHash(value: string | null): Promise<string | null> {
  return value === null
    ? null
    : sha256Base64url(new TextEncoder().encode(value));
}

export async function commitAppleNotificationHistoryPage(
  env: Pick<Env, "DB">,
  claim: AppleNotificationHistoryRecoveryClaim,
  input: CommitAppleNotificationHistoryPageInput,
  completedAt = Math.floor(Date.now() / 1_000),
): Promise<void> {
  safePositiveInteger(completedAt, "completedAt");
  if (input.records.length > 20) throw new TypeError("a history page cannot exceed 20 records");
  const notificationUUIDs = new Set<string>();
  const payloadHashes = new Set<string>();
  for (const record of input.records) {
    if (
      !notificationUUIDPattern.test(record.notificationUUID)
      || !payloadHashPattern.test(record.payloadHash)
      || notificationUUIDs.has(record.notificationUUID)
      || payloadHashes.has(record.payloadHash)
    ) throw new TypeError("the notification history page records are invalid");
    notificationUUIDs.add(record.notificationUUID);
    payloadHashes.add(record.payloadHash);
  }
  if (
    (input.hasMore && (input.nextPaginationCursor === null
      || !validOpaqueCursor(input.nextPaginationCursor)))
    || (!input.hasMore && input.nextPaginationCursor !== null)
  ) throw new TypeError("the next notification history cursor is invalid");
  if (claim.paginationCursor !== null && !validOpaqueCursor(claim.paginationCursor)) {
    throw new TypeError("the claimed notification history cursor is invalid");
  }
  if (
    input.hasMore
    && claim.paginationCursor !== null
    && input.nextPaginationCursor === claim.paginationCursor
  ) throw new TypeError("the notification history cursor did not advance");

  const inputCursorHash = await cursorHash(claim.paginationCursor);
  const nextCursorHash = await cursorHash(input.nextPaginationCursor);
  const nextState = input.hasMore ? "ready" : "completed";
  const pageGuard = env.DB.prepare(
    `INSERT INTO billing_apple_notification_history_page_commits(
       generation, page_index, gate_generation, lease_token, input_cursor_hash,
       next_cursor_hash, has_more, record_count
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    claim.generation,
    claim.nextPageIndex,
    claim.gateGeneration,
    claim.leaseToken,
    inputCursorHash,
    nextCursorHash,
    input.hasMore ? 1 : 0,
    input.records.length,
  );
  const recordReceipts = input.records.map((record, recordIndex) => env.DB.prepare(
    `INSERT INTO billing_apple_notification_history_page_records(
       generation, page_index, record_index, notification_uuid, payload_hash
     ) VALUES (?, ?, ?, ?, ?)`,
  ).bind(
    claim.generation,
    claim.nextPageIndex,
    recordIndex,
    record.notificationUUID,
    record.payloadHash,
  ));
  const stateAdvance = env.DB.prepare(
    `UPDATE billing_apple_notification_history_recovery
        SET state = ?, pagination_cursor = ?,
            committed_page_count = committed_page_count + 1,
            committed_record_count = committed_record_count + ?,
            attempts = 0, not_before = ?, lease_token = NULL,
            lease_expires_at = NULL, claimed_gate_generation = NULL,
            last_error_code = NULL,
            completed_at = ?, updated_at = unixepoch()
      WHERE singleton = 1 AND state = 'leased' AND generation = ?
        AND lease_token = ? AND claimed_gate_generation = ?
        AND lease_expires_at > ? AND lease_expires_at > unixepoch()
        AND EXISTS (
          SELECT 1 FROM billing_runtime_gate AS gate
           WHERE gate.singleton = 1
             AND gate.apple_notification_history_recovery_enabled = 1
             AND gate.generation = ?
        )`,
  ).bind(
    nextState,
    input.nextPaginationCursor,
    input.records.length,
    completedAt,
    input.hasMore ? null : completedAt,
    claim.generation,
    claim.leaseToken,
    claim.gateGeneration,
    completedAt,
    claim.gateGeneration,
  );
  const finalization = env.DB.prepare(
    `INSERT INTO billing_apple_notification_history_page_finalizations(
       generation, page_index
     ) VALUES (?, ?)`,
  ).bind(claim.generation, claim.nextPageIndex);
  const results = await env.DB.batch([
    pageGuard,
    ...recordReceipts,
    stateAdvance,
    finalization,
  ]);
  if (results.at(-1)?.meta.changes !== 1) {
    throw new Error("notification history page did not advance its claimed state");
  }
}

function retryDelaySeconds(attempts: number): number {
  return attempts >= 20
    ? 86_400
    : Math.min(3_600, 30 * (2 ** Math.min(attempts - 1, 7)));
}

export async function retryAppleNotificationHistoryRecovery(
  env: Pick<Env, "DB">,
  claim: AppleNotificationHistoryRecoveryClaim,
  errorCode: string,
  failedAt = Math.floor(Date.now() / 1_000),
): Promise<boolean> {
  safePositiveInteger(failedAt, "failedAt");
  if (!errorCodePattern.test(errorCode)) throw new TypeError("errorCode is invalid");
  const attempts = Math.min(20, claim.attempts + 1);
  const retryAt = failedAt + retryDelaySeconds(attempts);
  const failed = await env.DB.prepare(
    `UPDATE billing_apple_notification_history_recovery
        SET state = 'retry_wait', attempts = ?, not_before = ?,
            lease_token = NULL, lease_expires_at = NULL,
            claimed_gate_generation = NULL,
            last_error_code = ?, updated_at = unixepoch()
      WHERE singleton = 1 AND state = 'leased' AND generation = ?
        AND lease_token = ? AND lease_expires_at > ?
        AND lease_expires_at > unixepoch()`,
  ).bind(
    attempts,
    retryAt,
    errorCode,
    claim.generation,
    claim.leaseToken,
    failedAt,
  ).run();
  if (failed.meta.changes === 1) return true;

  // A response that outlived its lease cannot impose a backoff. Release the
  // stale lease so another invocation can reclaim the unchanged cursor now.
  await env.DB.prepare(
    `UPDATE billing_apple_notification_history_recovery
        SET state = 'ready', attempts = 0, not_before = ?,
            lease_token = NULL, lease_expires_at = NULL,
            claimed_gate_generation = NULL,
            last_error_code = NULL, updated_at = unixepoch()
      WHERE singleton = 1 AND state = 'leased' AND generation = ?
        AND lease_token = ?
        AND (lease_expires_at <= ? OR lease_expires_at <= unixepoch())`,
  ).bind(failedAt, claim.generation, claim.leaseToken, failedAt).run();
  return false;
}

export async function blockAppleNotificationHistoryRecovery(
  env: Pick<Env, "DB">,
  claim: AppleNotificationHistoryRecoveryClaim,
  errorCode: string,
  blockedAt = Math.floor(Date.now() / 1_000),
): Promise<boolean> {
  safePositiveInteger(blockedAt, "blockedAt");
  if (!errorCodePattern.test(errorCode)) throw new TypeError("errorCode is invalid");
  const result = await env.DB.prepare(
    `UPDATE billing_apple_notification_history_recovery
        SET state = 'blocked', not_before = 0,
            lease_token = NULL, lease_expires_at = NULL,
            claimed_gate_generation = NULL,
            last_error_code = ?, updated_at = unixepoch()
      WHERE singleton = 1 AND state = 'leased' AND generation = ?
        AND lease_token = ? AND lease_expires_at > ?
        AND lease_expires_at > unixepoch()`,
  ).bind(errorCode, claim.generation, claim.leaseToken, blockedAt).run();
  return result.meta.changes === 1;
}

export async function resetAppleNotificationHistoryCursor(
  env: Pick<Env, "DB">,
  claim: AppleNotificationHistoryRecoveryClaim,
  resetAt = Math.floor(Date.now() / 1_000),
): Promise<"reset" | "blocked" | null> {
  safePositiveInteger(resetAt, "resetAt");
  const reset = await env.DB.prepare(
    `UPDATE billing_apple_notification_history_recovery
        SET generation = generation + 1, state = 'ready',
            pagination_cursor = NULL,
            committed_page_count = 0, committed_record_count = 0,
            cursor_reset_count = cursor_reset_count + 1,
            attempts = 0, not_before = ?,
            lease_token = NULL, lease_expires_at = NULL,
            claimed_gate_generation = NULL,
            last_error_code = NULL, completed_at = NULL,
            updated_at = unixepoch()
      WHERE singleton = 1 AND state = 'leased' AND generation = ?
        AND lease_token = ? AND lease_expires_at > ?
        AND lease_expires_at > unixepoch()
        AND cursor_reset_count < ?`,
  ).bind(
    resetAt,
    claim.generation,
    claim.leaseToken,
    resetAt,
    APPLE_NOTIFICATION_HISTORY_MAX_CURSOR_RESETS,
  ).run();
  if (reset.meta.changes === 1) return "reset";

  const blocked = await env.DB.prepare(
    `UPDATE billing_apple_notification_history_recovery
        SET state = 'blocked', not_before = 0,
            lease_token = NULL, lease_expires_at = NULL,
            claimed_gate_generation = NULL,
            last_error_code = 'apple_notification_history_cursor_reset_exhausted',
            updated_at = unixepoch()
      WHERE singleton = 1 AND state = 'leased' AND generation = ?
        AND lease_token = ? AND lease_expires_at > ?
        AND lease_expires_at > unixepoch()
        AND cursor_reset_count >= ?`,
  ).bind(
    claim.generation,
    claim.leaseToken,
    resetAt,
    APPLE_NOTIFICATION_HISTORY_MAX_CURSOR_RESETS,
  ).run();
  return blocked.meta.changes === 1 ? "blocked" : null;
}
