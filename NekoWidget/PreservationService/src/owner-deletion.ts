import { ServiceError, sha256, type KeyCustody, type Session } from './contracts';
import { OwnerDeletionJournal, type OwnerDeletionRequest } from './owner-deletion-journal';
import { inventoryOwnerCloudStorage, type OwnerCloudInventory } from './owner-cloud-inventory';
import { inspectOwnerD1Residue, ownerD1DeleteOrder } from './owner-d1-residue';
import { requestManifestPhotoDeletion } from './r2-photo-purge';
import type { S3RecoveryCopy } from './s3-recovery-copy';
import type { S3VersionPurge } from './s3-version-purge';

const unavailable = () => new ServiceError('OWNER_DELETION_UNAVAILABLE', 503);
const canonical = (inventory: OwnerCloudInventory): string => JSON.stringify({
  ownerId: inventory.ownerId,
  r2Objects: [...inventory.r2Objects].sort((a, b) => a.key.localeCompare(b.key, 'en')),
  s3Versions: [...inventory.s3Versions].sort((a, b) =>
    `${a.key}\0${a.versionId}`.localeCompare(`${b.key}\0${b.versionId}`, 'en')),
});
type Plan = { ownerId: string; r2Objects: OwnerCloudInventory['r2Objects'];
  s3Versions: OwnerCloudInventory['s3Versions'] };
type Base = { db: D1Database; journal: OwnerDeletionJournal; now: () => number };

export class OwnerDeletionRequests {
  constructor(private readonly d: Base & { auth: { requireSession(token: string): Promise<Session> } }) {}

  async request(token: string, receipt: unknown) {
    if (typeof receipt !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(receipt)) {
      throw new ServiceError('INVALID_REQUEST');
    }
    const session = await this.d.auth.requireSession(token);
    const owner = await this.d.db.prepare(`SELECT epoch FROM pa_owners
      WHERE owner_id=? AND disabled=0 AND purge_fence_id IS NULL`)
      .bind(session.ownerId).first<{ epoch: number }>();
    if (!owner) throw unavailable();
    const request = await this.d.journal.prepare({ version: 1, ownerId: session.ownerId,
      requestId: crypto.randomUUID(), receiptHash: await sha256(receipt),
      ownerEpoch: owner.epoch + 1, requestedAt: this.d.now() });
    if (request.receiptHash !== await sha256(receipt)) {
      throw new ServiceError('OWNER_DELETION_PENDING', 409);
    }
    // The immutable external receipt immediately blocks new authenticated
    // access. The executor fences D1 after existing recovery writes drain.
    return { ownerId: request.ownerId, state: 'processing' as const };
  }

  async status(ownerId: string, receipt: string) {
    const status = await this.d.journal.status(ownerId, receipt);
    if (status.state === 'completed') {
      const remaining = await inspectOwnerD1Residue(this.d.db, ownerId);
      // A restored D1 bookmark is not allowed to resurrect a completed owner,
      // nor to keep reporting completion while that image is being reconciled.
      if (remaining.contentTotal || remaining.pendingPhotoDeletes
        || Object.values(remaining.ownerCursors).some(Boolean)
        || Object.values(remaining.recoveryRepairCursors).some(Boolean)) return { state: 'processing' as const };
      await this.d.db.prepare('DELETE FROM pa_owner_deletion_requests WHERE owner_id=?').bind(ownerId).run();
    }
    return status;
  }
}

/** The external request wins even if the process dies before this transaction.
 * Both authentication and restoration consult that request independently.
 */
