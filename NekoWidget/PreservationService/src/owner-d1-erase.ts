import { ServiceError } from './contracts';
import { verifyOwnerCloudEmpty } from './owner-cloud-empty';
import { inspectOwnerD1Residue, ownerD1DeleteOrder } from './owner-d1-residue';
import { loadOwnerPurgeTimeline } from './purge-intent-replay';
import type { VerifiedMembershipStatus } from './retention-ledger';
import type { S3PurgeIntentStore } from './s3-purge-intent';
import type { S3PurgeManifestStore } from './s3-purge-manifest';
import type { S3RecoveryCopy } from './s3-recovery-copy';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const hex = /^[0-9a-f]{64}$/u;
const unavailable = () => new ServiceError('OWNER_D1_ERASE_UNAVAILABLE', 503);
const batchSize = 128;

type Dependencies = {
  db: D1Database;
  bucket: R2Bucket;
  recovery: S3RecoveryCopy;
  intentStore: Pick<S3PurgeIntentStore,
    'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>;
  planStore: Pick<S3PurgeManifestStore, 'loadPublished'>;
  statusForBillingAccount: (accountId: string) => Promise<VerifiedMembershipStatus>;
  enabled: string | undefined;
};
export type D1EraseStep = { state: 'progress'; table: string; removed: number }
  | { state: 'owner-erased' };

/** Private offline executor only; no HTTP or cron route calls it. Each step
 * replays the external erasing record and complete plan, checks the DB-local
 * claim, and inventories both storage prefixes twice before one bounded D1
 * batch. A renewed or unknown membership stops subsequent steps while the
 * owner remains fenced; it does not restore content already erased. The
 * external audit is NOT bounded to a Worker request for a large owner. A
 * failed check never becomes permission to delete.
 */
export class OwnerD1Eraser {
  constructor(private readonly d: Dependencies) {}

