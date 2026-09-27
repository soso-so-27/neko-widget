import { ServiceError } from './contracts';
import { verifyOwnerCloudEmpty } from './owner-cloud-empty';
import { inspectOwnerD1Residue } from './owner-d1-residue';
import type { PurgeIntentCursor, PurgeIntentReference, PurgeIntentVersion,
  S3PurgeIntentStore } from './s3-purge-intent';
import type { PurgeManifestCopyCursor, PurgeManifestCopyVersion,
  S3PurgeManifestStore } from './s3-purge-manifest';
import type { S3PurgeEvidenceDelete } from './s3-purge-evidence-delete';
import type { S3RecoveryCopy } from './s3-recovery-copy';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const identifier = new RegExp(`^${uuid}$`, 'u');
const eventKey = new RegExp(`^purge/v1/(${uuid})/(${uuid})/(?:prepared|aborted|erasing|completed)$`, 'u');
const planKey = new RegExp(`^purge-plan/v1/(${uuid})/(${uuid})/(?:header|chunk/[0-9]{6})$`, 'u');
const day = 86_400_000;
const maximumBatch = 128;
const unavailable = () => new ServiceError('PURGE_EVIDENCE_CLEANUP_UNAVAILABLE', 503);

type Dependencies = {
  db: D1Database;
  bucket: R2Bucket;
  recovery: S3RecoveryCopy;
  intentStore: Pick<S3PurgeIntentStore,
    'readExact' | 'listOwnerVersionsPage'>;
  planStore: Pick<S3PurgeManifestStore, 'listOwnerEvidenceVersionsPage'>;
  deleteStore: Pick<S3PurgeEvidenceDelete,
    'requestPlanVersionDeletion' | 'requestEventVersionDeletion'>;
  /** Must directly check that D1 cannot restore to the completed timestamp.
   * Age alone, an unverified local clock, or a manual assertion is insufficient.
   */
  restoreWindowClosed: (completedAt: number) => Promise<boolean>;
  now: () => number;
  enabled: string | undefined;
};
export type S3EvidenceCleanupStep = { state: 'progress'; kind: 'plan' | 'event';
  removed: number; overdue: boolean } | { state: 's3-cleared'; overdue: boolean };

/** Private, default-off second phase. A verified completed version remains
 * until every plan and other event version is gone. Every step re-lists from
 * the beginning, so a lost response never requires a D1 resume cursor.
 * This is not wired to a Worker route or cron until a real Time Travel floor
 * verifier and an isolated-restore drill exist.
 */
export class OwnerS3EvidenceCleanup {
  constructor(private readonly d: Dependencies) {}

  private async eventInventory(ownerId: string): Promise<PurgeIntentVersion[]> {
    const versions: PurgeIntentVersion[] = [];
    const cursors = new Set<string>();
    let cursor: PurgeIntentCursor | undefined;
    while (true) {
      const page = await this.d.intentStore.listOwnerVersionsPage(ownerId, cursor);
      versions.push(...page.versions);
      if (!page.nextCursor) return versions;
      const marker = JSON.stringify(page.nextCursor);
      if (cursors.has(marker)) throw unavailable();
      cursors.add(marker);
      cursor = page.nextCursor;
    }
  }

  private async planInventory(ownerId: string): Promise<PurgeManifestCopyVersion[]> {
    const versions: PurgeManifestCopyVersion[] = [];
    const cursors = new Set<string>();
    let cursor: PurgeManifestCopyCursor | undefined;
    while (true) {
      const page = await this.d.planStore.listOwnerEvidenceVersionsPage(ownerId, cursor);
      versions.push(...page.versions);
      if (!page.nextCursor) return versions;
      const marker = JSON.stringify(page.nextCursor);
      if (cursors.has(marker)) throw unavailable();
      cursors.add(marker);
      cursor = page.nextCursor;
    }
  }