export async function installOwnerDeletionFence(db: D1Database, r: OwnerDeletionRequest): Promise<void> {
  await db.batch([
    db.prepare(`INSERT INTO pa_owner_deletion_requests(owner_id,request_id,receipt_hash,
      owner_epoch,requested_at,request_sha256,state)
      VALUES(?,?,?,?,?,?,'requested') ON CONFLICT(owner_id) DO NOTHING`)
      .bind(r.ownerId, r.requestId, r.receiptHash, r.ownerEpoch, r.requestedAt,
        await sha256(JSON.stringify(r))),
    db.prepare(`UPDATE pa_owners SET disabled=1,epoch=?,purge_fence_id=?
      WHERE owner_id=? AND epoch=? AND disabled=0 AND purge_fence_id IS NULL
      AND EXISTS(SELECT 1 FROM pa_owner_deletion_requests WHERE owner_id=? AND request_id=?)`)
      .bind(r.ownerEpoch, r.requestId, r.ownerId, r.ownerEpoch - 1, r.ownerId, r.requestId),
    db.prepare(`UPDATE pa_owner_deletion_requests SET state='fenced' WHERE owner_id=?
      AND request_id=? AND state='requested' AND EXISTS(SELECT 1 FROM pa_owners
      WHERE owner_id=? AND epoch=? AND disabled=1 AND purge_fence_id=?)`)
      .bind(r.ownerId, r.requestId, r.ownerId, r.ownerEpoch, r.requestId),
  ]);
  const state = await db.prepare(`SELECT state,request_sha256 FROM pa_owner_deletion_requests
    WHERE owner_id=? AND request_id=?`).bind(r.ownerId, r.requestId)
    .first<{ state: string; request_sha256: string }>();
  if (!state || !['fenced', 'erasing'].includes(state.state)
    || state.request_sha256 !== await sha256(JSON.stringify(r))) throw unavailable();
}

type ExecutorDependencies = Base & {
  enabled?: boolean; bucket: R2Bucket; recovery: S3RecoveryCopy;
  versionPurge: Pick<S3VersionPurge, 'requestExactVersionDeletion'>;
  keys: KeyCustody; revokeRefreshToken: (token: string) => Promise<void>;
};

/** Private executor. Request authority comes from the authenticated, external
 * receipt, never membership expiry or a client-supplied owner. Every step is
 * retryable and scoped to one receipt. No real owner is used for validation.
 */
export class OwnerDeletionExecutor {
  constructor(private readonly d: ExecutorDependencies) {}

  async step(ownerId: string): Promise<'processing' | 'waiting' | 'completed'> {
    if (this.d.enabled !== true) throw new ServiceError('OWNER_DELETION_DISABLED', 503);
    const r = await this.d.journal.request(ownerId);
    if (!r) throw unavailable();
    const completed = await this.d.journal.stage<{ completedAt: number }>(r, 'completed');
    if (completed) {
      const residue = await inspectOwnerD1Residue(this.d.db, ownerId);
      if (residue.contentTotal || residue.pendingPhotoDeletes
        || Object.values(residue.ownerCursors).some(Boolean)
        || Object.values(residue.recoveryRepairCursors).some(Boolean)) throw unavailable();
      await this.d.db.prepare('DELETE FROM pa_owner_deletion_requests WHERE owner_id=?').bind(ownerId).run();
      return 'completed';
    }
    const db = this.d.db;
    const pending = await db.prepare(`SELECT
      (SELECT COUNT(*) FROM pa_recovery_write_leases WHERE owner_id=?) AS writes,
      (SELECT COUNT(*) FROM pa_uploads WHERE owner_id=?) AS uploads,
      (SELECT COUNT(*) FROM pa_purge_fences WHERE owner_id=?) AS expiry_fences`)
      .bind(ownerId, ownerId, ownerId).first<{ writes: number; uploads: number; expiry_fences: number }>();
    // An uncertain write is not dismissed because its lease is old. It must
    // finish or be independently reconciled before sealing the inventory.
    if (!pending || pending.writes || pending.uploads || pending.expiry_fences) return 'waiting';
    await installOwnerDeletionFence(db, r);

    if (!await this.d.journal.stage(r, 'apple-revoked')) {
      const credential = await db.prepare(`SELECT sealed_credentials FROM pa_identity_credentials
        WHERE owner_id=?`).bind(ownerId).first<{ sealed_credentials: ArrayBuffer | number[] }>();
      if (!credential) throw unavailable();
      const plaintext = await this.d.keys.open(new Uint8Array(credential.sealed_credentials),
        { ownerId, purpose: 'identity' });
      try {
        const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(plaintext)) as
          { issuer: string; refreshToken: string };
        if (value.issuer !== 'https://appleid.apple.com' || typeof value.refreshToken !== 'string') throw unavailable();
        await this.d.revokeRefreshToken(value.refreshToken);
      } finally { plaintext.fill(0); }
      await this.d.journal.record(r, 'apple-revoked', { revoked: true });
    }

