import { ServiceError } from './contracts';
import { OwnerArchiveRecovery } from './owner-archive-recovery';
import { loadOwnerPurgeReplay } from './purge-intent-replay';
import { RecordRecoveryCopy, type DiscoveredDeleteIntent,
  type DiscoveredRecordCommit } from './record-recovery-copy';
import type { S3PurgeIntentStore } from './s3-purge-intent';

const unavailable = () => new ServiceError('OWNER_QUARANTINE_RESTORE_UNAVAILABLE', 503);

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
      'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>) {}

  private async requireNoPurgeIntent(ownerId: string): Promise<void> {
    if (await loadOwnerPurgeReplay(this.purgeIntents, ownerId) !== 'clear') throw unavailable();
  }

  private async requireEmptyTarget(ownerId: string): Promise<void> {
    const row = await this.db.prepare(`SELECT
      (SELECT count(*) FROM pa_owners) AS owners,
      (SELECT count(*) FROM pa_records) AS records,
      (SELECT count(*) FROM pa_purge_fences) AS fences,
      (SELECT count(*) FROM pa_owner_recovery_versions) AS owner_copies,
      (SELECT count(*) FROM pa_record_recovery_versions) AS record_copies,
      (SELECT delete_intent_required FROM pa_recovery_write_policy WHERE singleton=1)
        AS record_policy,
      (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)
        AS owner_policy`).first<{ owners: number; records: number; fences: number;
        owner_copies: number; record_copies: number; record_policy: number; owner_policy: number }>();
    if (!row || row.owners !== 0 || row.records !== 0 || row.fences !== 0
      || row.owner_copies !== 0 || row.record_copies !== 0
      || row.record_policy !== 0 || row.owner_policy !== 0) throw unavailable();
    const listed = await this.bucket.list({ prefix: `personal/${ownerId}/`, limit: 1 });
    if (listed.objects.length !== 0 || listed.truncated) throw unavailable();
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
