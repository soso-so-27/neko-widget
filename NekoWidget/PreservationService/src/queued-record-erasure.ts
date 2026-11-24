import { ServiceError } from './contracts';
import type { RecordDeletionJob } from './record-physical-deletion';
import { matchesCommittedTombstone, type RecordRecoveryCopy } from './record-recovery-copy';
import { requestManifestPhotoDeletion } from './r2-photo-purge';
import type { RecoveryObject, S3RecoveryCopy } from './s3-recovery-copy';
import type { S3VersionPurge } from './s3-version-purge';

const unavailable = () => new ServiceError('RECORD_ERASURE_SCOPE_UNVERIFIED', 503);
const ownerIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const recordIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const recordBudgetMs = 20_000;
const photoBatch = 4;
const keyBatch = 4;

type Dependencies = {
  db: D1Database;
  bucket: R2Bucket;
  records: Pick<RecordRecoveryCopy, 'inspectManifest' | 'read'>;
  inventory: Pick<S3RecoveryCopy, 'listRecordKeyVersionsPage'>;
  eraser: Pick<S3VersionPurge, 'requestExactVersionDeletion'>;
  now: () => number;
};

type Authority = {
  generation: number;
  erased_through_key: string;
  marker_object_key: string; marker_version_id: string; marker_sha256: string; marker_bytes: number;
  intent_object_key: string; intent_version_id: string; intent_sha256: string; intent_bytes: number;
  record_object_key: string; record_version_id: string; record_sha256: string; record_bytes: number;
};

type HistoricalKey = {
  key: string; version_id: string; revision: number;
  marker_object_key: string; marker_version_id: string; marker_sha256: string; marker_bytes: number;
};

const identity = (job: RecordDeletionJob) => [job.owner_id, job.record_id, job.tombstone_revision, job.requested_at];
const marker = (row: Pick<Authority, 'marker_object_key' | 'marker_version_id' | 'marker_sha256' | 'marker_bytes'>): RecoveryObject => ({
  key: row.marker_object_key, versionId: row.marker_version_id, sha256: row.marker_sha256, bytes: row.marker_bytes,
});

function mediaKind(owner: string, key: string): 'record' | 'photo' {
  const parts = key.split('/');
  const kind = parts[3];
  if (parts.length !== 5 || parts[0] !== 'recovery' || parts[1] !== 'v1' || parts[2] !== owner
    || (kind !== 'record' && kind !== 'photo') || !ownerIdPattern.test(parts[4] ?? '')) throw unavailable();
  return kind;
}

export class QueuedRecordErasure {
  constructor(private readonly d: Dependencies) {}

  private async authority(job: RecordDeletionJob, prior?: Authority): Promise<Authority> {
    const active = await this.d.db.prepare(SQL_AUTHORITY).bind(...identity(job)).first<Authority>();
    if (!active || (prior && (active.generation !== prior.generation
      || active.erased_through_key !== prior.erased_through_key))) throw unavailable();
    return active;
  }

  private async confirmTombstone(job: RecordDeletionJob, row: Authority) {
    const [commit, intent] = await Promise.all([
      this.d.records.inspectManifest(job.owner_id, marker(row)),
      this.d.records.inspectManifest(job.owner_id, {
        key: row.intent_object_key, versionId: row.intent_version_id, sha256: row.intent_sha256, bytes: row.intent_bytes,
      }),
    ]);
    if (commit.kind !== 'commit' || commit.recordId !== job.record_id || commit.revision !== job.tombstone_revision
      || !matchesCommittedTombstone(commit, intent) || commit.record.key !== row.record_object_key
      || commit.record.versionId !== row.record_version_id || commit.record.sha256 !== row.record_sha256
      || commit.record.bytes !== row.record_bytes) throw unavailable();
    if (!(await this.d.records.read(job.owner_id, job.record_id, commit)).deleted) throw unavailable();
  }

  private async checkKeySharing(job: RecordDeletionJob, key: string) {
    const conflict = await this.d.db.prepare(SQL_KEY_CONFLICT)
      .bind(key, key, job.owner_id, job.record_id, job.tombstone_revision, key, key).first('conflict');
    if (conflict !== 0) throw unavailable();
  }

