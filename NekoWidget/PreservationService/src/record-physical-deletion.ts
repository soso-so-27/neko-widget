import { ServiceError, sha256 } from './contracts';
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
const reviewRecords = 13;
const reviewUnmatchedVersions = 755;

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

  private async reviewScope(expected: string) {
    // Use the existing deletion backlog. The read-only check must also work before
    // the physical queue migration is approved for the database being reviewed.
    const scope = await this.d.db.prepare(`SELECT r.owner_id,r.record_id,r.revision AS tombstone_revision,
      d.created_at AS requested_at,g.generation
      FROM pa_records r
      JOIN pa_record_commit_markers m USING(owner_id,record_id,revision)
      JOIN pa_record_delete_intents d ON d.owner_id=r.owner_id AND d.record_id=r.record_id AND d.target_revision=r.revision
      JOIN pa_record_recovery_versions v ON v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision
      JOIN pa_owners o ON o.owner_id=r.owner_id
      JOIN pa_owner_recovery_generations g ON g.owner_id=r.owner_id
      WHERE r.deleted=1 AND r.metadata IS NULL AND r.photo_key IS NULL
        AND v.record_object_key=d.record_object_key AND v.photo_object_key IS NULL
        AND o.disabled=0 AND o.purge_fence_id IS NULL
        AND (SELECT count(*) FROM pa_pending_deletes)=?
        AND EXISTS(SELECT 1 FROM pa_pending_deletes p
          WHERE p.object_key >= 'personal/'||r.owner_id||'/'||r.record_id||'/'
            AND p.object_key < 'personal/'||r.owner_id||'/'||r.record_id||'0')
        AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests p WHERE p.owner_id=r.owner_id)
        AND NOT EXISTS(SELECT 1 FROM pa_uploads p WHERE p.owner_id=r.owner_id)
        AND NOT EXISTS(SELECT 1 FROM pa_recovery_write_leases p WHERE p.owner_id=r.owner_id)
        AND NOT EXISTS(SELECT 1 FROM pa_owner_delta_work p WHERE p.owner_id=r.owner_id)
        AND NOT EXISTS(SELECT 1 FROM pa_owner_delta_nodes p WHERE p.owner_id=r.owner_id)
        AND NOT EXISTS(SELECT 1 FROM pa_owner_recovery_builds p WHERE p.owner_id=r.owner_id)
      ORDER BY d.created_at,r.owner_id,r.record_id LIMIT ?`)
      .bind(reviewRecords, reviewRecords + 1).all<RecordDeletionJob & { generation: number }>();
    const first = scope.results[0];
    if (!first || scope.results.length !== reviewRecords
      || scope.results.some(job => job.owner_id !== first.owner_id || job.generation !== first.generation)
      || await sha256(JSON.stringify(scope.results.map(job => [
        job.owner_id,job.record_id,job.tombstone_revision,job.requested_at,
      ]))) !== expected) throw unavailable();
    return { jobs: scope.results, owner: first.owner_id, generation: first.generation };
  }

  private async scan(jobs: readonly RecordDeletionJob[], generation: number, registered?: ReadonlySet<string>) {
    const owner = jobs[0]!.owner_id;
    const wanted = new Map(jobs.map(job => [job.record_id, job.tombstone_revision]));
    // Independently verify the latest owner backup. A stale owner snapshot
    // or a corrupt/non-restorable unrelated record blocks physical erasure.
    const physical = await inventoryOwnerCloudStorage(this.d.bucket, this.d.inventory, owner);
    const checkpoint = await this.d.archive.assembleQuarantineCandidate(owner, this.d.now(), physical.s3Versions);
    if (checkpoint.status !== 'ready-for-quarantine' || !checkpoint.erasureEvidence || checkpoint.owner.ownerId !== owner
      || checkpoint.owner.generation !== generation
      || checkpoint.owner.records.filter(item => item.deleted && wanted.get(item.recordId) === item.revision).length !== wanted.size) {
      throw unavailable();
    }
    const owners = new Map<string, { record: string; bytes: number; sha256: string; shared: boolean; final: boolean }>();
    const intents = new Map<string, DiscoveredRecordManifest[]>();
    const tombstones = new Map<string, DiscoveredRecordCommit>();
    for (const found of checkpoint.erasureEvidence.manifests) {
        const revision = wanted.get(found.recordId);
        if (found.kind !== 'commit') {
          if (revision !== undefined) {
            const existing = intents.get(found.recordId) ?? [];
            existing.push(found);
            intents.set(found.recordId, existing);
          }
          continue;
        }
        if (found.revision === revision) tombstones.set(found.recordId, found);
        for (const ref of [found.record, ...(found.photo === null ? [] : [found.photo])]) {
          const id = versionID(ref);
          const prior = owners.get(id);
          if (prior && (prior.bytes !== ref.bytes || prior.sha256 !== ref.sha256)) throw unavailable();
          owners.set(id, { record: prior?.record ?? found.recordId, bytes: ref.bytes, sha256: ref.sha256,
            shared: !!prior?.shared || (!!prior && prior.record !== found.recordId),
            final: !!prior?.final || found.revision === revision });
          if (prior && prior.record !== found.recordId && (revision !== undefined || wanted.has(prior.record))) throw unavailable();
          if (prior?.shared && revision !== undefined) throw unavailable();
        }
    }
    for (const record of wanted.keys()) {
      const tombstone = tombstones.get(record);
      const recordIntents = intents.get(record);
      if (!tombstone || !recordIntents?.length
        || !recordIntents.every(intent => matchesCommittedTombstone(tombstone, intent))) throw unavailable();
    }
    const pages = new Map(checkpoint.erasureEvidence.pages.map(ref => [versionID(ref), ref.bytes]));
    const list = new Map(physical.s3Versions.map(item => [versionID(item), item.bytes]));
    for (const [id, size] of pages) if (owners.has(id) || registered?.has(id) || list.get(id) !== size) throw unavailable();
    const targets: RecoveryVersion[] = [];
    const unlinked: RecoveryVersion[] = [];
    let unresolvedVersions = 0;
    let olderTargetBodies = 0;
    let orphanBodies = 0;
    for (const item of physical.s3Versions) {
      const kind = item.key.split('/')[3];
      if (item.deleteMarker || !['photo','record','manifest','owner'].includes(kind ?? '')) throw unavailable();
      if (kind === 'manifest' || kind === 'owner') continue;
      const id = versionID(item);
      if (pages.has(id)) continue;
      const ref = owners.get(id);
      if (registered && registered.has(id) !== !!ref) throw unavailable();
      if (!ref) {
        if (kind === 'record') unlinked.push(item);
        else unresolvedVersions++;
        continue;
      }
      if (ref.bytes !== item.bytes) throw unavailable();
      if (wanted.has(ref.record) && !ref.final) targets.push(item);
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
          const revision = wanted.get(entry.recordId);
          if (revision === undefined) return null;
          if (copy.deleted || copy.revision >= revision) throw unavailable();
          return item;
        }));
        for (const result of findings) {
          if (result.status === 'rejected') unresolvedVersions++;
          else if (result.value) {
            olderTargetBodies++;
            targets.push(result.value);
          } else orphanBodies++;
        }
      }
    }
    const r2 = physical.r2Objects.filter(item => wanted.has(item.key.split('/')[2] ?? ''));
    return { r2, s3: targets, physical, protectedPages: pages.size, olderTargetBodies, orphanBodies, unresolvedVersions };
  }

  async review(expected: string) {
    const started = this.d.now();
    const scope = await this.reviewScope(expected);
    const known = await this.d.db.prepare(`SELECT record_object_key AS key,record_version_id AS version
      FROM pa_record_recovery_versions WHERE owner_id=? UNION
      SELECT photo_object_key AS key,photo_version_id AS version FROM pa_record_recovery_versions
      WHERE owner_id=? AND photo_object_key IS NOT NULL`).bind(scope.owner,scope.owner).all<{key:string;version:string}>();
    const registered = new Set(known.results.map(item => `${item.key}\0${item.version}`));
    const proof = await this.scan(scope.jobs, scope.generation, registered);
    const { protectedPages, olderTargetBodies, orphanBodies, unresolvedVersions } = proof;
    if (protectedPages + olderTargetBodies + orphanBodies + unresolvedVersions !== reviewUnmatchedVersions) throw unavailable();
    const remaining = await inventoryOwnerCloudStorage(this.d.bucket, this.d.inventory, scope.owner);
    if ((await this.reviewScope(expected)).generation !== scope.generation) throw unavailable();
    this.stillPresent(proof.physical.r2Objects, [], remaining.r2Objects, r2Id);
    this.stillPresent(proof.physical.s3Versions, [], remaining.s3Versions, s3Id);
    return { protectedPages, olderTargetBodies, orphanBodies, unresolvedVersions, durationMs: this.d.now() - started };
  }

  async step(job: RecordDeletionJob): Promise<'processing' | 'complete'> {
    const eraser = this.d.eraser;
    if (!eraser) throw unavailable();
    const generation = await this.requireCurrent(job);
    const selected = await this.scan([job], generation);
    await this.requireCurrent(job, generation);
    if (selected.unresolvedVersions) throw unavailable();
    const yieldAt = this.d.now() + 5000;
    for (const item of selected.r2.slice(0, attemptLimit)) {
      await this.requireCurrent(job, generation);
      await requestManifestPhotoDeletion(this.d.bucket, job.owner_id, item);
      if (this.d.now() >= yieldAt) break;
    }
    if (selected.r2.length === 0) {
      for (const item of selected.s3.slice(0, attemptLimit)) {
        await this.requireCurrent(job, generation);
        await eraser.requestExactVersionDeletion(job.owner_id, item);
        if (this.d.now() >= yieldAt) break;
      }
    }
    // A successful provider delete is a request, not proof of absence.
    const remaining = await inventoryOwnerCloudStorage(this.d.bucket, this.d.inventory, job.owner_id);
    await this.requireCurrent(job, generation);
    const r2Pending = this.stillPresent(selected.physical.r2Objects, selected.r2, remaining.r2Objects, r2Id);
    const s3Pending = this.stillPresent(selected.physical.s3Versions, selected.s3, remaining.s3Versions, s3Id);
    if (r2Pending || s3Pending) return 'processing';
    const closed = await this.d.db.prepare(`DELETE FROM pa_record_physical_delete_queue
      WHERE owner_id=? AND record_id=? AND tombstone_revision=? AND requested_at=?
      AND EXISTS(SELECT 1 FROM pa_owner_recovery_generations g
        WHERE g.owner_id=pa_record_physical_delete_queue.owner_id AND g.generation=?)`)
      .bind(job.owner_id, job.record_id, job.tombstone_revision, job.requested_at, generation).run();
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

const r2Id = (item: { key: string; version: string; bytes: number }) => JSON.stringify([item.key, item.version, item.bytes]);
const s3Id = (item: RecoveryVersion) => JSON.stringify([item.key, item.versionId, item.bytes, item.deleteMarker]);
