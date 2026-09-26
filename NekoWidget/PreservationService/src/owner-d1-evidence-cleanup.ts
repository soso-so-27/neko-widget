import { ServiceError } from './contracts';
import { verifyOwnerCloudEmpty } from './owner-cloud-empty';
import { inspectOwnerD1Residue } from './owner-d1-residue';
import { loadOwnerPurgeTimeline } from './purge-intent-replay';
import type { PurgeIntentReference, S3PurgeIntentStore } from './s3-purge-intent';
import type { S3RecoveryCopy } from './s3-recovery-copy';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const hex = /^[0-9a-f]{64}$/u;
const day = 86_400_000;
const unavailable = () => new ServiceError('PURGE_EVIDENCE_CLEANUP_UNAVAILABLE', 503);
const batchSize = 128;
const tables = [
  'pa_purge_manifest_remote_refs', 'pa_purge_manifest_remote_seals',
  'pa_purge_manifest_chunks', 'pa_purge_manifests',
] as const;

type Completion = {
  state: string; manifest_sha256: string; finished_at: number | null;
  event_recorded_at: number; s3_object_key: string;
  s3_version_id: string; s3_sha256: string; s3_bytes: number;
};
type Dependencies = { db: D1Database; bucket: R2Bucket; recovery: S3RecoveryCopy;
  intentStore: Pick<S3PurgeIntentStore,
    'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>;
  now: () => number; enabled: string | undefined };
export type EvidenceCleanupStep = { state: 'progress'; table: string; removed: number;
  overdue: boolean } | { state: 'd1-cleared'; overdue: boolean };

/** Private, default-off first phase of evidence cleanup. The completed S3
 * chain is retained while D1 Time Travel could still contain pre-purge rows.
 * This class is deliberately not a public route or scheduled controller.
 * Each D1 batch inserts a short permit, deletes at most 128 owner rows and
 * consumes the permit atomically. No success depends on an empty DB alone.
 */
export class OwnerD1EvidenceCleanup {
  constructor(private readonly d: Dependencies) {}

