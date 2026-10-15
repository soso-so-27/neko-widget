import { ServiceError, sha256, type ToolBackupPart } from './contracts';
import { parseToolIndex } from './documents';
import { OwnerArchiveRecovery } from './owner-archive-recovery';
import { loadOwnerPurgeReplay } from './purge-intent-replay';
import { RecordRecoveryCopy, type DiscoveredDeleteIntent,
  type DiscoveredRecordCommit } from './record-recovery-copy';
import type { S3PurgeIntentStore } from './s3-purge-intent';

const unavailable = () => new ServiceError('OWNER_QUARANTINE_RESTORE_UNAVAILABLE', 503);
type RestoredToolPart = Omit<ToolBackupPart, 'payload'> & { bytes: number };

/** Writes only to a migrated, empty and offline D1/R2 target. The owner is
 * inserted disabled, without sessions or notice contact. Even a fully staged
 * owner cannot be activated until the independent deletion ledger is replayed,
 * identity/billing are verified, and a separately reviewed release path exists.
 * A partial failed attempt must be discarded as an isolated environment; this
 * method never deletes potentially user-owned data to make a retry succeed.
 */
export class OwnerQuarantineRestore {
  constructor(private readonly archive: OwnerArchiveRecovery,
    private readonly records: RecordRecoveryCopy,
    private readonly db: D1Database,
    private readonly bucket: R2Bucket,
    private readonly purgeIntents: Pick<S3PurgeIntentStore,
      'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>,
    private readonly ownerDeletion?: { assertNotRequested(ownerId: string): Promise<void> }) {}

  private async requireNoPurgeIntent(ownerId: string): Promise<void> {
    if (!this.ownerDeletion) throw unavailable();
    await this.ownerDeletion.assertNotRequested(ownerId);
    if (await loadOwnerPurgeReplay(this.purgeIntents, ownerId) !== 'clear') throw unavailable();
  }

  private async requireEmptyTarget(ownerId: string): Promise<void> {
    const row = await this.db.prepare(`SELECT
      (SELECT count(*) FROM pa_owners) AS owners,
      (SELECT count(*) FROM pa_records) AS records,
      (SELECT count(*) FROM pa_purge_fences) AS fences,
      (SELECT count(*) FROM pa_owner_recovery_versions) AS owner_copies,
      (SELECT count(*) FROM pa_record_recovery_versions) AS record_copies,
      (SELECT count(*) FROM pa_tool_snapshot_references) AS tool_references,
      (SELECT count(*) FROM pa_tool_part_delete_claims) AS tool_delete_claims,
      (SELECT count(*) FROM pa_tool_owner_trials) AS trial_grants,
      (SELECT count(*) FROM pa_tool_trial_records) AS trial_slots,
      (SELECT count(*) FROM pa_tool_trial_resume_repairs) AS trial_repairs,
      (SELECT delete_intent_required FROM pa_recovery_write_policy WHERE singleton=1)
        AS record_policy,
      (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)
        AS owner_policy`).first<{ owners: number; records: number; fences: number;
        owner_copies: number; record_copies: number; tool_references: number;
        tool_delete_claims: number; trial_grants: number; trial_slots: number;
        trial_repairs: number; record_policy: number; owner_policy: number }>();
    if (!row || row.owners !== 0 || row.records !== 0 || row.fences !== 0
      || row.owner_copies !== 0 || row.record_copies !== 0
      || row.tool_references !== 0 || row.tool_delete_claims !== 0
      || row.trial_grants !== 0 || row.trial_slots !== 0 || row.trial_repairs !== 0
      || row.record_policy !== 0 || row.owner_policy !== 0) throw unavailable();
    const listed = await this.bucket.list({ prefix: `personal/${ownerId}/`, limit: 1 });
    if (listed.objects.length !== 0 || listed.truncated) throw unavailable();
  }

  private async restoredMetadata(ownerId: string, recordId: string) {
    const row = await this.db.prepare(`SELECT revision,metadata,photo_key,photo_bytes,deleted
      FROM pa_records WHERE owner_id=? AND record_id=?`).bind(ownerId, recordId)
      .first<{ revision: number; metadata: unknown; photo_key: string | null;
        photo_bytes: number; deleted: number }>();
    if (!row || row.deleted !== 0 || row.revision !== 1) throw unavailable();
    const raw = row.metadata;
    const metadata = raw instanceof Uint8Array ? raw : raw instanceof ArrayBuffer
      ? new Uint8Array(raw) : Array.isArray(raw) ? new Uint8Array(raw) : null;
    if (metadata === null) throw unavailable();
    const result = await this.records.readMetadata({ ownerId, recordId, revision: row.revision,
      metadata, photoKey: row.photo_key, photoBytes: row.photo_bytes, deleted: false });
    if (!result) throw unavailable();
    return result;
  }