    let plan = await this.d.journal.stage<Plan>(r, 'plan');
    if (!plan) {
      const before = canonical(await inventoryOwnerCloudStorage(this.d.bucket, this.d.recovery, ownerId));
      const after = canonical(await inventoryOwnerCloudStorage(this.d.bucket, this.d.recovery, ownerId));
      if (before !== after) throw unavailable();
      plan = await this.d.journal.record(r, 'plan', JSON.parse(before) as Plan);
    }
    if (plan.ownerId !== ownerId || !Array.isArray(plan.r2Objects) || !Array.isArray(plan.s3Versions)) throw unavailable();
    const planHash = await sha256(JSON.stringify(plan));
    await this.d.journal.record(r, 'erasing', { planHash });
    await db.prepare(`UPDATE pa_owner_deletion_requests SET state='erasing',manifest_sha256=?,
      apple_revoked=1 WHERE owner_id=? AND request_id=? AND state IN ('fenced','erasing')`)
      .bind(planHash, ownerId, r.requestId).run();
    const current = await inventoryOwnerCloudStorage(this.d.bucket, this.d.recovery, ownerId);
    // Nothing newly written or replaced may be silently adopted into a plan.
    const allowedPhotos = new Set(plan.r2Objects.map(item => JSON.stringify(item)));
    const allowedVersions = new Set(plan.s3Versions.map(item => JSON.stringify(item)));
    if (current.r2Objects.some(item => !allowedPhotos.has(JSON.stringify(item)))
      || current.s3Versions.some(item => !allowedVersions.has(JSON.stringify(item)))) throw unavailable();
    if (current.r2Objects.length) {
      await requestManifestPhotoDeletion(this.d.bucket, ownerId, current.r2Objects[0]!);
      return 'processing';
    }
    if (current.s3Versions.length) {
      await this.d.versionPurge.requestExactVersionDeletion(ownerId, current.s3Versions[0]!);
      // A successful DELETE is not a completion receipt; the next step re-lists.
      return 'processing';
    }
    const confirmed = await inventoryOwnerCloudStorage(this.d.bucket, this.d.recovery, ownerId);
    if (confirmed.r2Objects.length || confirmed.s3Versions.length) throw unavailable();
    await db.prepare(`UPDATE pa_owner_deletion_requests SET cloud_empty=1
      WHERE owner_id=? AND request_id=? AND state='erasing' AND manifest_sha256=?`)
      .bind(ownerId, r.requestId, planHash).run();
    const authority = `EXISTS(SELECT 1 FROM pa_owner_requested_erasing_authority WHERE owner_id=? AND request_id=?)`;
    const residue = await inspectOwnerD1Residue(db, ownerId);
    if (Object.entries(residue.purgeWork).some(([table, n]) => table !== 'pa_owner_deletion_requests' && n)) throw unavailable();
    for (const [table, column, n] of [
      ...Object.entries(residue.ownerCursors).map(([table, n]) => [table, 'owner_id', n] as const),
      ...Object.entries(residue.recoveryRepairCursors).map(([table, n]) => [table, 'last_owner_id', n] as const),
    ]) {
      if (!n) continue;
      await db.prepare(`UPDATE ${table} SET ${column}='' WHERE ${column}=? AND ${authority}`)
        .bind(ownerId, ownerId, r.requestId).run();
      return 'processing';
    }
    if (residue.pendingPhotoDeletes) {
      await db.prepare(`DELETE FROM pa_pending_deletes WHERE object_key IN
        (SELECT object_key FROM pa_pending_deletes WHERE object_key>=? AND object_key<? LIMIT 128)
        AND ${authority}`).bind(`personal/${ownerId}/`, `personal/${ownerId}0`, ownerId, r.requestId).run();
      return 'processing';
    }
    for (const table of ownerD1DeleteOrder) {
      if (table === 'pa_purge_fences' || !residue.content[table]) continue;
      await db.prepare(`DELETE FROM ${table} WHERE rowid IN
        (SELECT rowid FROM ${table} WHERE owner_id=? LIMIT 128) AND ${authority}`)
        .bind(ownerId, ownerId, r.requestId).run();
      return 'processing';
    }
    const final = await inspectOwnerD1Residue(db, ownerId);
    if (final.contentTotal || final.pendingPhotoDeletes
      || Object.values(final.ownerCursors).some(Boolean)
      || Object.values(final.recoveryRepairCursors).some(Boolean)) throw unavailable();
    await this.d.journal.record(r, 'completed', { completedAt: this.d.now() });
    await db.prepare('DELETE FROM pa_owner_deletion_requests WHERE owner_id=? AND request_id=?')
      .bind(ownerId, r.requestId).run();
    return 'completed';
  }
}