  async step(ownerId: string, intentId: string,
    rootSha256: string, completedRef: PurgeIntentReference): Promise<EvidenceCleanupStep> {
    if (this.d.enabled !== 'YES' || !uuid.test(ownerId) || !uuid.test(intentId)
      || !hex.test(rootSha256)
      || completedRef?.key !== `purge/v1/${ownerId}/${intentId}/completed`)
      throw unavailable();
    try {
      const timeline = await loadOwnerPurgeTimeline(this.d.intentStore, ownerId);
      const target = timeline.intents.find(intent => intent.intentId === intentId);
      if (timeline.replay !== 'deleted' || target?.stage !== 'completed'
        || target.manifestSha256 !== rootSha256
        || timeline.intents.some(intent => intent.intentId !== intentId
          && intent.stage !== 'aborted')) throw unavailable();
      const completed = await this.d.intentStore.readExact(completedRef);
      if (completed.ownerId !== ownerId || completed.intentId !== intentId
        || completed.stage !== 'completed' || completed.manifestSha256 !== rootSha256
        || completed.recordedAt !== target.recordedAt) throw unavailable();
      const now = this.d.now();
      if (!Number.isSafeInteger(now) || now < completed.recordedAt) throw unavailable();
      await verifyOwnerCloudEmpty(this.d.bucket, this.d.recovery, ownerId);
      const residue = await inspectOwnerD1Residue(this.d.db, ownerId);
      if (residue.contentTotal || residue.pendingPhotoDeletes
        || Object.values(residue.ownerCursors).some(Boolean)
        || Object.values(residue.recoveryRepairCursors).some(Boolean)
        || residue.purgeWork.pa_purge_fences
        || residue.purgeWork.pa_purge_evidence_cleanup_permits) throw unavailable();
      const overdue = now > completed.recordedAt + 4 * day;
      const proof = await this.d.db.prepare(`SELECT c.state,c.manifest_sha256,c.finished_at,
        e.recorded_at AS event_recorded_at,e.s3_object_key,e.s3_version_id,
        e.s3_sha256,e.s3_bytes FROM pa_purge_execution_claims c
        JOIN pa_owner_purge_events e ON e.owner_id=c.owner_id
          AND e.intent_id=c.intent_id AND e.stage='completed'
        WHERE c.owner_id=? AND c.intent_id=?`).bind(ownerId, intentId).first<Completion>();
      // The final D1 batch may commit while its response is lost. Its absent
      // claim/event is success only when the independent completed S3 chain
      // remains exact and no owner-bearing D1 or cloud rows remain.
      if (!proof && residue.purgeWorkTotal === 0) return { state: 'd1-cleared', overdue };
      if (!proof || proof.state !== 'completed' || proof.manifest_sha256 !== rootSha256
        || proof.finished_at === null || proof.finished_at < completed.recordedAt
        || proof.event_recorded_at !== completed.recordedAt
        || proof.s3_object_key !== completedRef.key
        || proof.s3_version_id !== completedRef.versionId
        || proof.s3_sha256 !== completedRef.sha256
        || proof.s3_bytes !== completedRef.bytes) throw unavailable();
      const permit = this.d.db.prepare(`INSERT INTO pa_purge_evidence_cleanup_permits(
        owner_id,intent_id,manifest_sha256,completed_at,s3_object_key,
        s3_version_id,s3_sha256,s3_bytes,issued_at,expires_at)
        VALUES(?,?,?,?,?,?,?,?,?,?)`).bind(ownerId, intentId, rootSha256,
        proof.finished_at, completedRef.key, completedRef.versionId,
        completedRef.sha256, completedRef.bytes, now, now + 60_000);
      const consume = this.d.db.prepare(`DELETE FROM pa_purge_evidence_cleanup_permits
        WHERE owner_id=? AND intent_id=?`).bind(ownerId, intentId);
      const run = async (deletion: D1PreparedStatement, table: string) => {
        const results = await this.d.db.batch<{ rowid: number }>([permit, deletion, consume]);
        const removed = results[1]?.results.length ?? 0;
        if (results.length !== 3 || results[0]?.meta.changes !== 1
          || results[2]?.meta.changes !== 1 || removed < 1 || removed > batchSize)
          throw unavailable();
        return { state: 'progress' as const, table, removed, overdue };
      };
      for (const table of tables) {
        if (!residue.purgeWork[table]) continue;
        return await run(this.d.db.prepare(`DELETE FROM ${table} WHERE rowid IN
          (SELECT rowid FROM ${table} WHERE owner_id=? LIMIT ?)
          RETURNING rowid`).bind(ownerId, batchSize), table);
      }
      if ((residue.purgeWork.pa_owner_purge_events ?? 0) > 1) {
        return await run(this.d.db.prepare(`DELETE FROM pa_owner_purge_events
          WHERE rowid IN (SELECT rowid FROM pa_owner_purge_events
            WHERE owner_id=? AND NOT (intent_id=? AND stage='completed') LIMIT ?)
          RETURNING rowid`).bind(ownerId, intentId, batchSize), 'pa_owner_purge_events');
      }
      if ((residue.purgeWork.pa_purge_execution_claims ?? 0) > 1) {
        return await run(this.d.db.prepare(`DELETE FROM pa_purge_execution_claims
          WHERE rowid IN (SELECT rowid FROM pa_purge_execution_claims
            WHERE owner_id=? AND intent_id<>? LIMIT ?)
          RETURNING rowid`).bind(ownerId, intentId, batchSize), 'pa_purge_execution_claims');
      }
      if (residue.purgeWork.pa_owner_purge_events !== 1
        || residue.purgeWork.pa_purge_execution_claims !== 1
        || residue.purgeWorkTotal !== 2) throw unavailable();
      const final = await this.d.db.batch<{ rowid: number }>([
        permit,
        this.d.db.prepare(`DELETE FROM pa_purge_execution_claims
          WHERE owner_id=? AND intent_id=? AND state='completed' RETURNING rowid`)
          .bind(ownerId, intentId),
        this.d.db.prepare(`DELETE FROM pa_owner_purge_events
          WHERE owner_id=? AND intent_id=? AND stage='completed' RETURNING rowid`)
          .bind(ownerId, intentId),
        consume,
      ]);
      if (final.length !== 4 || final[0]?.meta.changes !== 1
        || final[1]?.results.length !== 1 || final[2]?.results.length !== 1
        || final[3]?.meta.changes !== 1) throw unavailable();
      const after = await inspectOwnerD1Residue(this.d.db, ownerId);
      if (after.contentTotal || after.purgeWorkTotal || after.pendingPhotoDeletes
        || Object.values(after.ownerCursors).some(Boolean)
        || Object.values(after.recoveryRepairCursors).some(Boolean)) throw unavailable();
      return { state: 'd1-cleared', overdue };
    } catch { throw unavailable(); }
  }
}