  /** The edge table is derived data. Rebuild it only from authenticated current
   * metadata in this empty, offline target. V1 dependencies remain bound to the
   * original index; v2 edges must be complete before any staged success. */
  private async rebuildToolReferences(ownerId: string, parts: Map<string, RestoredToolPart>): Promise<void> {
    let expectedReferences = 0;
    for (const [snapshotId, descriptor] of parts) {
      if (descriptor.kind !== 'index') continue;
      const metadata = await this.restoredMetadata(ownerId, snapshotId);
      const tag = metadata.document.toolBackup;
      if (!tag || tag.kind !== 'index' || tag.snapshotId !== snapshotId) throw unavailable();
      const index = parseToolIndex(tag);
      const edges: D1PreparedStatement[] = [];
      for (const file of index.files) {
        const photo = file.path.endsWith('.jpg');
        const source = (file.sourceSnapshotID ?? index.snapshotID).toLowerCase();
        let bytes = 0;
        // At most one bounded JSON file is assembled; never retain all restored
        // plaintext indices or photos while walking an owner's snapshot graph.
        const chunks: Uint8Array[] = [];
        for (let offset = 0; offset < file.records.length; offset++) {
          const id = file.records[offset]!.toLowerCase();
          const part = parts.get(id);
          if (!part || part.kind !== (photo ? 'photo' : 'json') || part.snapshotId !== source
            || part.path !== file.path || part.part !== offset || part.count !== file.records.length) {
            throw unavailable();
          }
          bytes += part.bytes;
          if (!Number.isSafeInteger(bytes) || bytes > file.bytes) throw unavailable();
          if (photo) {
            if (part.sha256 !== file.sha256) throw unavailable();
          } else {
            const document = (await this.restoredMetadata(ownerId, id)).document;
            const chunk = document.toolBackup;
            if (!chunk || chunk.kind !== 'json' || chunk.snapshotId !== source || chunk.path !== file.path
              || chunk.part !== offset || chunk.count !== file.records.length || chunk.sha256 !== part.sha256) {
              throw unavailable();
            }
            chunks.push(Uint8Array.from(atob(chunk.payload), c => c.charCodeAt(0)));
          }
          if (index.version === 2) {
            edges.push(this.db.prepare(`INSERT INTO pa_tool_snapshot_references(owner_id,snapshot_id,part_id)
              VALUES(?,?,?)`).bind(ownerId, snapshotId, id));
            expectedReferences++;
            if (!Number.isSafeInteger(expectedReferences)) throw unavailable();
          }
        }
        if (bytes !== file.bytes) throw unavailable();
        if (!photo) {
          const fileBytes = new Uint8Array(bytes);
          let at = 0;
          for (const chunk of chunks) { fileBytes.set(chunk, at); at += chunk.length; chunk.fill(0); }
          try { if (await sha256(fileBytes) !== file.sha256) throw unavailable(); }
          finally { fileBytes.fill(0); }
        }
      }
      for (let offset = 0; offset < edges.length; offset += 50) {
        await this.db.batch(edges.slice(offset, offset + 50));
      }
    }
    const closure = await this.db.prepare(`SELECT
      (SELECT count(*) FROM pa_tool_snapshot_references WHERE owner_id=?) AS refs,
      (SELECT count(*) FROM pa_tool_part_delete_claims WHERE owner_id=?) AS claims`)
      .bind(ownerId, ownerId).first<{ refs: number; claims: number }>();
    if (!closure || closure.refs !== expectedReferences || closure.claims !== 0) throw unavailable();
  }

  private async restorePhoto(key: string, ciphertext: Uint8Array): Promise<void> {
    const stored = await this.bucket.put(key, ciphertext.slice().buffer,
      { onlyIf: new Headers({ 'If-None-Match': '*' }),
        httpMetadata: { contentType: 'application/octet-stream' } });
    if (!stored) throw unavailable();
    const readBack = await this.bucket.get(key);
    if (!readBack || readBack.size !== ciphertext.length) throw unavailable();
    const actual = new Uint8Array(await readBack.arrayBuffer());
    if (actual.length !== ciphertext.length) throw unavailable();
    const [actualHash, expectedHash] = await Promise.all([
      crypto.subtle.digest('SHA-256', actual as BufferSource),
      crypto.subtle.digest('SHA-256', ciphertext as BufferSource),
    ]);
    const expectedDigest = new Uint8Array(expectedHash);
    if (new Uint8Array(actualHash).some((byte, index) => byte !== expectedDigest[index])) {
      throw unavailable();
    }
  }