  async step(ownerId: string, intentId: string, rootSha256: string): Promise<D1EraseStep> {
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
      if (plan.ownerId !== ownerId || plan.intentId !== intentId
        || plan.sha256 !== rootSha256 || plan.ownerEpoch !== own.ownerEpoch
        || plan.inventoryGeneration !== own.inventoryGeneration) throw unavailable();
      const authority = await this.d.db.prepare(`SELECT l.billing_account_id,c.manifest_sha256,
        c.owner_epoch,c.inventory_generation,c.retention_episode,
        c.retention_revision,c.due_at
        FROM pa_purge_d1_erasing_authority a
        JOIN pa_purge_execution_claims c ON c.owner_id=a.owner_id
          AND c.intent_id=a.intent_id
        JOIN pa_membership_links l ON l.owner_id=a.owner_id
        WHERE a.owner_id=? AND a.intent_id=?`)
        .bind(ownerId, intentId).first<{ billing_account_id: string; manifest_sha256: string;
          owner_epoch: number; inventory_generation: number;
          retention_episode: number; retention_revision: number; due_at: number }>();
      if (!authority || authority.manifest_sha256 !== rootSha256
        || authority.owner_epoch !== own.ownerEpoch
        || authority.inventory_generation !== own.inventoryGeneration
        || authority.retention_episode !== own.retentionEpisode
        || authority.retention_revision !== own.retentionRevision
        || authority.due_at !== own.dueAt) throw unavailable();
      await verifyOwnerCloudEmpty(this.d.bucket, this.d.recovery, ownerId);
      const residue = await inspectOwnerD1Residue(this.d.db, ownerId);
      const requireExpired = async () => {
        // A fresh result is required immediately before each actual D1
        // mutation, not only before the earlier cloud inventory.
        if (await this.d.statusForBillingAccount(authority.billing_account_id)
          !== 'expired') throw unavailable();
      };

      // Advisory cursors and pending-deletion keys can still identify the
      // owner after content removal. They carry no erasure authority.
      for (const table of ['pa_expiry_review_cursor', 'pa_notice_scan_cursor',
        'pa_recovery_repair_cursor', 'pa_owner_recovery_repair_cursor'] as const) {
        const cursorRows = table === 'pa_expiry_review_cursor' || table === 'pa_notice_scan_cursor'
          ? residue.ownerCursors[table] : residue.recoveryRepairCursors[table];
        if (!cursorRows) continue;
        await requireExpired();
        const result = await this.d.db.prepare(`UPDATE ${table} SET
          ${table === 'pa_expiry_review_cursor' || table === 'pa_notice_scan_cursor'
            ? 'owner_id' : 'last_owner_id'}=''
          WHERE ${table === 'pa_expiry_review_cursor' || table === 'pa_notice_scan_cursor'
            ? 'owner_id' : 'last_owner_id'}=?
          AND EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority
            WHERE owner_id=? AND intent_id=?)`).bind(ownerId, ownerId, intentId).run();
        if (result.meta.changes) return { state: 'progress', table,
          removed: result.meta.changes };
        throw unavailable();
      }
      const prefix = `personal/${ownerId}/`;
      const upper = `personal/${ownerId}0`;
      if (residue.pendingPhotoDeletes) {
        await requireExpired();
        const queue = await this.d.db.prepare(`DELETE FROM pa_pending_deletes
          WHERE object_key IN (SELECT object_key FROM pa_pending_deletes
            WHERE object_key>=? AND object_key<? LIMIT ?)
          AND EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority
            WHERE owner_id=? AND intent_id=?)`)
          .bind(prefix, upper, batchSize, ownerId, intentId).run();
        if (queue.meta.changes) return { state: 'progress', table: 'pa_pending_deletes',
          removed: queue.meta.changes };
        throw unavailable();
      }

      for (const table of ownerD1DeleteOrder) {
        // The billing link must remain readable for a fresh membership check
        // on every invocation. Keep the fence (and disabled owner) until the
        // same final atomic batch removes all three together.
        if (table === 'pa_membership_links' || table === 'pa_purge_fences') continue;
        if (table === 'pa_owners') {
          if (residue.contentTotal !== 2 || residue.content.pa_owners !== 1
            || residue.content.pa_membership_links !== 1
            || residue.purgeWork.pa_purge_fences !== 1
            || residue.pendingPhotoDeletes !== 0
            || Object.values(residue.ownerCursors).some(Boolean)
            || Object.values(residue.recoveryRepairCursors).some(Boolean)) throw unavailable();
          await requireExpired();
          const final = await this.d.db.batch([
            this.d.db.prepare(`DELETE FROM pa_membership_links WHERE owner_id=?
              AND EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority
                WHERE owner_id=? AND intent_id=?)`).bind(ownerId, ownerId, intentId),
            this.d.db.prepare(`DELETE FROM pa_purge_fences WHERE owner_id=? AND fence_id=?
              AND EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority
                WHERE owner_id=? AND intent_id=?)`).bind(ownerId, intentId, ownerId, intentId),
            this.d.db.prepare(`DELETE FROM pa_owners WHERE owner_id=? AND disabled=1
              AND purge_fence_id=? AND EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority
                WHERE owner_id=? AND intent_id=?)`).bind(ownerId, intentId, ownerId, intentId),
          ]);
          if (final.length !== 3 || final.some(result => result.meta.changes !== 1))
            throw unavailable();
          return { state: 'owner-erased' };
        }
        if (!residue.content[table] && !residue.purgeWork[table]) continue;
        await requireExpired();
        const result = await this.d.db.prepare(`DELETE FROM ${table}
          WHERE rowid IN (SELECT rowid FROM ${table} WHERE owner_id=? LIMIT ?)
          AND EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority
            WHERE owner_id=? AND intent_id=?)`)
          .bind(ownerId, batchSize, ownerId, intentId).run();
        if (result.meta.changes) {
          return { state: 'progress', table, removed: result.meta.changes };
        }
        throw unavailable();
      }
      throw unavailable();
    } catch { throw unavailable(); }
  }
}
