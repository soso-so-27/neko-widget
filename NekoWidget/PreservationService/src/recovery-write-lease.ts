import { ServiceError } from './contracts';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const unavailable = () => new ServiceError('RECOVERY_WRITE_FENCED', 503);

/** Fail-closed S3-write lease. A crash or uncertain write result leaves a row
 * that blocks future expiry purge until independently reconciled; no TTL
 * silently bypasses it.
 */
export class RecoveryWriteLease {
  constructor(private readonly db: D1Database, private readonly now: () => number) {}

  async withOwnerWrite<T>(ownerId: string, action: () => Promise<T>): Promise<T> {
    if (!uuid.test(ownerId)) throw unavailable();
    const writeId = crypto.randomUUID();
    const startedAt = this.now();
    if (!Number.isSafeInteger(startedAt) || startedAt < 1) throw unavailable();
    try {
      await this.db.prepare(`INSERT INTO pa_recovery_write_leases(write_id,owner_id,started_at)
        SELECT ?,o.owner_id,? FROM pa_owners o WHERE o.owner_id=?
          AND o.disabled=0 AND o.purge_fence_id IS NULL`)
        .bind(writeId, startedAt, ownerId).run();
      const row = await this.db.prepare(`SELECT write_id FROM pa_recovery_write_leases
        WHERE write_id=? AND owner_id=?`).bind(writeId, ownerId)
        .first<{ write_id: string }>();
      if (!row || row.write_id !== writeId) throw unavailable();
    } catch { throw unavailable(); }
    // A thrown action does not prove that S3 did not commit. Preserve even an
    // undefined rejection and leave the durable lease in place.
    const result = await action();
    try {
      const deletion = await this.db.prepare(`DELETE FROM pa_recovery_write_leases
        WHERE write_id=? AND owner_id=? RETURNING write_id`)
        .bind(writeId, ownerId).all<{ write_id: string }>();
      if (deletion.results.length !== 1 || deletion.results[0]?.write_id !== writeId) {
        throw unavailable();
      }
    } catch { throw unavailable(); }
    return result;
  }
}
