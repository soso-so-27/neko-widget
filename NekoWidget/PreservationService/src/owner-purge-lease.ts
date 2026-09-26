import { ServiceError } from './contracts';
import { verifyFencedPurgeEligibility } from './fenced-purge-eligibility';
import type { PurgeFence } from './owner-purge-fence';
import type { VerifiedMembershipStatus } from './retention-ledger';

const unavailable = () => new ServiceError('PURGE_LEASE_RENEWAL_UNAVAILABLE', 503);
const leaseDuration = 10 * 60_000;

/** Extends an unexpired, pre-erasure fence only after fresh private billing
 * and owner/notice checks. This does not authorize or perform deletion. A
 * missed lease cannot be revived by this method; it stays quarantined until
 * an independent abort or a new, separately reviewed recovery procedure.
 */
export async function renewFencedPurgeLease(db: D1Database, fence: PurgeFence,
  now: number, statusForBillingAccount: (accountId: string) => Promise<VerifiedMembershipStatus>
): Promise<number> {
  try {
    if (!Number.isSafeInteger(now) || !Number.isSafeInteger(now + leaseDuration)
      || !await verifyFencedPurgeEligibility(db, fence, now, statusForBillingAccount)) {
      throw unavailable();
    }
    const result = await db.prepare(`UPDATE pa_purge_fences AS f
      SET lease_expires_at=MAX(lease_expires_at,?),updated_at=?
      WHERE f.fence_id=? AND f.owner_id=? AND f.state='fenced'
        AND f.owner_epoch=? AND f.inventory_generation=?
        AND f.retention_episode=? AND f.retention_revision=? AND f.due_at=?
        AND f.lease_expires_at>?
        AND NOT EXISTS(SELECT 1 FROM pa_purge_execution_claims c
          WHERE c.owner_id=f.owner_id AND c.intent_id=f.fence_id)
        AND EXISTS(SELECT 1 FROM pa_owners o WHERE o.owner_id=f.owner_id
          AND o.disabled=1 AND o.epoch=f.owner_epoch AND o.purge_fence_id=f.fence_id)
      RETURNING lease_expires_at`)
      .bind(now + leaseDuration, now, fence.fenceId, fence.ownerId,
        fence.ownerEpoch, fence.inventoryGeneration, fence.candidate.episode,
        fence.candidate.revision, fence.candidate.dueAt, now)
      .all<{ lease_expires_at: number }>();
    const expiry = result.results[0]?.lease_expires_at;
    if (result.results.length !== 1 || !Number.isSafeInteger(expiry)
      || expiry! <= now
      || !await verifyFencedPurgeEligibility(db, fence, now, statusForBillingAccount)) {
      throw unavailable();
    }
    return expiry!;
  } catch { throw unavailable(); }
}
