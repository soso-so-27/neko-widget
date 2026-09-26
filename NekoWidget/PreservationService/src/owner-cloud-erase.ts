import { ServiceError } from './contracts';
import { inventoryOwnerCloudStorage } from './owner-cloud-inventory';
import { remainingCloudItems } from './owner-cloud-subset';
import { verifyOwnerCloudEmpty } from './owner-cloud-empty';
import { requestManifestPhotoDeletion } from './r2-photo-purge';
import { loadOwnerPurgeTimeline } from './purge-intent-replay';
import type { VerifiedMembershipStatus } from './retention-ledger';
import type { S3PurgeIntentStore } from './s3-purge-intent';
import type { S3PurgeManifestStore } from './s3-purge-manifest';
import type { S3RecoveryCopy } from './s3-recovery-copy';
import type { S3VersionPurge } from './s3-version-purge';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const hex = /^[0-9a-f]{64}$/u;
const unavailable = () => new ServiceError('OWNER_CLOUD_ERASE_UNAVAILABLE', 503);
type Authority = { billing_account_id: string; manifest_sha256: string;
  owner_epoch: number; inventory_generation: number;
  retention_episode: number; retention_revision: number; due_at: number };
type Dependencies = { db: D1Database; bucket: R2Bucket;
  recovery: S3RecoveryCopy; versionPurge: Pick<S3VersionPurge,
    'requestExactVersionDeletion'>;
  intentStore: Pick<S3PurgeIntentStore,
    'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>;
  planStore: Pick<S3PurgeManifestStore, 'loadPublished'>;
  statusForBillingAccount: (accountId: string) => Promise<VerifiedMembershipStatus>;
  enabled: string | undefined };
export type CloudEraseStep = { state: 'progress'; kind: 'r2' | 's3' }
  | { state: 'empty' };

/** Non-public, default-off executor for one externally planned object/version
 * per invocation. A renewed or unknown membership stops further deletion and
 * leaves the owner quarantined for a separately decided recovery policy. The
 * final billing race/renewal semantics are unresolved; do not wire to a
 * scheduler or use on real owner data until that product decision and an
 * independent safety review are complete.
 */
export class OwnerCloudEraser {
  constructor(private readonly d: Dependencies) {}

  private authority(ownerId: string, intentId: string): Promise<Authority | null> {
    return this.d.db.prepare(`SELECT l.billing_account_id,c.manifest_sha256,
      c.owner_epoch,c.inventory_generation,c.retention_episode,
      c.retention_revision,c.due_at
      FROM pa_purge_d1_erasing_authority a
      JOIN pa_purge_execution_claims c ON c.owner_id=a.owner_id
        AND c.intent_id=a.intent_id
      JOIN pa_membership_links l ON l.owner_id=a.owner_id
      WHERE a.owner_id=? AND a.intent_id=?`)
      .bind(ownerId, intentId).first<Authority>();
  }

  async step(ownerId: string, intentId: string,
    rootSha256: string): Promise<CloudEraseStep> {
    if (this.d.enabled !== 'YES' || !uuid.test(ownerId) || !uuid.test(intentId)
      || !hex.test(rootSha256)) throw unavailable();
    try {
      const timeline = await loadOwnerPurgeTimeline(this.d.intentStore, ownerId);
      const own = timeline.intents.find(item => item.intentId === intentId);
      if (timeline.replay !== 'quarantined' || own?.stage !== 'erasing'
        || own.manifestSha256 !== rootSha256
        || timeline.intents.some(item => item.intentId !== intentId
          && item.stage !== 'aborted')) throw unavailable();
      const plan = await this.d.planStore.loadPublished(ownerId, intentId, rootSha256);
      const before = await this.authority(ownerId, intentId);
      if (!before || before.manifest_sha256 !== rootSha256
        || before.owner_epoch !== own.ownerEpoch
        || before.inventory_generation !== own.inventoryGeneration
        || before.retention_episode !== own.retentionEpisode
        || before.retention_revision !== own.retentionRevision
        || before.due_at !== own.dueAt
        || plan.ownerId !== ownerId || plan.intentId !== intentId
        || plan.sha256 !== rootSha256 || plan.ownerEpoch !== own.ownerEpoch
        || plan.inventoryGeneration !== own.inventoryGeneration) throw unavailable();
      if (await this.d.statusForBillingAccount(before.billing_account_id)
        !== 'expired') throw unavailable();
      const a = await inventoryOwnerCloudStorage(this.d.bucket, this.d.recovery, ownerId);
      const b = await inventoryOwnerCloudStorage(this.d.bucket, this.d.recovery, ownerId);
      const left = remainingCloudItems(plan, a);
      const right = remainingCloudItems(plan, b);
      if (JSON.stringify(left) !== JSON.stringify(right)) throw unavailable();
      const after = await this.authority(ownerId, intentId);
      if (!after || JSON.stringify(before) !== JSON.stringify(after)
        || await this.d.statusForBillingAccount(after.billing_account_id)
          !== 'expired') throw unavailable();
      const photo = left.r2[0];
      const version = left.s3[0];
      if (!photo && !version) {
        await verifyOwnerCloudEmpty(this.d.bucket, this.d.recovery, ownerId);
        return { state: 'empty' };
      }
      if (photo) {
        if (await requestManifestPhotoDeletion(this.d.bucket, ownerId, photo)
          !== 'deleted') throw unavailable();
      }
      else await this.d.versionPurge.requestExactVersionDeletion(ownerId, version!);
      const next = remainingCloudItems(plan,
        await inventoryOwnerCloudStorage(this.d.bucket, this.d.recovery, ownerId));
      if (photo ? next.r2.some(item => item.key === photo.key)
        : next.s3.some(item => item.key === version!.key
          && item.versionId === version!.versionId)) throw unavailable();
      return { state: 'progress', kind: photo ? 'r2' : 's3' };
    } catch { throw unavailable(); }
  }
}
