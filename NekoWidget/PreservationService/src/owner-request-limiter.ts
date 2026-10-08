import { ServiceError, type Session } from './contracts';

/** Thirty authenticated HTTP attempts per fixed UTC minute, not a rolling
 * sixty-second window. Failed downstream work is not refunded. All sessions
 * for an owner share one row; the D1 primary's clock sets every region's window.
 * This limit is independent of intake/cost-review deadlines and membership.
 */
export class OwnerRequestLimiter {
  constructor(private readonly db: D1Database) {}

  async admit(session: Session): Promise<void> {
    try {
      // A write always reaches D1's primary. The conditional increment and
      // current session/epoch checks are one statement, never a read-then-write.
      // A backward database clock cannot reopen an earlier allowance.
      const admitted = await this.db.prepare(`WITH clock AS (
          SELECT CAST(unixepoch()/60 AS INTEGER) AS minute, unixepoch('subsec')*1000 AS now_ms
        ) UPDATE pa_owners SET
          http_request_count=CASE WHEN http_request_minute=(SELECT minute FROM clock)
            THEN http_request_count+1 ELSE 1 END,
          http_request_minute=(SELECT minute FROM clock)
        WHERE owner_id=? AND disabled=0 AND purge_fence_id IS NULL
          AND http_request_minute<=(SELECT minute FROM clock)
          AND (http_request_minute<(SELECT minute FROM clock) OR http_request_count<30)
          AND EXISTS(SELECT 1 FROM pa_sessions s WHERE s.session_hash=?
            AND s.owner_id=pa_owners.owner_id AND s.owner_epoch=pa_owners.epoch
            AND s.expires_at>(SELECT now_ms FROM clock))
          AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests d
            WHERE d.owner_id=pa_owners.owner_id)
          AND ((SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=0
            OR EXISTS(SELECT 1 FROM pa_owner_recovery_generations g
              JOIN pa_owner_recovery_versions v ON v.owner_id=g.owner_id AND v.generation=g.generation
              WHERE g.owner_id=pa_owners.owner_id))
        RETURNING http_request_minute,http_request_count`)
        .bind(session.ownerId, session.sessionHash)
        .first<{ http_request_minute: number; http_request_count: number }>();
      // A session invalidated after requireSession also fails closed here;
      // no downstream handler runs and no quota is consumed for that session.
      if (!admitted) throw new ServiceError('RATE_LIMITED', 429);
      if (!Number.isSafeInteger(admitted.http_request_minute) || admitted.http_request_minute < 0
        || !Number.isSafeInteger(admitted.http_request_count)
        || admitted.http_request_count < 1 || admitted.http_request_count > 30) throw new Error();
    } catch (error) {
      if (error instanceof ServiceError) throw error;
      throw new ServiceError('OWNER_REQUEST_LIMIT_UNAVAILABLE', 503);
    }
  }
}
