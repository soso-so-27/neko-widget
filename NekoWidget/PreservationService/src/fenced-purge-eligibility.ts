import { ServiceError } from './contracts';
import type { PurgeFence } from './owner-purge-fence';
import type { VerifiedMembershipStatus } from './retention-ledger';

const day = 86_400_000;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const unavailable = () => new ServiceError('FENCED_PURGE_ELIGIBILITY_UNAVAILABLE', 503);

interface Evidence {
  billing_account_id: string;
  identity_key: string;
  owner_epoch: number;
  inventory_generation: number;
  retention_episode: number;
  retention_revision: number;
  due_at: number;
  delivered_at: number;
  delivery_event_id: string;
  contact_updated_at: number;
  checked_at: number;
  notice_not_before_at: number;
  sealed_email_hex: string;
  recipient_tag: string;
  submitted_at: number;
  provider_accepted_at: number;
  lease_expires_at: number;
}

/** Fresh private billing plus a double-read of the exact disabled owner,
 * fence, notice and inventory evidence. This is read-only and NOT deletion
 * authority: S3 purge intent replay, a stable manifest and another check
 * immediately before each physical delete are still required.
 */
export async function verifyFencedPurgeEligibility(db: D1Database, fence: PurgeFence,
  now: number, statusForBillingAccount: (accountId: string) => Promise<VerifiedMembershipStatus>
): Promise<boolean> {
  if (!fence || !uuid.test(fence.ownerId) || !uuid.test(fence.fenceId)
    || !Number.isSafeInteger(fence.ownerEpoch) || fence.ownerEpoch < 1
    || !Number.isSafeInteger(fence.inventoryGeneration) || fence.inventoryGeneration < 0
    || !fence.candidate || fence.candidate.ownerId !== fence.ownerId
    || !Number.isSafeInteger(fence.candidate.episode) || fence.candidate.episode < 1
    || !Number.isSafeInteger(fence.candidate.revision) || fence.candidate.revision < 1
    || !Number.isSafeInteger(fence.candidate.dueAt) || fence.candidate.dueAt < 1
    || !Number.isSafeInteger(fence.candidate.deliveredAt) || fence.candidate.deliveredAt < 1
    || typeof fence.candidate.deliveryEventId !== 'string'
    || fence.candidate.deliveryEventId.length < 16
    || !Number.isSafeInteger(now) || now <= 30 * day) throw unavailable();
  const prefix = `personal/${fence.ownerId}/`;
  const upper = `personal/${fence.ownerId}0`;
  const read = () => db.prepare(`SELECT l.billing_account_id,o.identity_key,
      f.owner_epoch,f.inventory_generation,
      f.retention_episode,f.retention_revision,f.due_at,f.delivered_at,f.delivery_event_id,
      f.contact_updated_at,f.lease_expires_at,r.checked_at,r.notice_not_before_at,
      hex(c.sealed_email) AS sealed_email_hex,s.recipient_tag,s.submitted_at,
      s.provider_accepted_at
    FROM pa_purge_fences f JOIN pa_owners o ON o.owner_id=f.owner_id
      JOIN pa_inventory i ON i.owner_id=f.owner_id
      JOIN pa_membership_links l ON l.owner_id=f.owner_id
      JOIN pa_retention r ON r.owner_id=f.owner_id
      JOIN pa_notice_contacts c ON c.owner_id=f.owner_id
      JOIN pa_notice_submissions s ON s.owner_id=f.owner_id
        AND s.delivery_event_id=f.delivery_event_id
    WHERE f.fence_id=? AND f.owner_id=? AND f.state='fenced'
      AND f.owner_epoch=? AND f.inventory_generation=?
      AND f.retention_episode=? AND f.retention_revision=?
      AND f.due_at=? AND f.delivered_at=? AND f.delivery_event_id=?
      AND o.disabled=1 AND o.epoch=f.owner_epoch AND o.purge_fence_id=f.fence_id
      AND i.generation=f.inventory_generation AND i.reserved_bytes=0
      AND NOT EXISTS(SELECT 1 FROM pa_uploads u WHERE u.owner_id=f.owner_id)
      AND NOT EXISTS(SELECT 1 FROM pa_recovery_write_leases w WHERE w.owner_id=f.owner_id)
      AND NOT EXISTS(SELECT 1 FROM pa_pending_deletes p
        WHERE p.object_key>=? AND p.object_key<?)
      AND r.episode=f.retention_episode AND r.revision=f.retention_revision
      AND r.verified_status='expired' AND r.paused_at IS NULL
      AND r.due_at=f.due_at AND r.final_notice_delivered_at=f.delivered_at
      AND r.final_notice_receipt=f.delivery_event_id
      AND r.checked_at>=f.created_at-? AND r.checked_at<=f.created_at
      AND f.due_at<=? AND f.delivered_at<=? AND f.lease_expires_at>?
      AND c.source='apple' AND c.updated_at=f.contact_updated_at
      AND s.evidence_version=2 AND s.episode=f.retention_episode
      AND s.retention_revision<=f.retention_revision
      AND s.due_at<=f.due_at AND s.delivered_at=f.delivered_at
      AND s.provider_accepted_at IS NOT NULL
      AND s.contact_updated_at=c.updated_at
      AND length(s.recipient_tag)=64
      AND s.submitted_at>=r.notice_not_before_at
      AND f.due_at=MAX(s.due_at,s.delivered_at+?)`)
    .bind(fence.fenceId, fence.ownerId, fence.ownerEpoch, fence.inventoryGeneration,
      fence.candidate.episode, fence.candidate.revision, fence.candidate.dueAt,
      fence.candidate.deliveredAt, fence.candidate.deliveryEventId,
      prefix, upper, day, now, Math.max(0, now - 30 * day), now, 30 * day).first<Evidence>();
  try {
    const before = await read();
    if (!before || typeof before.billing_account_id !== 'string') return false;
    let status: VerifiedMembershipStatus;
    try { status = await statusForBillingAccount(before.billing_account_id); }
    catch { return false; }
    if (status !== 'expired') return false;
    const after = await read();
    return after !== null && JSON.stringify(before) === JSON.stringify(after);
  } catch { throw unavailable(); }
}
