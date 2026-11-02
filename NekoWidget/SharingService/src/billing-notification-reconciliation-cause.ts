import type { Env } from "./env";

const notificationUUIDPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const transactionIdPattern = /^\d{1,32}$/u;

/**
 * Returns the idempotent cause write for a verified, linked notification.
 * Its D1 AFTER INSERT trigger queues reconciliation exactly once per Apple
 * notification UUID. A replay repairs a previously missing cause but cannot
 * repeatedly increment the reconciliation generation.
 */
export function appleNotificationReconciliationCauseStatement(
  env: Pick<Env, "DB" | "BILLING_STORE_ENVIRONMENT">,
  notificationUUID: string,
  originalTransactionId: string,
  storeEnvironment = env.BILLING_STORE_ENVIRONMENT,
): D1PreparedStatement {
  if (storeEnvironment !== "Sandbox" && storeEnvironment !== "Production") {
    throw new TypeError("storeEnvironment is invalid");
  }
  if (!notificationUUIDPattern.test(notificationUUID)) {
    throw new TypeError("notificationUUID is invalid");
  }
  if (!transactionIdPattern.test(originalTransactionId)) {
    throw new TypeError("originalTransactionId is invalid");
  }
  return env.DB.prepare(
    `INSERT OR IGNORE INTO billing_apple_notification_reconciliation_causes(
       environment, notification_uuid, original_transaction_id
     ) VALUES (?, ?, ?)`,
  ).bind(storeEnvironment, notificationUUID, originalTransactionId);
}

export async function ensureAppleNotificationReconciliationCause(
  env: Pick<Env, "DB" | "BILLING_STORE_ENVIRONMENT">,
  notificationUUID: string,
  originalTransactionId: string,
  storeEnvironment = env.BILLING_STORE_ENVIRONMENT,
): Promise<boolean> {
  const result = await appleNotificationReconciliationCauseStatement(
    env,
    notificationUUID,
    originalTransactionId,
    storeEnvironment,
  ).run();
  // D1 may include the AFTER INSERT queue upsert in meta.changes. Zero still
  // unambiguously means the immutable notificationUUID cause already existed.
  return result.meta.changes > 0;
}