  private async confirmHistoricalKey(job: RecordDeletionJob, item: HistoricalKey) {
    const kind = mediaKind(job.owner_id, item.key);
    const commit = await this.d.records.inspectManifest(job.owner_id, marker(item));
    if (commit.kind !== 'commit' || commit.recordId !== job.record_id || commit.revision !== item.revision
      || commit.revision >= job.tombstone_revision) throw unavailable();
    const reference = commit[kind];
    if (!reference || reference.key !== item.key || reference.versionId !== item.version_id) throw unavailable();
  }

  async step(job: RecordDeletionJob): Promise<'processing' | 'complete'> {
    if (!ownerIdPattern.test(job.owner_id) || !recordIdPattern.test(job.record_id)) throw unavailable();
    const deadline = this.d.now() + recordBudgetMs;
    let current = await this.authority(job);
    if (current.erased_through_key) mediaKind(job.owner_id, current.erased_through_key);
    await this.confirmTombstone(job, current);
    if (this.d.now() >= deadline) return 'processing';

    const prefix = 'personal/' + job.owner_id + '/' + job.record_id + '/';
    const photos = await this.d.bucket.list({ prefix, limit: photoBatch });
    if (photos.truncated && !photos.objects.length) throw unavailable();
    if (photos.objects.length) {
      for (const item of photos.objects) {
        if (this.d.now() >= deadline) return 'processing';
        if (!item.key.startsWith(prefix)) throw unavailable();
        await this.authority(job, current);
        const used = await this.d.db.prepare('SELECT 1 FROM pa_records WHERE deleted=0 AND photo_key=?')
          .bind(item.key).first();
        if (used) throw unavailable();
        await requestManifestPhotoDeletion(this.d.bucket, job.owner_id, {
          key: item.key, version: item.version, bytes: item.size,
        });
      }
      // Re-list from the beginning next time. No R2 cursor is kept across deletes.
      return 'processing';
    }

    for (let keys = 0; keys < keyBatch && this.d.now() < deadline; keys++) {
      const historical = await this.d.db.prepare(SQL_NEXT_KEY)
        .bind(job.owner_id, job.record_id, job.tombstone_revision,
          current.erased_through_key, current.erased_through_key).first<HistoricalKey>();
      if (!historical) {
        await this.authority(job, current);
        const done = await this.d.db.prepare('DELETE FROM pa_record_physical_delete_queue ' + SQL_PROGRESS_GUARD)
          .bind(...identity(job), current.erased_through_key, job.owner_id, current.generation).run();
        if (done.meta.changes !== 1) throw unavailable();
        return 'complete';
      }

      await this.confirmHistoricalKey(job, historical);
      await this.checkKeySharing(job, historical.key);
      if (this.d.now() >= deadline) return 'processing';
      let page = await this.d.inventory.listRecordKeyVersionsPage(job.owner_id, historical.key);
      if (page.versions.some(item => item.key !== historical.key)) throw unavailable();
      if (page.versions.length) {
        for (const item of page.versions) {
          if (this.d.now() >= deadline) return 'processing';
          await this.authority(job, current);
          await this.checkKeySharing(job, historical.key);
          await this.d.eraser.requestExactVersionDeletion(job.owner_id, item);
        }
        if (this.d.now() >= deadline || page.nextCursor) return 'processing';
        page = await this.d.inventory.listRecordKeyVersionsPage(job.owner_id, historical.key);
      }
      // A delete response is not proof of absence. Advance only after a
      // fresh first page is empty, including delete markers.
      if (page.versions.length || page.nextCursor) return 'processing';
      await this.authority(job, current);
      const written = await this.d.db.prepare(
        'UPDATE pa_record_physical_delete_queue SET erased_through_key=? ' + SQL_PROGRESS_GUARD)
        .bind(historical.key, ...identity(job), current.erased_through_key, job.owner_id, current.generation).run();
      if (written.meta.changes !== 1) throw unavailable();
      current = { ...current, erased_through_key: historical.key };
    }
    return 'processing';
  }
}

