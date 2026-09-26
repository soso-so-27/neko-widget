import { ServiceError } from './contracts';
import type { OwnerPurgeAbort } from './owner-purge-abort';
import { abortFencedOwner, type PurgeFence } from './owner-purge-fence';
import { reconcileFencedPrimaryInventory } from './owner-primary-reconciliation';
import { loadOwnerPurgeTimeline } from './purge-intent-replay';
import type { VerifiedMembershipStatus } from './retention-ledger';
import type { S3PurgeIntentStore } from './s3-purge-intent';
import type { OwnerRecoveryCopy } from './owner-recovery-copy';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const unavailable = () => new ServiceError('OWNER_PURGE_RELEASE_UNAVAILABLE', 503);

interface ReleaseState { billing_account_id: string; owner_epoch: number;
  inventory_generation: number; claim_state: string }

/** Re-enables only a pre-deletion abort, after two primary inventories and a
 * full S3 version replay. It is not exposed by the public Worker or scheduler.
 * A missing photo, disputed identity or failed dependency leaves the owner
 * disabled for offline investigation; it never guesses missing bytes.
 */
export class OwnerPurgeRelease {
  constructor(private readonly db: D1Database,
    private readonly bucket: R2Bucket,
    private readonly store: Pick<S3PurgeIntentStore,
      'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>,
    private readonly aborter: Pick<OwnerPurgeAbort, 'claimAndRecordAbort'>,
    private readonly ownerRecovery: Pick<OwnerRecoveryCopy, 'copyCurrent'>,
    private readonly now: () => number,
    private readonly statusForBillingAccount: (accountId: string) => Promise<VerifiedMembershipStatus>) {}

  private async state(fence: PurgeFence): Promise<ReleaseState | null> {
    return this.db.prepare(`SELECT l.billing_account_id,o.epoch AS owner_epoch,
      i.generation AS inventory_generation,c.state AS claim_state
      FROM pa_owners o JOIN pa_purge_fences f ON f.owner_id=o.owner_id
      JOIN pa_purge_execution_claims c ON c.owner_id=f.owner_id
        AND c.intent_id=f.fence_id
      JOIN pa_inventory i ON i.owner_id=o.owner_id
      JOIN pa_membership_links l ON l.owner_id=o.owner_id
      WHERE o.owner_id=? AND o.disabled=1 AND o.epoch=?
        AND o.purge_fence_id=? AND f.fence_id=? AND f.state='fenced'
        AND f.owner_epoch=o.epoch AND f.inventory_generation=i.generation
        AND f.retention_episode=? AND f.retention_revision=? AND f.due_at=?
        AND c.state='aborted' AND c.owner_epoch=f.owner_epoch
        AND c.inventory_generation=f.inventory_generation
        AND c.retention_episode=f.retention_episode
        AND c.retention_revision=f.retention_revision AND c.due_at=f.due_at`)
      .bind(fence.ownerId, fence.ownerEpoch, fence.fenceId, fence.fenceId,
        fence.candidate.episode, fence.candidate.revision,
        fence.candidate.dueAt).first<ReleaseState>();
  }

  private async requireExternalAbort(fence: PurgeFence): Promise<void> {
    const timeline = await loadOwnerPurgeTimeline(this.store, fence.ownerId);
    const own = timeline.intents.find(item => item.intentId === fence.fenceId);
    if (timeline.replay !== 'clear' || !own || own.stage !== 'aborted'
      || own.ownerEpoch !== fence.ownerEpoch
      || own.inventoryGeneration !== fence.inventoryGeneration
      || own.retentionEpisode !== fence.candidate.episode
      || own.retentionRevision !== fence.candidate.revision
      || own.dueAt !== fence.candidate.dueAt
      || timeline.intents.some(item => item.stage !== 'aborted')) throw unavailable();
  }

  async release(fence: PurgeFence): Promise<void> {
    if (!fence || !uuid.test(fence.ownerId) || !uuid.test(fence.fenceId)
      || fence.candidate?.ownerId !== fence.ownerId
      || !Number.isSafeInteger(fence.ownerEpoch) || fence.ownerEpoch < 1
      || !Number.isSafeInteger(fence.inventoryGeneration)
      || fence.inventoryGeneration < 0) throw unavailable();
    try {
      await this.aborter.claimAndRecordAbort(fence);
      const firstState = await this.state(fence);
      if (!firstState || firstState.claim_state !== 'aborted'
        || firstState.owner_epoch !== fence.ownerEpoch
        || firstState.inventory_generation !== fence.inventoryGeneration) throw unavailable();
      const first = await reconcileFencedPrimaryInventory(this.db, this.bucket, fence.ownerId);
      if (first.epoch !== fence.ownerEpoch || first.generation !== fence.inventoryGeneration) {
        throw unavailable();
      }
      await this.requireExternalAbort(fence);
      let status: VerifiedMembershipStatus;
      try { status = await this.statusForBillingAccount(firstState.billing_account_id); }
      catch { status = 'unknown'; }
      const second = await reconcileFencedPrimaryInventory(this.db, this.bucket, fence.ownerId);
      const secondState = await this.state(fence);
      if (JSON.stringify(first) !== JSON.stringify(second)
        || JSON.stringify(firstState) !== JSON.stringify(secondState)) throw unavailable();
      await this.requireExternalAbort(fence);
      const at = this.now();
      if (!Number.isSafeInteger(at) || at < fence.candidate.dueAt) throw unavailable();
      await abortFencedOwner(this.db, fence.fenceId, fence.ownerId,
        fence.ownerEpoch, at, status);
      // The release transaction advances the owner generation. Until its
      // independent S3 image is verified, requireSession stays closed.
      await this.ownerRecovery.copyCurrent(this.db, fence.ownerId, at);
      const final = await this.db.prepare(`SELECT disabled,epoch,purge_fence_id FROM pa_owners
        WHERE owner_id=?`).bind(fence.ownerId)
        .first<{ disabled: number; epoch: number; purge_fence_id: string | null }>();
      if (!final || final.disabled !== 0 || final.epoch !== fence.ownerEpoch + 1
        || final.purge_fence_id !== null) throw unavailable();
    } catch { throw unavailable(); }
  }
}