  async restore(ownerId: string, now: number): Promise<
    { status: 'missing' | 'disabled' | 'quarantined' } |
    { status: 'staged-disabled'; ownerId: string; records: number; photos: number }> {
    // A D1 bookmark can predate a physical deletion. Consult the independent
    // full-version ledger before reading a recovery image or staging any bytes.
    await this.requireNoPurgeIntent(ownerId);
    const candidate = await this.archive.assembleQuarantineCandidate(ownerId, now);
    if (candidate.status !== 'ready-for-quarantine') return candidate;
    const owner = candidate.owner;
    if (!owner.disabled || owner.contact !== null || owner.purgeFenceId !== null
      || owner.retention?.status === 'expired'
      || (owner.retention?.finalNoticeReceipt ?? null) !== null
      || candidate.verifiedRecords !== owner.records.length
      || candidate.recordMarkers.length !== owner.records.length) throw unavailable();
    await this.requireEmptyTarget(ownerId);
    await this.requireNoPurgeIntent(ownerId);
    const initial = [
      this.db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,created_at,
        purge_fence_id) VALUES(?,?,?,1,?,NULL)`)
        .bind(ownerId, owner.identityKey, owner.epoch, owner.createdAt),
      this.db.prepare(`INSERT INTO pa_identity_credentials(owner_id,owner_epoch,
        sealed_credentials,updated_at) VALUES(?,?,?,?)`)
        .bind(ownerId, owner.credential.ownerEpoch,
          owner.credential.sealedCredentials.slice().buffer, owner.credential.updatedAt),
      this.db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(ownerId),
      ...(owner.billing ? [this.db.prepare(`INSERT INTO pa_membership_links(owner_id,
        billing_account_id,created_at) VALUES(?,?,?)`)
        .bind(ownerId, owner.billing.accountId, owner.billing.createdAt)] : []),
      ...(owner.retention ? [this.db.prepare(`INSERT INTO pa_retention(owner_id,revision,
        episode,verified_status,checked_at,expired_at,due_at,paused_at,
        notice_not_before_at,final_notice_delivered_at,final_notice_receipt)
        VALUES(?,?,?,?,?,?,?,?,?,NULL,NULL)`)
        .bind(ownerId, owner.retention.revision, owner.retention.episode,
          owner.retention.status, owner.retention.checkedAt, owner.retention.expiredAt,
          owner.retention.dueAt, owner.retention.pausedAt,
          owner.retention.noticeNotBeforeAt)] : []),
    ];
    await this.db.batch(initial);
    const markerGroups = new Map(candidate.recordMarkers.map(item => [item.recordId,
      item.markers]));
    let photos = 0;
    let historyRows = 0;
    let expectedUsedBytes = 0;
    const toolParts = new Map<string, RestoredToolPart>();
    for (const expected of owner.records) {
      const group = markerGroups.get(expected.recordId);
      if (!group) throw unavailable();
      const selected = await this.records.selectRecoveredRecord(ownerId, expected.recordId,
        group);
      if (selected.status !== 'ready' || selected.image.revision !== expected.revision
        || selected.image.deleted !== expected.deleted) throw unavailable();
      const commits = new Map<number, DiscoveredRecordCommit>();
      const intents = new Map<number, DiscoveredDeleteIntent>();
      for (const marker of group) {
        const manifest = await this.records.inspectManifest(ownerId, marker);
        if (manifest.recordId !== expected.recordId) throw unavailable();
        if (manifest.kind === 'commit') {
          const current = commits.get(manifest.revision);
          if (!current || manifest.marker.key === expected.marker.key
            || manifest.marker.key < current.marker.key) commits.set(manifest.revision, manifest);
        } else {
          const current = intents.get(manifest.revision);
          if (!current || manifest.marker.key < current.marker.key) {
            intents.set(manifest.revision, manifest);
          }
        }
      }
      const latest = commits.get(expected.revision);
      if (!latest || latest.marker.key !== expected.marker.key
        || latest.marker.versionId !== expected.marker.versionId
        || latest.marker.sha256 !== expected.marker.sha256
        || latest.marker.bytes !== expected.marker.bytes
        || commits.size !== expected.revision) throw unavailable();
      const image = selected.image;
      try {
        const metadata = await this.records.readMetadata(image);
        const tag = metadata?.document.toolBackup;
        if (tag) {
          if (image.revision !== 1 || (tag.kind === 'index' && tag.snapshotId !== expected.recordId)) throw unavailable();
          const { payload, ...part } = tag;
          toolParts.set(expected.recordId, { ...part,
            bytes: tag.kind === 'photo' ? image.photoBytes : atob(payload).length });
        }
        if (image.photoKey !== null) {
          if (image.photoCiphertext === null) throw unavailable();
          await this.restorePhoto(image.photoKey, image.photoCiphertext);
          photos++;
        }
        expectedUsedBytes += image.quotaBytes;
        if (!Number.isSafeInteger(expectedUsedBytes)) throw unavailable();
        const statements: D1PreparedStatement[] = [
          this.db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,
            initial_fingerprint,initial_operation,metadata,photo_key,photo_bytes,
            quota_bytes,deleted) VALUES(?,?,?,?,?,?,?,?,?,?)`)
            .bind(ownerId, expected.recordId, image.revision,
              image.initialFingerprint, image.initialOperation,
              image.metadata?.slice().buffer ?? null, image.photoKey,
              image.photoBytes, image.quotaBytes, image.deleted ? 1 : 0),
        ];
        for (const historical of [...commits.values()].sort((a, b) => a.revision - b.revision)) {
          statements.push(this.db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,
            revision,record_object_key,record_version_id,record_sha256,record_bytes,
            photo_object_key,photo_version_id,photo_sha256,photo_bytes,committed_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`)
            .bind(ownerId, expected.recordId, historical.revision, historical.record.key,
              historical.record.versionId, historical.record.sha256, historical.record.bytes,
              historical.photo?.key ?? null, historical.photo?.versionId ?? null,
              historical.photo?.sha256 ?? null, historical.photo?.bytes ?? null, now));
          statements.push(this.db.prepare(`INSERT INTO pa_record_commit_markers(owner_id,record_id,
            revision,marker_object_key,marker_version_id,marker_sha256,marker_bytes,
            confirmed_at) VALUES(?,?,?,?,?,?,?,?)`)
            .bind(ownerId, expected.recordId, historical.revision, historical.marker.key,
              historical.marker.versionId, historical.marker.sha256, historical.marker.bytes, now));
          historyRows++;
        }
        for (const intent of [...intents.values()].sort((a, b) => a.revision - b.revision)) {
          statements.push(this.db.prepare(`INSERT INTO pa_record_delete_intents(owner_id,
            record_id,target_revision,record_object_key,intent_object_key,
            intent_version_id,intent_sha256,intent_bytes,created_at)
            VALUES(?,?,?,?,?,?,?,?,?)`)
            .bind(ownerId, expected.recordId, intent.revision, intent.record.key,
              intent.marker.key, intent.marker.versionId, intent.marker.sha256,
              intent.marker.bytes, now));
        }
        for (let offset = 0; offset < statements.length; offset += 50) {
          await this.db.batch(statements.slice(offset, offset + 50));
        }
      } finally {
        image.metadata?.fill(0);
        image.photoCiphertext?.fill(0);
      }
    }
    await this.rebuildToolReferences(ownerId, toolParts);
    await this.requireNoPurgeIntent(ownerId);
    const count = await this.db.prepare(`SELECT o.disabled,
      (SELECT count(*) FROM pa_records WHERE owner_id=o.owner_id) AS records,
      (SELECT count(*) FROM pa_sessions WHERE owner_id=o.owner_id) AS sessions,
      (SELECT count(*) FROM pa_notice_contacts WHERE owner_id=o.owner_id) AS contacts,
      (SELECT count(*) FROM pa_records WHERE owner_id=o.owner_id AND photo_key IS NOT NULL)
        AS photos,
      (SELECT count(*) FROM pa_record_recovery_versions WHERE owner_id=o.owner_id)
        AS history_rows,
      (SELECT used_bytes FROM pa_inventory WHERE owner_id=o.owner_id) AS used_bytes
      FROM pa_owners o WHERE o.owner_id=?`).bind(ownerId)
      .first<{ disabled: number; records: number; sessions: number;
        contacts: number; photos: number; history_rows: number; used_bytes: number }>();
    if (!count || count.disabled !== 1 || count.records !== candidate.verifiedRecords
      || count.sessions !== 0 || count.contacts !== 0 || count.photos !== photos
      || count.history_rows !== historyRows || count.used_bytes !== expectedUsedBytes) {
      throw unavailable();
    }
    return { status: 'staged-disabled', ownerId, records: count.records, photos };
  }
}
