import { ServiceError } from './contracts';
import { inventoryOwnerCloudStorage } from './owner-cloud-inventory';
import type { OwnerArchiveRecovery } from './owner-archive-recovery';
import { matchesCommittedTombstone, type DiscoveredRecordManifest, type DiscoveredRecordCommit, type RecordRecoveryCopy } from './record-recovery-copy';
import { requestManifestPhotoDeletion } from './r2-photo-purge';
import type { RecoveryObject, RecoveryVersion, S3RecoveryCopy } from './s3-recovery-copy';
import type { S3VersionPurge } from './s3-version-purge';

export interface RecordDeletionJob {
  owner_id: string;
  record_id: string;
  tombstone_revision: number;
  requested_at: number;
}
type Dependencies = {
  db: D1Database;
  bucket: R2Bucket;
  archive: Pick<OwnerArchiveRecovery, 'assembleQuarantineCandidate'>;
  records: Pick<RecordRecoveryCopy, 'inspectManifest'>;
  inventory: Pick<S3RecoveryCopy, 'listOwnerVersionsPage'>;
  eraser: Pick<S3VersionPurge, 'requestExactVersionDeletion'>;
  now: () => number;
};
const unavailable = () => new ServiceError('RECORD_ERASURE_SCOPE_UNVERIFIED', 503);
const versionID = (ref: RecoveryObject | RecoveryVersion) => `${ref.key}\0${ref.versionId}`;
const attemptLimit = 16;

export class RecordPhysicalDeletion {
  constructor(private readonly d: Dependencies) {}

  private async requireCurrent(job: RecordDeletionJob): Promise<void> {
    const active = await this.d.db.prepare(`SELECT 1
      FROM pa_record_physical_delete_queue q JOIN pa_record_physical_delete_candidates c
      USING(owner_id,record_id,tombstone_revision,requested_at)
      JOIN pa_owners o ON o.owner_id=q.owner_id
      WHERE q.owner_id=? AND q.record_id=? AND q.tombstone_revision=? AND q.requested_at=?
      AND o.disabled=0 AND o.purge_fence_id IS NULL
      AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests d WHERE d.owner_id=q.owner_id)
      AND NOT EXISTS(SELECT 1 FROM pa_uploads u WHERE u.owner_id=q.owner_id AND u.record_id=q.record_id)
      AND NOT EXISTS(SELECT 1 FROM pa_recovery_write_leases w WHERE w.owner_id=q.owner_id)`)
      .bind(job.owner_id, job.record_id, job.tombstone_revision, job.requested_at).first();
    if (!active) throw unavailable();
  }

  private async scan(job: RecordDeletionJob) {
    await this.requireCurrent(job);
    const { owner_id: owner, record_id: record, tombstone_revision: revision } = job;
    // Independently verify the latest owner backup. A stale owner snapshot
    // or a corrupt/non-restorable unrelated record blocks physical erasure.
    const checkpoint = await this.d.archive.assembleQuarantineCandidate(owner, this.d.now());
    if (checkpoint.status !== 'ready-for-quarantine' || checkpoint.owner.ownerId !== owner
      || !checkpoint.owner.records.some(item => item.recordId === record && item.deleted && item.revision === revision)) {
      throw unavailable();
    }
    const owners = new Map<string, { record: string; bytes: number; shared: boolean; final: boolean }>();
    const intents: DiscoveredRecordManifest[] = [];
    let tombstone: DiscoveredRecordCommit | undefined;
    for (const group of checkpoint.recordMarkers) {
      for (const marker of group.markers) {
        const found = await this.d.records.inspectManifest(owner, marker);
        if (found.recordId !== group.recordId) throw unavailable();
        if (found.kind !== 'commit') {
          if (found.recordId === record) intents.push(found);
          continue;
        }
        if (found.recordId === record && found.revision === revision) tombstone = found;
        for (const ref of [found.record, ...(found.photo === null ? [] : [found.photo])]) {
          const id = versionID(ref);
          const prior = owners.get(id);
          if (prior && prior.bytes !== ref.bytes) throw unavailable();
          owners.set(id, { record: prior?.record ?? found.recordId, bytes: ref.bytes,
            shared: !!prior?.shared || (!!prior && prior.record !== found.recordId),
            final: !!prior?.final || found.recordId === record && found.revision === revision });
          if (found.recordId === record && prior && (prior.record !== record || prior.shared)) throw unavailable();
          if (prior?.record === record && found.recordId !== record) throw unavailable();
        }
      }
    }
    const terminalCommit = tombstone;
    if (!terminalCommit || !intents.length || !intents.every(intent => matchesCommittedTombstone(terminalCommit, intent))) {
      throw unavailable();
    }
    const physical = await inventoryOwnerCloudStorage(this.d.bucket, this.d.inventory, owner);
    const targets: RecoveryVersion[] = [];
    for (const item of physical.s3Versions) {
      const kind = item.key.split('/')[3];
      if (item.deleteMarker || !['photo','record','manifest','owner'].includes(kind ?? '')) throw unavailable();
      if (kind === 'manifest' || kind === 'owner') continue;
      const ref = owners.get(versionID(item));
      // An unclassified media version may be an interrupted write for this
      // record. Hold the whole job until independent attribution is possible.
      if (!ref || ref.bytes !== item.bytes) throw unavailable();
      if (ref.record === record && !ref.final) targets.push(item);
    }
    const prefix = `personal/${owner}/${record}/`;
    await this.requireCurrent(job);
    return { r2: physical.r2Objects.filter(item => item.key.startsWith(prefix)), s3: targets };
  }

  async step(job: RecordDeletionJob): Promise<'processing' | 'complete'> {
    const selected = await this.scan(job);
    const yieldAt = this.d.now() + 5000;
    for (const item of selected.r2.slice(0, attemptLimit)) {
      await this.requireCurrent(job);
      await requestManifestPhotoDeletion(this.d.bucket, job.owner_id, item);
      if (this.d.now() >= yieldAt) break;
    }
    if (selected.r2.length === 0) {
      for (const item of selected.s3.slice(0, attemptLimit)) {
        await this.requireCurrent(job);
        await this.d.eraser.requestExactVersionDeletion(job.owner_id, item);
        if (this.d.now() >= yieldAt) break;
      }
    }
    // A successful provider delete is a request, not proof of absence.
    const remaining = await this.scan(job);
    if (remaining.r2.length || remaining.s3.length) return 'processing';
    await this.d.db.prepare(`DELETE FROM pa_record_physical_delete_queue
      WHERE owner_id=? AND record_id=? AND tombstone_revision=? AND requested_at=?`)
      .bind(job.owner_id, job.record_id, job.tombstone_revision, job.requested_at).run();
    return 'complete';
  }
}
