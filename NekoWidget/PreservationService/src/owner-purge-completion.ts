import { ServiceError } from './contracts';
import { verifyOwnerCloudEmpty } from './owner-cloud-empty';
import { inspectOwnerD1Residue } from './owner-d1-residue';
import type { OwnerPurgeIntentLedger } from './owner-purge-intent-ledger';
import { loadOwnerPurgeTimeline } from './purge-intent-replay';
import type { S3PurgeIntentStore } from './s3-purge-intent';
import type { S3PurgeManifestStore } from './s3-purge-manifest';
import type { S3RecoveryCopy } from './s3-recovery-copy';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const hex = /^[0-9a-f]{64}$/u;
const unavailable = () => new ServiceError('OWNER_PURGE_COMPLETION_UNAVAILABLE', 503);

type Claim = { state: 'erasing' | 'completed'; owner_epoch: number;
  inventory_generation: number; retention_episode: number;
  retention_revision: number; due_at: number; manifest_sha256: string;
  claimed_at: number; finished_at: number | null };
type Dependencies = { db: D1Database; bucket: R2Bucket; recovery: S3RecoveryCopy;
  intentStore: Pick<S3PurgeIntentStore,
    'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>;
  intentLedger: Pick<OwnerPurgeIntentLedger, 'append'>;
  planStore: Pick<S3PurgeManifestStore, 'loadPublished'>;
  now: () => number; enabled: string | undefined };

/** Private terminal transition, not a public route. When S3 accepted the
 * completed event but D1 failed, replay supplies the exact original time so
 * append() can retry the same immutable event. It never declares completion
 * merely from an empty DB or a successful delete request.
 */
export class OwnerPurgeCompletion {
  constructor(private readonly d: Dependencies) {}

  async complete(ownerId: string, intentId: string, rootSha256: string): Promise<void> {
    if (this.d.enabled !== 'YES' || !uuid.test(ownerId) || !uuid.test(intentId)
      || !hex.test(rootSha256)) throw unavailable();
    try {
      const timeline = await loadOwnerPurgeTimeline(this.d.intentStore, ownerId);
      const own = timeline.intents.find(item => item.intentId === intentId);
      if (!own || !['erasing', 'completed'].includes(own.stage)
        || own.manifestSha256 !== rootSha256
        || timeline.intents.some(item => item.intentId !== intentId
          && item.stage !== 'aborted')) throw unavailable();
      const plan = await this.d.planStore.loadPublished(ownerId, intentId, rootSha256);
      if (plan.ownerId !== ownerId || plan.intentId !== intentId
        || plan.sha256 !== rootSha256 || plan.ownerEpoch !== own.ownerEpoch
        || plan.inventoryGeneration !== own.inventoryGeneration) throw unavailable();
      const claim = await this.d.db.prepare(`SELECT state,owner_epoch,
        inventory_generation,retention_episode,retention_revision,due_at,
        manifest_sha256,claimed_at,finished_at FROM pa_purge_execution_claims
        WHERE owner_id=? AND intent_id=?`).bind(ownerId, intentId).first<Claim>();
      if (!claim || !['erasing', 'completed'].includes(claim.state)
        || claim.manifest_sha256 !== rootSha256
        || claim.owner_epoch !== own.ownerEpoch
        || claim.inventory_generation !== own.inventoryGeneration
        || claim.retention_episode !== own.retentionEpisode
        || claim.retention_revision !== own.retentionRevision
        || claim.due_at !== own.dueAt
        || (claim.state === 'completed' && own.stage !== 'completed')) throw unavailable();
      await verifyOwnerCloudEmpty(this.d.bucket, this.d.recovery, ownerId);
      const residue = await inspectOwnerD1Residue(this.d.db, ownerId);
      if (residue.contentTotal !== 0 || residue.pendingPhotoDeletes !== 0
        || residue.purgeWork.pa_purge_fences !== 0
        || Object.values(residue.ownerCursors).some(Boolean)
        || Object.values(residue.recoveryRepairCursors).some(Boolean)) {
        throw unavailable();
      }
      const recordedAt = own.stage === 'completed' ? own.recordedAt
        : Math.max(this.d.now(), own.recordedAt + 1, claim.claimed_at);
      if (!Number.isSafeInteger(recordedAt) || recordedAt < own.recordedAt) {
        throw unavailable();
      }
      await this.d.intentLedger.append({ version: 1, ownerId, intentId,
        stage: 'completed', ownerEpoch: own.ownerEpoch,
        inventoryGeneration: own.inventoryGeneration,
        retentionEpisode: own.retentionEpisode,
        retentionRevision: own.retentionRevision, dueAt: own.dueAt,
        recordedAt, manifestSha256: rootSha256 });
      if (claim.state === 'erasing') {
        const result = await this.d.db.prepare(`UPDATE pa_purge_execution_claims
          SET state='completed',finished_at=? WHERE owner_id=? AND intent_id=?
            AND state='erasing' AND manifest_sha256=?`)
          .bind(recordedAt, ownerId, intentId, rootSha256).run();
        if (result.meta.changes !== 1) throw unavailable();
      }
      const final = await this.d.db.prepare(`SELECT state,finished_at
        FROM pa_purge_execution_claims WHERE owner_id=? AND intent_id=?`)
        .bind(ownerId, intentId)
        .first<{ state: string; finished_at: number | null }>();
      if (final?.state !== 'completed' || final.finished_at === null
        || final.finished_at < recordedAt) throw unavailable();
    } catch { throw unavailable(); }
  }
}
