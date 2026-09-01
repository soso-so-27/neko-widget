import {
  fetchAppleNotificationHistoryPageViaService,
  type AppleNotificationHistoryPageRequest,
  type VerifiedAppleNotificationHistoryPage,
  type VerifiedAppleNotificationHistoryRecord,
} from "./billing-apple-client";
import { ingestVerifiedAppleBillingNotification } from "./billing-authority";
import {
  beginAppleNotificationHistoryRecovery,
  blockAppleNotificationHistoryRecovery,
  claimAppleNotificationHistoryRecovery,
  commitAppleNotificationHistoryPage,
  getAppleNotificationHistoryRecoveryState,
  resetAppleNotificationHistoryCursor,
  retryAppleNotificationHistoryRecovery,
} from "./billing-notification-history-state";
import {
  AppleNotificationHistoryConfigurationBlockedError,
  AppleNotificationHistoryCursorResetRequiredError,
  AppleNotificationHistoryDisabledError,
  InvalidAppleNotificationHistoryError,
  loadVerifierConfig,
} from "./billing-verifier-client";
import {
  billingAppleNotificationHistoryRecoveryRuntimeEnabled,
  type Env,
} from "./env";
import { ApiError } from "./errors";
import { loadBillingRuntimeGate } from "./runtime-gate";

const stableHistoryLagSeconds = 10 * 60;
const maximumFrozenWindowMs = 24 * 60 * 60 * 1_000;

export type AppleNotificationHistoryPageFetcher = (
  request: AppleNotificationHistoryPageRequest,
  env: Env,
) => Promise<VerifiedAppleNotificationHistoryPage>;

export type AppleNotificationHistoryRecordIngestor = (
  env: Env,
  record: VerifiedAppleNotificationHistoryRecord,
) => Promise<void>;

async function defaultRecordIngestor(
  env: Env,
  record: VerifiedAppleNotificationHistoryRecord,
): Promise<void> {
  await ingestVerifiedAppleBillingNotification(
    env,
    record.notification,
    record.payloadHash,
  );
}

function errorCode(error: unknown): string {
  if (error instanceof ApiError) {
    const safe = error.code.replace(/[^a-z0-9_]/gu, "_").slice(0, 64);
    return safe === "" ? "apple_notification_history_unavailable" : safe;
  }
  return "apple_notification_history_unavailable";
}

function requiresOperator(error: unknown): boolean {
  return error instanceof AppleNotificationHistoryConfigurationBlockedError
    || error instanceof AppleNotificationHistoryDisabledError
    || error instanceof InvalidAppleNotificationHistoryError
    || (error instanceof ApiError && new Set([
      "apple_notification_conflict",
      "billing_configuration_unavailable",
      "billing_transaction_conflict",
      "billing_verifier_invalid_response",
    ]).has(error.code));
}

async function ensureFrozenWindow(
  env: Env,
  now: number,
): Promise<void> {
  const state = await getAppleNotificationHistoryRecoveryState(env);
  if (state.state !== "idle" && state.state !== "completed") return;

  const config = loadVerifierConfig(env);
  if (
    state.state === "completed"
    && (state.storeEnvironment !== config.environment
      || state.bundleId !== config.bundleId)
  ) {
    // App identity changes are an operator event. Never reinterpret an old
    // watermark as belonging to the newly configured app.
    return;
  }
  const stableEndDateMs = (now - stableHistoryLagSeconds) * 1_000;
  if (!Number.isSafeInteger(stableEndDateMs) || stableEndDateMs <= 0) return;
  const frozenStartDateMs = state.state === "completed"
    ? state.frozenEndDateMs
    : stableEndDateMs - maximumFrozenWindowMs;
  if (frozenStartDateMs === null || frozenStartDateMs >= stableEndDateMs) return;
  const frozenEndDateMs = Math.min(
    stableEndDateMs,
    frozenStartDateMs + maximumFrozenWindowMs,
  );
  await beginAppleNotificationHistoryRecovery(env, {
    expectedGeneration: state.generation,
    storeEnvironment: config.environment,
    bundleId: config.bundleId,
    frozenStartDateMs,
    frozenEndDateMs,
  }, now);
}

/**
 * Recover at most one immutable Notification History page per five-minute run.
 * Record/event/cause writes finish before the signed cursor can advance; any
 * interruption therefore replays the same page through idempotent ledgers.
 */
export async function runAppleNotificationHistoryRecovery(
  env: Env,
  fetchPage: AppleNotificationHistoryPageFetcher =
    fetchAppleNotificationHistoryPageViaService,
  ingestRecord: AppleNotificationHistoryRecordIngestor = defaultRecordIngestor,
  now = Math.floor(Date.now() / 1_000),
  completedAtOverride?: number,
): Promise<void> {
  if (!billingAppleNotificationHistoryRecoveryRuntimeEnabled(env)) return;
  const gate = await loadBillingRuntimeGate(env);
  if (gate?.appleNotificationHistoryRecoveryEnabled !== true) return;

  try {
    await ensureFrozenWindow(env, now);
  } catch {
    // Missing or malformed verifier configuration must not create a partially
    // identified recovery generation. The public health/config attestations
    // remain the operator-visible evidence for this pre-claim failure.
    return;
  }

  const claim = await claimAppleNotificationHistoryRecovery(env, now);
  if (claim === null) return;
  const completedAt = completedAtOverride
    ?? Math.max(now, Math.floor(Date.now() / 1_000));

  try {
    const config = loadVerifierConfig(env);
    if (
      claim.storeEnvironment !== config.environment
      || claim.bundleId !== config.bundleId
    ) {
      await blockAppleNotificationHistoryRecovery(
        env,
        claim,
        "apple_notification_history_identity_mismatch",
        completedAt,
      );
      return;
    }
    const page = await fetchPage({
      startDateMs: claim.frozenStartDateMs,
      endDateMs: claim.frozenEndDateMs,
      paginationToken: claim.paginationCursor,
    }, env);
    for (const record of page.records) {
      await ingestRecord(env, record);
    }
    // All normalized records and their one-time reconciliation causes are now
    // durable. The fenced page/state batch is the final cursor checkpoint.
    await commitAppleNotificationHistoryPage(env, claim, {
      hasMore: page.hasMore,
      nextPaginationCursor: page.nextPaginationToken,
      records: page.records.map((record) => ({
        notificationUUID: record.notification.notificationUUID,
        payloadHash: record.payloadHash,
      })),
    }, completedAt);
  } catch (error) {
    if (error instanceof AppleNotificationHistoryCursorResetRequiredError) {
      await resetAppleNotificationHistoryCursor(env, claim, completedAt);
    } else if (requiresOperator(error)) {
      await blockAppleNotificationHistoryRecovery(
        env,
        claim,
        errorCode(error),
        completedAt,
      );
    } else {
      await retryAppleNotificationHistoryRecovery(
        env,
        claim,
        errorCode(error),
        completedAt,
      );
    }
  }
}