  async step(ownerId: string, intentId: string,
    completedRef: PurgeIntentReference): Promise<S3EvidenceCleanupStep> {
    if (this.d.enabled !== 'YES' || !identifier.test(ownerId) || !identifier.test(intentId)
      || completedRef?.key !== `purge/v1/${ownerId}/${intentId}/completed`) throw unavailable();
    try {
      const now = this.d.now();
      if (!Number.isSafeInteger(now)) throw unavailable();
      await verifyOwnerCloudEmpty(this.d.bucket, this.d.recovery, ownerId);
      const residue = await inspectOwnerD1Residue(this.d.db, ownerId);
      if (residue.contentTotal || residue.purgeWorkTotal || residue.pendingPhotoDeletes
        || Object.values(residue.ownerCursors).some(Boolean)
        || Object.values(residue.recoveryRepairCursors).some(Boolean)) throw unavailable();

      // A missing completed version is never proof of success: it can also
      // mean premature removal while an older D1 restore is still possible.
      const completed = await this.d.intentStore.readExact(completedRef);
      if (completed.ownerId !== ownerId || completed.intentId !== intentId
        || completed.stage !== 'completed' || !completed.manifestSha256
        || !Number.isSafeInteger(completed.recordedAt)
        || now < completed.recordedAt + 31 * day
        || !await this.d.restoreWindowClosed(completed.recordedAt)) throw unavailable();
      const overdue = now > completed.recordedAt + 35 * day;

      // Inspect the complete inventory before the first irreversible delete.
      // S3 is allowed to truncate before MaxKeys, including a page with only
      // the completed event and more events in subsequent pages.
      const [plans, events] = await Promise.all([
        this.planInventory(ownerId), this.eventInventory(ownerId),
      ]);
      const seenPlans = new Set<string>();
      for (const item of plans) {
        const match = planKey.exec(item.key);
        const identity = `${item.key}\0${item.versionId}`;
        if (!match || match[1] !== ownerId || seenPlans.has(identity)) throw unavailable();
        seenPlans.add(identity);
      }
      const seenEvents = new Set<string>();
      let exactCompleted = 0;
      for (const item of events) {
        const match = eventKey.exec(item.key);
        const identity = `${item.key}\0${item.versionId}`;
        if (!match || match[1] !== ownerId || seenEvents.has(identity)) throw unavailable();
        seenEvents.add(identity);
        if (item.key.endsWith('/completed')) {
          if (item.key !== completedRef.key || item.versionId !== completedRef.versionId
            || item.deleteMarker || item.bytes !== completedRef.bytes) throw unavailable();
          exactCompleted++;
        }
      }
      if (exactCompleted !== 1) throw unavailable();
      if (plans.length) {
        const items = plans.slice(0, maximumBatch);
        for (const item of items) {
          const match = planKey.exec(item.key)!;
          await this.d.deleteStore.requestPlanVersionDeletion(ownerId, match[2]!, item);
        }
        return { state: 'progress', kind: 'plan', removed: items.length, overdue };
      }
      const others = events.filter(item => item.key !== completedRef.key
        || item.versionId !== completedRef.versionId);
      if (others.length) {
        const items = others.slice(0, maximumBatch);
        for (const item of items) {
          const match = eventKey.exec(item.key);
          if (!match || match[1] !== ownerId) throw unavailable();
          await this.d.deleteStore.requestEventVersionDeletion(ownerId, match[2]!, item);
        }
        return { state: 'progress', kind: 'event', removed: items.length, overdue };
      }
      if (events.length !== 1) throw unavailable();
      await this.d.deleteStore.requestEventVersionDeletion(ownerId, intentId, events[0]!);
      const [afterPlans, afterEvents] = await Promise.all([
        this.planInventory(ownerId), this.eventInventory(ownerId),
      ]);
      if (afterPlans.length || afterEvents.length) throw unavailable();
      return { state: 's3-cleared', overdue };
    } catch { throw unavailable(); }
  }
}