const SQL_PROGRESS_GUARD = 'WHERE owner_id=? AND record_id=? AND tombstone_revision=? AND requested_at=?'
  + ' AND erased_through_key=? AND EXISTS(SELECT 1 FROM pa_owner_recovery_generations WHERE owner_id=? AND generation=?)';

const SQL_AUTHORITY = [
  'SELECT g.generation, q.erased_through_key, m.marker_object_key, m.marker_version_id, m.marker_sha256, m.marker_bytes,',
  ' d.intent_object_key,d.intent_version_id,d.intent_sha256,d.intent_bytes,',
  ' v.record_object_key,v.record_version_id,v.record_sha256,v.record_bytes',
  'FROM pa_record_physical_delete_queue q JOIN pa_record_physical_delete_candidates c',
  'USING(owner_id,record_id,tombstone_revision,requested_at)',
  'JOIN pa_owners o ON o.owner_id=q.owner_id',
  'JOIN pa_owner_recovery_generations g ON g.owner_id=q.owner_id',
  'JOIN pa_owner_recovery_versions s ON s.owner_id=g.owner_id AND s.generation=g.generation',
  'JOIN pa_record_commit_markers m ON m.owner_id=q.owner_id AND m.record_id=q.record_id AND m.revision=q.tombstone_revision',
  'JOIN pa_record_delete_intents d ON d.owner_id=q.owner_id AND d.record_id=q.record_id AND d.target_revision=q.tombstone_revision',
  'JOIN pa_record_recovery_versions v ON v.owner_id=q.owner_id AND v.record_id=q.record_id AND v.revision=q.tombstone_revision',
  'WHERE q.owner_id=? AND q.record_id=? AND q.tombstone_revision=? AND q.requested_at=?',
  'AND o.disabled=0 AND o.purge_fence_id IS NULL',
  'AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests p WHERE p.owner_id=q.owner_id)',
  'AND NOT EXISTS(SELECT 1 FROM pa_uploads p WHERE p.owner_id=q.owner_id AND p.record_id=q.record_id)',
  'AND NOT EXISTS(SELECT 1 FROM pa_recovery_write_leases p WHERE p.owner_id=q.owner_id)',
  'AND NOT EXISTS(SELECT 1 FROM pa_owner_delta_work p WHERE p.owner_id=q.owner_id)',
  'AND NOT EXISTS(SELECT 1 FROM pa_owner_delta_nodes p WHERE p.owner_id=q.owner_id)',
  'AND NOT EXISTS(SELECT 1 FROM pa_owner_recovery_builds p WHERE p.owner_id=q.owner_id)',
].join('\n');

const SQL_NEXT_KEY = [
  'WITH history AS (',
  ' SELECT * FROM pa_record_recovery_versions WHERE owner_id=? AND record_id=? AND revision<?',
  '), keys AS (',
  ' SELECT record_object_key AS key, record_version_id AS version_id, owner_id,record_id,revision',
  ' FROM history WHERE record_object_key>?',
  ' UNION ALL',
  ' SELECT photo_object_key AS key, photo_version_id AS version_id, owner_id,record_id,revision',
  ' FROM history WHERE photo_object_key>?',
  '), next AS (SELECT * FROM keys ORDER BY key,revision LIMIT 1)',
  'SELECT k.key,k.version_id,k.revision,m.marker_object_key,m.marker_version_id,m.marker_sha256,m.marker_bytes',
  'FROM next k LEFT JOIN pa_record_commit_markers m USING(owner_id,record_id,revision)',
].join('\n');

const SQL_KEY_CONFLICT = [
  'SELECT EXISTS(',
  ' SELECT 1 FROM pa_record_recovery_versions WHERE (record_object_key=? OR photo_object_key=?)',
  ' AND (owner_id<>? OR record_id<>? OR revision>=?)',
  ' UNION ALL SELECT 1 FROM pa_owner_recovery_versions WHERE object_key=?',
  ' UNION ALL SELECT 1 FROM pa_owner_delta_nodes WHERE object_key=?',
  ') AS conflict',
].join('\n');
