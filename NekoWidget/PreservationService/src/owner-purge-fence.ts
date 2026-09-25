import { ServiceError } from './contracts';
import type { DurableAuth } from './auth';
import type { NoticeSubmissions } from './notice-submissions';
import { RetentionLedger, type ExpiryReviewCandidate, type VerifiedMembershipStatus } from './retention-ledger';

const ownerPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const day = 86_400_000;
const fenceLease = 10 * 60_000;
const unavailable = () => new ServiceError('PURGE_FENCE_UNAVAILABLE', 503);
const photoPrefixForOwner = (ownerId: string) => `personal/${ownerId}/`;
// '/' sorts immediately before '0'; this indexed range covers every key in
// one fixed UUID owner prefix without matching a neighbouring owner.
const photoPrefixUpperBound = (ownerId: string) => `personal/${ownerId}0`;

interface OwnerState { epoch: number; generation: number; billing_account_id: string;
  pending_uploads: number; pending_deletes: number }
export interface PurgeFence { fenceId: string; ownerId: string; ownerEpoch: number; inventoryGeneration: number;
  candidate: ExpiryReviewCandidate }
interface Dependencies {
  db: D1Database;
  now: () => number;
  auth: DurableAuth;
  notices: NoticeSubmissions;
  retention: RetentionLedger;
  statusForBillingAccount: (billingAccountId: string) => Promise<VerifiedMembershipStatus>;
}

/** Stops normal access before any irreversible purge. This is not deletion
 * authority: the caller must independently inventory every R2/S3 version,
 * recheck billing after fencing and again before each destructive action,
 * and keep a durable deletion ledger. No HTTP route or scheduler calls it yet.
 */
export class OwnerPurgeFence {
  constructor(private readonly d: Dependencies) {}

  private now(): number {
    const value = this.d.now();
    if (!Number.isSafeInteger(value) || value <= 30 * day) throw unavailable();
    return value;
  }

  private async state(ownerId: string): Promise<OwnerState | null> {
    const photoPrefix = photoPrefixForOwner(ownerId);
    return this.d.db.prepare(`SELECT o.epoch,i.generation,l.billing_account_id,
      (SELECT COUNT(*) FROM pa_uploads u WHERE u.owner_id=o.owner_id) AS pending_uploads,
      (SELECT COUNT(*) FROM pa_pending_deletes p WHERE p.object_key>=? AND p.object_key<?) AS pending_deletes
      FROM pa_owners o JOIN pa_inventory i ON i.owner_id=o.owner_id
      JOIN pa_membership_links l ON l.owner_id=o.owner_id
      JOIN pa_identity_credentials c ON c.owner_id=o.owner_id AND c.owner_epoch=o.epoch
      WHERE o.owner_id=? AND o.disabled=0 AND o.purge_fence_id IS NULL`)
      .bind(photoPrefix, photoPrefixUpperBound(ownerId), ownerId).first<OwnerState>();
  }

