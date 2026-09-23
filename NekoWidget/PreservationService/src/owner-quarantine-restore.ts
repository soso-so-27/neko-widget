import { ServiceError } from './contracts';
import { OwnerArchiveRecovery } from './owner-archive-recovery';
import { RecordRecoveryCopy } from './record-recovery-copy';

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
    private readonly bucket: R2Bucket) {}

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
    const candidate = await this.archive.assembleQuarantineCandidate(ownerId, now);
    if (candidate.status !== 'ready-for-quarantine') return candidate;
    const owner = candidate.owner;
    if (!owner.disabled || owner.contact !== null || owner.purgeFenceId !== null
      || owner.retention?.status === 'expired'
      || (owner.retention?.finalNoticeReceipt ?? null) !== null
      || candidate.verifiedRecords !== owner.records.length
      || candidate.recordMarkers.length !== owner.records.length) throw unavailable();
    await this.requireEmptyTarget(ownerId);
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
    for (const expected of owner.records) {
      const group = markerGroups.get(expected.recordId);
      if (!group) throw unavailable();
      const selected = await this.records.selectRecoveredRecord(ownerId, expected.recordId,
        group);
      if (selected.status !== 'ready' || selected.image.revision !== expected.revision
        || selected.image.deleted !== expected.deleted) throw unavailable();
      const commit = await this.records.inspectCommit(ownerId, expected.marker);
      if (commit.recordId !== expected.recordId || commit.revision !== expected.revision) {
        throw unavailable();
      }
      const image = selected.image;
      try {
        if (image.photoKey !== null) {
          if (image.photoCiphertext === null) throw unavailable();
          await this.restorePhoto(image.photoKey, image.photoCiphertext);
          photos++;
        }
        await this.db.batch([
          this.db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,
            initial_fingerprint,initial_operation,metadata,photo_key,photo_bytes,
            quota_bytes,deleted) VALUES(?,?,?,?,?,?,?,?,?,?)`)
            .bind(ownerId, expected.recordId, image.revision,
              image.initialFingerprint, image.initialOperation,
              image.metadata?.slice().buffer ?? null, image.photoKey,
              image.photoBytes, image.quotaBytes, image.deleted ? 1 : 0),
          this.db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,
            revision,record_object_key,record_version_id,record_sha256,record_bytes,
            photo_object_key,photo_version_id,photo_sha256,photo_bytes,committed_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`)
            .bind(ownerId, expected.recordId, image.revision, commit.record.key,
              commit.record.versionId, commit.record.sha256, commit.record.bytes,
              commit.photo?.key ?? null, commit.photo?.versionId ?? null,
              commit.photo?.sha256 ?? null, commit.photo?.bytes ?? null, now),
          this.db.prepare(`INSERT INTO pa_record_commit_markers(owner_id,record_id,
            revision,marker_object_key,marker_version_id,marker_sha256,marker_bytes,
            confirmed_at) VALUES(?,?,?,?,?,?,?,?)`)
            .bind(ownerId, expected.recordId, image.revision, expected.marker.key,
              expected.marker.versionId, expected.marker.sha256, expected.marker.bytes, now),
        ]);
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
        AS photos
      FROM pa_owners o WHERE o.owner_id=?`).bind(ownerId)
      .first<{ disabled: number; records: number; sessions: number;
        contacts: number; photos: number }>();
    if (!count || count.disabled !== 1 || count.records !== candidate.verifiedRecords
      || count.sessions !== 0 || count.contacts !== 0 || count.photos !== photos) throw unavailable();
    return { status: 'staged-disabled', ownerId, records: count.records, photos };
  }
}
