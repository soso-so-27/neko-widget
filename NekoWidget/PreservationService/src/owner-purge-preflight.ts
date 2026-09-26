import { ServiceError } from './contracts';
import { verifyFencedPurgeEligibility } from './fenced-purge-eligibility';
import { inventoryOwnerCloudStorage } from './owner-cloud-inventory';
import { reconcileFencedPurgePrimaryInventory } from './owner-primary-reconciliation';
import { buildOwnerPurgeManifest, type PurgeManifest } from './owner-purge-manifest';
import type { OwnerPurgeManifestLedger } from './owner-purge-manifest-ledger';
import type { PurgeFence } from './owner-purge-fence';
import { loadOwnerPurgeTimeline } from './purge-intent-replay';
import type { VerifiedMembershipStatus } from './retention-ledger';
import type { S3PurgeIntentStore } from './s3-purge-intent';
import type { S3RecoveryCopy } from './s3-recovery-copy';

const unavailable = () => new ServiceError('OWNER_PURGE_PREFLIGHT_UNAVAILABLE', 503);

/** Read-only three-pass inventory plus immutable staging. This never appends
 * an erasing event, claims deletion or calls delete. A separately reviewed
 * controller must resume bounded chunks and recheck the lease; do not invoke
 * a large plan in a single Worker event with limited subrequests.
 */
export class OwnerPurgePreflight {
  constructor(private readonly db: D1Database,
    private readonly bucket: R2Bucket,
    private readonly recovery: S3RecoveryCopy,
    private readonly intentStore: Pick<S3PurgeIntentStore,
      'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>,
    private readonly ledger: OwnerPurgeManifestLedger,
    private readonly now: () => number,
    private readonly statusForBillingAccount: (accountId: string) => Promise<VerifiedMembershipStatus>) {}

  private async eligible(fence: PurgeFence): Promise<void> {
    if (!await verifyFencedPurgeEligibility(this.db, fence, this.now(),
      this.statusForBillingAccount)) throw unavailable();
  }

  private async prepared(fence: PurgeFence): Promise<void> {
    const timeline = await loadOwnerPurgeTimeline(this.intentStore, fence.ownerId);
    const own = timeline.intents.find(item => item.intentId === fence.fenceId);
    if (timeline.replay !== 'quarantined' || !own || own.stage !== 'prepared'
      || own.ownerEpoch !== fence.ownerEpoch
      || own.inventoryGeneration !== fence.inventoryGeneration
      || own.retentionEpisode !== fence.candidate.episode
      || own.retentionRevision !== fence.candidate.revision
      || own.dueAt !== fence.candidate.dueAt
      || timeline.intents.some(item => item.intentId !== fence.fenceId
        && item.stage !== 'aborted')) throw unavailable();
  }

  private async scan(fence: PurgeFence): Promise<PurgeManifest> {
    const primary = await reconcileFencedPurgePrimaryInventory(this.db, this.bucket, fence.ownerId);
    const cloud = await inventoryOwnerCloudStorage(this.bucket, this.recovery, fence.ownerId);
    return buildOwnerPurgeManifest(fence, primary, cloud);
  }

  async stage(fence: PurgeFence): Promise<PurgeManifest> {
    try {
      await this.eligible(fence);
      await this.prepared(fence);
      const first = await this.scan(fence);
      const second = await this.scan(fence);
      if (first.sha256 !== second.sha256) throw unavailable();
      await this.eligible(fence);
      await this.ledger.open(first, this.now());
      for (let i = 0; i < first.chunks.length; i++) {
        await this.ledger.appendChunk(first, i);
      }
      await this.ledger.seal(first, this.now());
      const last = await this.scan(fence);
      if (first.sha256 !== last.sha256) throw unavailable();
      await this.eligible(fence);
      await this.prepared(fence);
      return first;
    } catch { throw unavailable(); }
  }
}
