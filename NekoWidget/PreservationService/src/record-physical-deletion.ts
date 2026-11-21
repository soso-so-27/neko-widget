import { ServiceError } from './contracts';
import { inventoryOwnerCloudStorage } from './owner-cloud-inventory';
import type { OwnerArchiveRecovery } from './owner-archive-recovery';
import { keyContextHash, unverifiedEnvelopeContext } from './key-custody';
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
  records: Pick<RecordRecoveryCopy, 'inspectUncommittedCopy'>;
  inventory: Pick<S3RecoveryCopy, 'listOwnerVersionsPage' | 'referenceForListedVersion' | 'getVerified'>;
  eraser?: Pick<S3VersionPurge, 'requestExactVersionDeletion'>;
  now: () => number;
};
const unavailable = () => new ServiceError('RECORD_ERASURE_SCOPE_UNVERIFIED', 503);
const versionID = (ref: RecoveryObject | RecoveryVersion) => `${ref.key}\0${ref.versionId}`;
const attemptLimit = 16;

export class RecordPhysicalDeletion {
  constructor(private readonly d: Dependencies) {}

  private async requireCurrent(job: RecordDeletionJob, generation?: number): Promise<number> {
    const active = await this.d.db.prepare(`SELECT g.generation
      FROM pa_record_physical_delete_queue q JOIN pa_record_physical_delete_candidates c
      USING(owner_id,record_id,tombstone_revision,requested_at)
      JOIN pa_owners o ON o.owner_id=q.owner_id
      JOIN pa_owner_recovery_generations g ON g.owner_id=q.owner_id
      WHERE q.owner_id=? AND q.record_id=? AND q.tombstone_revision=? AND q.requested_at=?
      AND o.disabled=0 AND o.purge_fence_id IS NULL
      AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests d WHERE d.owner_id=q.owner_id)
      AND NOT EXISTS(SELECT 1 FROM pa_uploads u WHERE u.owner_id=q.owner_id AND u.record_id=q.record_id)
      AND NOT EXISTS(SELECT 1 FROM pa_recovery_write_leases w WHERE w.owner_id=q.owner_id)
      AND NOT EXISTS(SELECT 1 FROM pa_owner_delta_work w WHERE w.owner_id=q.owner_id)
      AND NOT EXISTS(SELECT 1 FROM pa_owner_delta_nodes n WHERE n.owner_id=q.owner_id)
      AND NOT EXISTS(SELECT 1 FROM pa_owner_recovery_builds b WHERE b.owner_id=q.owner_id)`)
      .bind(job.owner_id, job.record_id, job.tombstone_revision, job.requested_at).first<{ generation: number }>();
    if (!active || (generation !== undefined && active.generation !== generation)) throw unavailable();
    return active.generation;
  }

  private async scan(job: RecordDeletionJob) {
    const generation = await this.requireCurrent(job);
    const { owner_id: owner, record_id: record, tombstone_revision: revision } = job;
    // Independently verify the latest owner backup. A stale owner snapshot
    // or a corrupt/non-restorable unrelated record blocks physical erasure.
    const physical = await inventoryOwnerCloudStorage(this.d.bucket, this.d.inventory, owner);
    const checkpoint = await this.d.archive.assembleQuarantineCandidate(owner, this.d.now(), physical.s3Versions);
    if (checkpoint.status !== 'ready-for-quarantine' || !checkpoint.erasureEvidence || checkpoint.owner.ownerId !== owner
      || checkpoint.owner.generation !== generation
      || !checkpoint.owner.records.some(item => item.recordId === record && item.deleted && item.revision === revision)) {
      throw unavailable();
    }
    const owners = new Map<string, { record: string; bytes: number; sha256: string; shared: boolean; final: boolean }>();
    const intents: DiscoveredRecordManifest[] = [];
    let tombstone: DiscoveredRecordCommit | undefined;
    for (const found of checkpoint.erasureEvidence.manifests) {
        if (found.kind !== 'commit') {
          if (found.recordId === record) intents.push(found);
          continue;
        }
        if (found.recordId === record && found.revision === revision) tombstone = found;
        for (const ref of [found.record, ...(found.photo === null ? [] : [found.photo])]) {
          const id = versionID(ref);
          const prior = owners.get(id);
          if (prior && (prior.bytes !== ref.bytes || prior.sha256 !== ref.sha256)) throw unavailable();
          owners.set(id, { record: prior?.record ?? found.recordId, bytes: ref.bytes, sha256: ref.sha256,
            shared: !!prior?.shared || (!!prior && prior.record !== found.recordId),
            final: !!prior?.final || found.recordId === record && found.revision === revision });
          if (found.recordId === record && prior && (prior.record !== record || prior.shared)) throw unavailable();
          if (prior?.record === record && found.recordId !== record) throw unavailable();
        }
    }
    const terminalCommit = tombstone;
    if (!terminalCommit || !intents.length || !intents.every(intent => matchesCommittedTombstone(terminalCommit, intent))) {
      throw unavailable();
    }
    const pages = new Map(checkpoint.erasureEvidence.pages.map(ref => [versionID(ref), ref.bytes]));
    const list = new Map(physical.s3Versions.map(item => [versionID(item), item.bytes]));
    for (const [id, size] of pages) if (owners.has(id) || list.get(id) !== size) throw unavailable();
    const targets: RecoveryVersion[] = [];
    const unlinked: RecoveryVersion[] = [];
    let unresolvedVersions = 0;
    let authenticatedUncommittedCopies = 0;
    for (const item of physical.s3Versions) {
      const kind = item.key.split('/')[3];
      if (item.deleteMarker || !['photo','record','manifest','owner'].includes(kind ?? '')) throw unavailable();
      if (kind === 'manifest' || kind === 'owner') continue;
      const id = versionID(item);
      if (pages.has(id)) continue;
      const ref = owners.get(id);
      if (!ref) {
        if (kind === 'record') unlinked.push(item);
        else unresolvedVersions++;
        continue;
      }
      if (ref.bytes !== item.bytes) throw unavailable();
      if (ref.record === record && !ref.final) targets.push(item);
    }
    if (unlinked.length) {
      const byContext = new Map<string, { recordId: string; revision: number }>();
      for (const item of checkpoint.owner.records) {
        const hash = await keyContextHash({ ownerId: owner, purpose: 'record', recordId: `${item.recordId}/document` });
        byContext.set(hash, item);
      }
      // Only a verified envelope can attribute an uncommitted record copy.
      // A page without an authenticated parent and an unmatched photo remain blocked.
      for (let offset = 0; offset < unlinked.length; offset += 6) {
        const findings = await Promise.allSettled(unlinked.slice(offset, offset + 6).map(async item => {
          const exact = await this.d.inventory.referenceForListedVersion(item);
          const sealed = await this.d.inventory.getVerified(exact);
          const entry = byContext.get(unverifiedEnvelopeContext(sealed));
          if (!entry) throw unavailable();
          const copy = await this.d.records.inspectUncommittedCopy(owner, entry.recordId, sealed);
          if (copy.revision > entry.revision) throw unavailable();
          if (copy.photo) {
            const known = owners.get(versionID(copy.photo));
            if (!known || known.shared || known.record !== entry.recordId
              || known.sha256 !== copy.photo.sha256 || known.bytes !== copy.photo.bytes) throw unavailable();
          }
          if (entry.recordId !== record) return null;
          if (copy.deleted || copy.revision >= revision) throw unavailable();
          return item;
        }));
        for (const result of findings) {
          if (result.status === 'rejected') unresolvedVersions++;
          else {
            authenticatedUncommittedCopies++;
            if (result.value) targets.push(result.value);
          }
        }
      }
    }
    const prefix = `personal/${owner}/${record}/`;
    await this.requireCurrent(job, generation);
    return { r2: physical.r2Objects.filter(item => item.key.startsWith(prefix)), s3: targets, physical, generation,
      protectedPages: pages.size, authenticatedUncommittedCopies, unresolvedVersions };
  }

