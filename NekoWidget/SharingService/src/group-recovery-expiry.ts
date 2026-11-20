import { ApiError } from './errors';

// The matching check in migration 0093 runs in the same transaction as key delivery.
export const recoveryPendingLifetime = 7 * 24 * 60 * 60;

export async function cleanupExpiredGroupRecovery(db: D1Database, now: number): Promise<void> {
  await db.prepare(`DELETE FROM group_recovery_pending WHERE rowid IN (
    SELECT rowid FROM group_recovery_pending WHERE created_at<=? ORDER BY created_at,rowid LIMIT 100
  )`).bind(now-recoveryPendingLifetime).run();
}

export async function recoveryExpiryCheckedBatch(db: D1Database, statements: D1PreparedStatement[]): Promise<void> {
  try { await db.batch(statements); }
  catch (error) {
    if (error instanceof Error && error.message.includes('group_recovery_pending_expired')) {
      throw new ApiError(409, 'recovery_pending_expired', 'Recovery registration has expired.');
    }
    throw error;
  }
}