  /** Returns null for an ineligible or changed owner; no data is erased. */
  async begin(ownerId: string): Promise<PurgeFence | null> {
    if (!ownerPattern.test(ownerId)) throw unavailable();
    const initial = await this.state(ownerId);
    if (!initial || !Number.isSafeInteger(initial.epoch) || initial.epoch < 0
      || !Number.isSafeInteger(initial.generation) || initial.generation < 0
      || initial.pending_uploads !== 0 || initial.pending_deletes !== 0) return null;
    let status: VerifiedMembershipStatus;
    try { status = await this.d.statusForBillingAccount(initial.billing_account_id); }
    catch { status = 'unknown'; }
    if (status !== 'expired') {
      // A renewal or outage invalidates the old expiry episode/notice. A
      // subsequent expiry must start from freshly observed retention state.
      await this.d.retention.observe(ownerId, status);
      return null;
    }
    const candidate = await this.d.retention.expiryReviewAfterFreshCheck(ownerId, status);
    if (!candidate) return null;
    const contact = await this.d.auth.verifiedNoticeContactForExpiry(candidate);
    const evidence = await this.d.notices.verifiedFinalNoticeEvidenceForExpiry(candidate, contact);
    if (!evidence) return null;
    const now = this.now();
    const leaseExpiresAt = now + fenceLease;
    if (!Number.isSafeInteger(leaseExpiresAt)) throw unavailable();
    const fenceId = crypto.randomUUID();
    const results = await this.d.db.batch([
      this.d.db.prepare(`INSERT INTO pa_purge_fences(fence_id,owner_id,state,retention_episode,
        retention_revision,due_at,delivered_at,delivery_event_id,contact_updated_at,created_at,updated_at,
        lease_expires_at)
        VALUES(?,?,'proposed',?,?,?,?,?,?,?,?,?)`)
        .bind(fenceId, ownerId, candidate.episode, candidate.revision, candidate.dueAt,
          candidate.deliveredAt, candidate.deliveryEventId, evidence.contactUpdatedAt, now, now,
          leaseExpiresAt),
      this.d.db.prepare(`UPDATE pa_owners AS o SET disabled=1,epoch=epoch+1,purge_fence_id=?
        WHERE o.owner_id=? AND o.epoch=? AND o.disabled=0 AND o.purge_fence_id IS NULL
          AND EXISTS(SELECT 1 FROM pa_purge_fences f WHERE f.fence_id=? AND f.owner_id=o.owner_id
            AND f.state='proposed')
          AND EXISTS(SELECT 1 FROM pa_membership_links l WHERE l.owner_id=o.owner_id
            AND l.billing_account_id=?)
          AND EXISTS(SELECT 1 FROM pa_inventory i WHERE i.owner_id=o.owner_id
            AND i.generation=? AND i.reserved_bytes=0)
          AND NOT EXISTS(SELECT 1 FROM pa_uploads u WHERE u.owner_id=o.owner_id)
          AND NOT EXISTS(SELECT 1 FROM pa_pending_deletes p
            WHERE p.object_key>=? AND p.object_key<?)
          AND EXISTS(SELECT 1 FROM pa_retention r
            JOIN pa_notice_contacts c ON c.owner_id=r.owner_id
            JOIN pa_notice_submissions s ON s.owner_id=r.owner_id
              AND s.delivery_event_id=r.final_notice_receipt
            WHERE r.owner_id=o.owner_id AND r.episode=? AND r.revision=? AND r.due_at=?
              AND r.final_notice_delivered_at=? AND r.final_notice_receipt=?
              AND r.verified_status='expired' AND r.paused_at IS NULL
              AND r.checked_at>=? AND r.checked_at<=? AND r.due_at<=?
              AND r.final_notice_delivered_at<=?
              AND r.notice_not_before_at<=s.submitted_at
              AND s.evidence_version=2 AND s.episode=r.episode
              AND s.retention_revision<=r.revision AND s.delivered_at=r.final_notice_delivered_at
              AND s.provider_accepted_at IS NOT NULL AND s.due_at<=r.due_at
              AND r.due_at=MAX(s.due_at,s.delivered_at+?)
              AND c.source='apple' AND c.updated_at=?
              AND s.contact_updated_at=c.updated_at AND s.recipient_tag=?)
        RETURNING epoch`)
        .bind(fenceId, ownerId, initial.epoch, fenceId, initial.billing_account_id,
          initial.generation, photoPrefixForOwner(ownerId), photoPrefixUpperBound(ownerId),
          candidate.episode, candidate.revision, candidate.dueAt,
          candidate.deliveredAt, candidate.deliveryEventId, Math.max(0, now - day), now, now,
          Math.max(0, now - 30 * day), 30 * day, evidence.contactUpdatedAt, evidence.recipientTag),
      this.d.db.prepare(`UPDATE pa_purge_fences SET state='fenced',owner_epoch=?,
        inventory_generation=?,updated_at=? WHERE fence_id=? AND state='proposed'
        AND EXISTS(SELECT 1 FROM pa_owners o WHERE o.owner_id=pa_purge_fences.owner_id
          AND o.disabled=1 AND o.epoch=? AND o.purge_fence_id=?)`)
        .bind(initial.epoch + 1, initial.generation, now, fenceId, initial.epoch + 1, fenceId),
    ]);
    if (results[1]?.results.length !== 1 || results[2]?.meta.changes !== 1) {
      if (results[1]?.results.length === 1) {
        await abortFencedOwner(this.d.db, fenceId, ownerId, initial.epoch + 1, this.now(), 'unknown');
      }
      return null;
    }
    const fence: PurgeFence = { fenceId, ownerId, ownerEpoch: initial.epoch + 1,
      inventoryGeneration: initial.generation, candidate };
    try { status = await this.d.statusForBillingAccount(initial.billing_account_id); }
    catch { status = 'unknown'; }
    if (status !== 'expired') {
      await abortFencedOwner(this.d.db, fenceId, ownerId, fence.ownerEpoch, this.now(), status);
      return null;
    }
    return fence;
  }

  /** Only a pre-deletion fence can be undone. Future physical deletion must
   * move to a separate state so it can never use this thaw operation. */
  async abortBeforeDeletion(fenceId: string, ownerId: string, ownerEpoch: number): Promise<void> {
    await abortFencedOwner(this.d.db, fenceId, ownerId, ownerEpoch, this.now(), 'unknown');
  }
}

/** A pre-deletion abort also revokes the old notice in the same D1 batch as
 * re-enabling access. Never thaw an owner while stale deletion proof remains. */
