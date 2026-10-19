import { ServiceError } from './contracts';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const unavailable = () => new ServiceError('RECOVERY_WRITE_FENCED', 503);

/** Fail-closed S3-write lease. A crash or uncertain write result leaves a row
 * that blocks future expiry purge until independently reconciled; no TTL
 * silently bypasses it.
 */
export class RecoveryWriteLease {
  constructor(private readonly db: D1Database, private readonly now: () => number,
    private readonly ownerDeletion?: { assertNotRequested(ownerId: string): Promise<void> }) {}

  private async acquire(ownerId: string): Promise<string> {
    if (!uuid.test(ownerId)) throw unavailable();
    await this.ownerDeletion?.assertNotRequested(ownerId);
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
    return writeId;
  }

  private async release(ownerId: string, writeId: string): Promise<void> {
    try {
      const deletion = await this.db.prepare(`DELETE FROM pa_recovery_write_leases
        WHERE write_id=? AND owner_id=? RETURNING write_id`)
        .bind(writeId, ownerId).all<{ write_id: string }>();
      if (deletion.results.length !== 1 || deletion.results[0]?.write_id !== writeId) {
        throw unavailable();
      }
    } catch { throw unavailable(); }
  }

  async withOwnerWrite<T>(ownerId: string, action: () => Promise<T>): Promise<T> {
    const writeId = await this.acquire(ownerId);
    // A thrown action does not prove that S3 did not commit. Preserve even an
    // undefined rejection and leave the durable lease in place.
    const result = await action();
    await this.release(ownerId, writeId);
    return result;
  }

  /** One operation may publish several immutable objects. Share its durable
   * fence, but recheck deletion and owner state before EVERY transport action.
   * The capability never escapes into another owner/operation. */
  async withOwnerWriteGroup<T>(ownerId: string,
    action: (lease: Pick<RecoveryWriteLease, 'withOwnerWrite'>) => Promise<T>): Promise<T> {
    if (!uuid.test(ownerId)) throw unavailable();
    let closed = false, uncertain = false, failed = false;
    let firstError: unknown, acquisition: Promise<string> | undefined;
    const pending = new Set<Promise<unknown>>();
    const remember = (error: unknown) => {
      if (!failed) { failed = true; firstError = error; }
    };
    const scoped: Pick<RecoveryWriteLease, 'withOwnerWrite'> = {
      withOwnerWrite: <U>(requestedOwner: string, write: () => Promise<U>): Promise<U> => {
        if (closed) return Promise.reject(unavailable());
        // Register synchronously, including all asynchronous prechecks. Closing
        // the group must drain admitted calls that have not reached PUT yet.
        const operation = (async () => {
          if (requestedOwner !== ownerId) throw unavailable();
          acquisition ??= this.acquire(ownerId).catch(error => { uncertain = true; throw error; });
          const writeId = await acquisition;
          await this.ownerDeletion?.assertNotRequested(ownerId);
          const row = await this.db.prepare(`SELECT w.write_id FROM pa_recovery_write_leases w
            JOIN pa_owners o ON o.owner_id=w.owner_id
            WHERE w.write_id=? AND w.owner_id=? AND o.disabled=0 AND o.purge_fence_id IS NULL`)
            .bind(writeId, ownerId).first<{ write_id: string }>();
          if (row?.write_id !== writeId) throw unavailable();
          try { return await write(); }
          catch (error) { uncertain = true; throw error; }
        })();
        pending.add(operation);
        void operation.then(() => { pending.delete(operation); }, error => {
          remember(error); pending.delete(operation);
        });
        return operation;
      },
    };
    let result: T | undefined, callbackFailed = false, callbackError: unknown;
    try { result = await action(scoped); }
    catch (error) { callbackFailed = true; callbackError = error; }
    closed = true;
    await Promise.allSettled([...pending]);
    // A known pre-PUT denial or a read/CAS failure can release a fully confirmed
    // group. An uncertain PUT/HEAD (even if swallowed by the callback) cannot.
    if (acquisition && !uncertain) await this.release(ownerId, await acquisition);
    if (callbackFailed) throw callbackError;
    if (failed) throw firstError;
    return result as T;
  }
}