  async review(job: RecordDeletionJob) {
    const proof = await this.scan(job);
    return { r2Targets: proof.r2.length, s3Targets: proof.s3.length,
      protectedPages: proof.protectedPages, authenticatedUncommittedCopies: proof.authenticatedUncommittedCopies,
      unresolvedVersions: proof.unresolvedVersions };
  }

  async step(job: RecordDeletionJob): Promise<'processing' | 'complete'> {
    const eraser = this.d.eraser;
    if (!eraser) throw unavailable();
    const selected = await this.scan(job);
    if (selected.unresolvedVersions) throw unavailable();
    const yieldAt = this.d.now() + 5000;
    for (const item of selected.r2.slice(0, attemptLimit)) {
      await this.requireCurrent(job, selected.generation);
      await requestManifestPhotoDeletion(this.d.bucket, job.owner_id, item);
      if (this.d.now() >= yieldAt) break;
    }
    if (selected.r2.length === 0) {
      for (const item of selected.s3.slice(0, attemptLimit)) {
        await this.requireCurrent(job, selected.generation);
        await eraser.requestExactVersionDeletion(job.owner_id, item);
        if (this.d.now() >= yieldAt) break;
      }
    }
    // A successful provider delete is a request, not proof of absence.
    const remaining = await inventoryOwnerCloudStorage(this.d.bucket, this.d.inventory, job.owner_id);
    await this.requireCurrent(job, selected.generation);
    const r2Id = (item: { key: string; version: string; bytes: number }) => JSON.stringify([item.key, item.version, item.bytes]);
    const s3Id = (item: RecoveryVersion) => JSON.stringify([item.key, item.versionId, item.bytes, item.deleteMarker]);
    const r2Pending = this.stillPresent(selected.physical.r2Objects, selected.r2, remaining.r2Objects, r2Id);
    const s3Pending = this.stillPresent(selected.physical.s3Versions, selected.s3, remaining.s3Versions, s3Id);
    if (r2Pending || s3Pending) return 'processing';
    const closed = await this.d.db.prepare(`DELETE FROM pa_record_physical_delete_queue
      WHERE owner_id=? AND record_id=? AND tombstone_revision=? AND requested_at=?
      AND EXISTS(SELECT 1 FROM pa_owner_recovery_generations g
        WHERE g.owner_id=pa_record_physical_delete_queue.owner_id AND g.generation=?)`)
      .bind(job.owner_id, job.record_id, job.tombstone_revision, job.requested_at, selected.generation).run();
    if (closed.meta.changes !== 1) throw unavailable();
    return 'complete';
  }

  private stillPresent<T>(prior: T[], targets: T[], after: T[], identity: (item: T) => string): boolean {
    const reviewed = new Set(prior.map(identity));
    const selected = new Set(targets.map(identity));
    const current = new Set(after.map(identity));
    for (const id of current) if (!reviewed.has(id)) throw unavailable();
    for (const id of reviewed) if (!current.has(id) && !selected.has(id)) throw unavailable();
    return [...selected].some(id => current.has(id));
  }
}