async function abortFencedOwner(db: D1Database, fenceId: string, ownerId: string,
  ownerEpoch: number, now: number, status: Exclude<VerifiedMembershipStatus, 'expired'>): Promise<void> {
  if (!ownerPattern.test(fenceId) || !ownerPattern.test(ownerId)
      || !Number.isSafeInteger(ownerEpoch) || ownerEpoch < 1
      || ownerEpoch >= Number.MAX_SAFE_INTEGER) throw unavailable();
    const resetExpiry = status === 'active' || status === 'grace';
    const results = await db.batch([
      db.prepare(`UPDATE pa_retention SET revision=revision+1,verified_status=?,checked_at=?,
        expired_at=CASE WHEN ? THEN NULL ELSE expired_at END,
        due_at=CASE WHEN ? THEN NULL ELSE due_at END,
        paused_at=CASE WHEN ? THEN NULL ELSE ? END,
        notice_not_before_at=CASE WHEN ? THEN 0 ELSE ? END,
        final_notice_delivered_at=NULL,final_notice_receipt=NULL
        WHERE owner_id=? AND verified_status='expired' AND paused_at IS NULL
          AND EXISTS(SELECT 1 FROM pa_purge_fences f JOIN pa_owners o ON o.owner_id=f.owner_id
            WHERE f.fence_id=? AND f.owner_id=pa_retention.owner_id AND f.state='fenced'
              AND f.owner_epoch=? AND f.retention_episode=pa_retention.episode
              AND f.retention_revision=pa_retention.revision
              AND o.disabled=1 AND o.epoch=? AND o.purge_fence_id=f.fence_id)
        RETURNING revision`)
        .bind(status, now, resetExpiry, resetExpiry, resetExpiry, now, resetExpiry, now,
          ownerId, fenceId, ownerEpoch, ownerEpoch),
      db.prepare(`UPDATE pa_owners SET disabled=0,epoch=epoch+1,purge_fence_id=NULL
        WHERE owner_id=? AND disabled=1 AND epoch=? AND purge_fence_id=?
          AND EXISTS(SELECT 1 FROM pa_identity_credentials c
            WHERE c.owner_id=pa_owners.owner_id AND c.owner_epoch<=?)
          AND EXISTS(SELECT 1 FROM pa_purge_fences f JOIN pa_retention r ON r.owner_id=f.owner_id
            WHERE f.fence_id=? AND f.owner_id=? AND f.state='fenced'
              AND r.episode=f.retention_episode AND r.revision=f.retention_revision+1
              AND r.verified_status=? AND r.final_notice_delivered_at IS NULL)
        RETURNING epoch`)
        .bind(ownerId, ownerEpoch, fenceId, ownerEpoch, fenceId, ownerId, status),
      db.prepare(`UPDATE pa_identity_credentials SET owner_epoch=?
        WHERE owner_id=? AND owner_epoch<=?
          AND EXISTS(SELECT 1 FROM pa_owners o WHERE o.owner_id=pa_identity_credentials.owner_id
            AND o.disabled=0 AND o.epoch=? AND o.purge_fence_id IS NULL)
        RETURNING owner_epoch`)
        .bind(ownerEpoch + 1, ownerId, ownerEpoch, ownerEpoch + 1),
      db.prepare(`UPDATE pa_purge_fences SET state='aborted',updated_at=?
        WHERE fence_id=? AND owner_id=? AND state='fenced' AND owner_epoch=?
          AND NOT EXISTS(SELECT 1 FROM pa_owners WHERE owner_id=? AND purge_fence_id=?)
          AND EXISTS(SELECT 1 FROM pa_identity_credentials c
            WHERE c.owner_id=pa_purge_fences.owner_id AND c.owner_epoch=?)
        RETURNING state`)
        .bind(now, fenceId, ownerId, ownerEpoch, ownerId, fenceId, ownerEpoch + 1),
    ]);
    if (results.some(result => result?.results.length !== 1)) throw unavailable();
}

/** Crash recovery for a lease that was fenced but never entered deletion.
 * Future physical purge must transition out of `fenced` before its first
 * destructive action; that later state must not be recoverable here. Once
 * owner recovery snapshots are required, D1 alone cannot prove that S3 has
 * no erasing event. Leave such owners disabled for external-ledger recovery.
 */
export async function recoverAbandonedPurgeFences(db: D1Database, now: number, limit = 20): Promise<number> {
  if (!Number.isSafeInteger(now) || now <= 30 * day
    || !Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw unavailable();
  const rows = await db.prepare(`SELECT f.fence_id,f.owner_id,f.owner_epoch
    FROM pa_purge_fences f JOIN pa_owners o ON o.owner_id=f.owner_id
    WHERE f.state='fenced' AND f.lease_expires_at<=? AND o.disabled=1
      AND o.epoch=f.owner_epoch AND o.purge_fence_id=f.fence_id
      AND (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=0
    ORDER BY f.lease_expires_at,f.fence_id LIMIT ?`).bind(now, limit)
    .all<{ fence_id: string; owner_id: string; owner_epoch: number }>();
  for (const row of rows.results) {
    await abortFencedOwner(db, row.fence_id, row.owner_id, row.owner_epoch, now, 'unknown');
  }
  return rows.results.length;
}
