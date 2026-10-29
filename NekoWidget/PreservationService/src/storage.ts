import { ServiceError, sha256, type ArchiveDocument, type KeyCustody, type MembershipAuthority,
  type PhotoValidator, type Session } from './contracts';
import { decodePhoto, encodePhoto, MAX_PHOTO_BYTES, recordId, validateDocument, toolIndexRecordIDs, parseAppRecordHead, isToolFragmentPath } from './documents';
import { parseToolNode, summarizeToolNode, validateToolNodePaths, toolNodeReferences, isCompleteToolRoot } from './tool-index-v4';
import { RecordRecoveryCopy, type CommittedRecordImage,
  type CopiedRecordImage, type StoredRecordImage } from './record-recovery-copy';
import type { OwnerRecoveryCopy } from './owner-recovery-copy';
import type { ToolOwnerTrial } from './tool-owner-trial';
import { exportPage } from './export-page';
import { ToolMetadataBatches } from './tool-metadata-batches';
import { pendingProductQuota, type ProductQuotaSettings } from './product-quota-policy';

interface Row {
  owner_id: string; record_id: string; revision: number; initial_fingerprint: string; initial_operation: string;
  metadata: ArrayBuffer; photo_key: string | null; photo_bytes: number; quota_bytes: number; deleted: number;
}
interface Metadata {
  version: 1; ownerId: string; recordId: string; revision: number; document: ArchiveDocument;
  photoSHA256: string | null; photoBytes: number;
}
interface UsageRow {
  inventory_owner: string | null; used_bytes: number; reserved_bytes: number;
  saved_records: number; record_identifiers: number; pending_records: number;
  record_bytes: number; upload_bytes: number; unacknowledged_records: number;
  accounting_valid: number;
}
interface Dependencies {
  productQuotaSettings?: ProductQuotaSettings;
  db: D1Database; bucket: R2Bucket; keys: KeyCustody; membership: MembershipAuthority; photos: PhotoValidator;
  auth: { requireSession(token: string): Promise<Session>; requireToolMetadataBatchSession?(token: string, batchId: string): Promise<Session> }; now: () => number; quotaBytes: number; maximumRecords: number;
  /** Operational admission cap across all owners. This does not cap S3 history or request charges. */
  globalActiveBytesLimit?: number;
  requireGlobalAdmissionLimit?: boolean;
  intakeControl?: { admit(plannedBytes: number): Promise<void> };
  requireIntakeControl?: boolean;
  mutationAdmission?: { admitMutation(ownerId: string, plannedBytes: number): Promise<void> };
  toolTrial?: ToolOwnerTrial;
  pilotStorageAccess?: import('./pilot-control').PilotStorageAccess;
  recovery?: RecordRecoveryCopy;
  ownerRecovery?: OwnerRecoveryCopy;
  requireRecovery?: boolean;
  requireOwnerRecovery?: boolean;
  ownerWriteLease?: { withOwnerWrite<T>(ownerId: string, action: () => Promise<T>): Promise<T> };
}
const bytes = (value: unknown): ArrayBuffer => {
  if (value instanceof ArrayBuffer) return value;
  if (value instanceof Uint8Array || Array.isArray(value)) return new Uint8Array(value).buffer;
  throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
};
const activeSessionBase = `EXISTS(SELECT 1 FROM pa_sessions s JOIN pa_owners o ON o.owner_id=s.owner_id
  WHERE s.session_hash=? AND s.owner_id=? AND s.expires_at>? AND o.disabled=0 AND o.purge_fence_id IS NULL AND s.owner_epoch=o.epoch
    AND (s.device_grant_id IS NULL OR EXISTS(SELECT 1 FROM pa_device_session_grants g
      WHERE g.grant_id=s.device_grant_id AND g.owner_id=o.owner_id AND g.owner_epoch=o.epoch
        AND g.revoked_at IS NULL AND g.idle_expires_at>?)))`;
const activeSession=activeSessionBase;
const exactLegacy = `EXISTS(SELECT 1 FROM pa_record_legacy_baseline b
  WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
  AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint
  AND b.photo_key IS r.photo_key
  AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)`;
const revisionValue = (value: unknown): number => {
  if (!Number.isSafeInteger(value) || (value as number) < 1) throw new ServiceError('INVALID_REVISION');
  return value as number;
};

export class ArchiveStore {
  constructor(private readonly d: Dependencies) {
    if (!Number.isSafeInteger(d.quotaBytes) || d.quotaBytes < 1 || !Number.isSafeInteger(d.maximumRecords)
      || d.maximumRecords < 1 || (d.globalActiveBytesLimit !== undefined
        && (!Number.isSafeInteger(d.globalActiveBytesLimit) || d.globalActiveBytesLimit < 1))) {
      throw new ServiceError('PRESERVATION_NOT_CONFIGURED', 503);
    }
  }
  async exportPage(token: string, request: Request, context?: Pick<ExecutionContext, 'waitUntil'>): Promise<Response> {
    return exportPage({ db: this.d.db, auth: this.d.auth, read: (value, id) => this.readBinary(value, id) }, request, token, context);
  }
  private sessionBindings(session: Session): [string, string, number, number] {
    const now=this.d.now();
    return [session.sessionHash, session.ownerId, now, now];
  }
  private async row(owner: string, id: string): Promise<Row | null> {
    return this.d.db.prepare('SELECT * FROM pa_records WHERE owner_id=? AND record_id=?').bind(owner, id).first<Row>();
  }
  private async generation(owner: string): Promise<number> {
    return (await this.d.db.prepare('SELECT generation FROM pa_inventory WHERE owner_id=?').bind(owner)
      .first<{ generation: number }>())?.generation ?? 0;
  }
  private async paid(owner: string) {
    const state = await this.d.membership.status(owner);
    if (state === 'unknown') throw new ServiceError('ACCESS_UNCONFIRMED', 503);
    if (!['active', 'grace'].includes(state)) throw new ServiceError('NEW_SAVE_REQUIRES_MEMBERSHIP', 403);
  }
  private requireRecovery(): void {
    if ((this.d.requireRecovery && !this.d.recovery)
      || (this.d.requireOwnerRecovery && !this.d.ownerRecovery)) {
      throw new ServiceError('RECOVERY_COPY_UNAVAILABLE', 503);
    }
  }
  private async acknowledgeOwnerInventory(ownerId: string): Promise<void> {
    if (this.d.requireOwnerRecovery) {
      await this.d.ownerRecovery!.copyCurrent(this.d.db, ownerId, this.d.now());
    }
  }
  private async requireWritePolicy(): Promise<void> {
    if (!this.d.requireRecovery) return;
    const policy = await this.d.db.prepare(`SELECT delete_intent_required,owner_snapshot_required
      FROM pa_recovery_write_policy WHERE singleton=1`)
      .first<{ delete_intent_required: number; owner_snapshot_required: number }>();
    if (policy?.delete_intent_required !== 1
      || (this.d.requireOwnerRecovery && policy.owner_snapshot_required !== 1)) {
      throw new ServiceError('RECOVERY_POLICY_INACTIVE', 503);
    }
  }
  private recoveryReference(ownerId: string, id: string, revision: number, copy: CopiedRecordImage) {
    // D1 meta.changes includes accounting-trigger writes. RETURNING identifies
    // the single recovery row attached by the immediately preceding record CAS.
    return this.d.db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,revision,
      record_object_key,record_version_id,record_sha256,record_bytes,
      photo_object_key,photo_version_id,photo_sha256,photo_bytes,committed_at)
      SELECT ?,?,?,?,?,?,?,?,?,?,?,? WHERE changes()=1 AND EXISTS(SELECT 1 FROM pa_records
        WHERE owner_id=? AND record_id=? AND revision=?) RETURNING revision`)
      .bind(ownerId, id, revision, copy.record.key, copy.record.versionId,
        copy.record.sha256, copy.record.bytes, copy.photo?.key ?? null,
        copy.photo?.versionId ?? null, copy.photo?.sha256 ?? null, copy.photo?.bytes ?? null,
        this.d.now(), ownerId, id, revision);
  }
  private async verifiedRecoveryReference(ownerId: string, id: string, revision: number) {
    if (!this.d.recovery) return;
    const row = await this.d.db.prepare(`SELECT record_object_key,record_version_id,record_sha256,
      record_bytes,photo_object_key,photo_version_id,photo_sha256,photo_bytes,
      m.marker_object_key,m.marker_version_id,m.marker_sha256,m.marker_bytes
      FROM pa_record_recovery_versions v LEFT JOIN pa_record_commit_markers m
        ON m.owner_id=v.owner_id AND m.record_id=v.record_id AND m.revision=v.revision
      WHERE v.owner_id=? AND v.record_id=? AND v.revision=?`)
      .bind(ownerId, id, revision).first<{ record_object_key: string; record_version_id: string;
        record_sha256: string; record_bytes: number; photo_object_key: string | null;
        photo_version_id: string | null; photo_sha256: string | null; photo_bytes: number | null;
        marker_object_key: string | null; marker_version_id: string | null;
        marker_sha256: string | null; marker_bytes: number | null }>();
    if (!row) throw new ServiceError('RECOVERY_RECORD_UNAVAILABLE', 503);
    const copied: CopiedRecordImage = { record: { key: row.record_object_key,
      versionId: row.record_version_id, sha256: row.record_sha256, bytes: row.record_bytes },
    photo: row.photo_object_key === null ? null : { key: row.photo_object_key,
      versionId: row.photo_version_id ?? '', sha256: row.photo_sha256 ?? '', bytes: row.photo_bytes ?? 0 } };
    let marker = row.marker_object_key === null ? null : { key: row.marker_object_key,
      versionId: row.marker_version_id ?? '', sha256: row.marker_sha256 ?? '', bytes: row.marker_bytes ?? 0 };
    if (!marker) {
      const uploaded = await this.d.recovery.commit(ownerId, id, revision, copied);
      await this.d.db.prepare(`INSERT OR IGNORE INTO pa_record_commit_markers(owner_id,record_id,revision,
        marker_object_key,marker_version_id,marker_sha256,marker_bytes,confirmed_at)
        SELECT ?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pa_record_recovery_versions
          WHERE owner_id=? AND record_id=? AND revision=? AND record_object_key=?)`)
        .bind(ownerId, id, revision, uploaded.key, uploaded.versionId, uploaded.sha256,
          uploaded.bytes, this.d.now(), ownerId, id, revision, copied.record.key).run();
      const confirmed = await this.d.db.prepare(`SELECT marker_object_key,marker_version_id,
        marker_sha256,marker_bytes FROM pa_record_commit_markers
        WHERE owner_id=? AND record_id=? AND revision=?`).bind(ownerId, id, revision)
        .first<{ marker_object_key: string; marker_version_id: string;
          marker_sha256: string; marker_bytes: number }>();
      if (!confirmed) throw new ServiceError('RECOVERY_RECORD_UNAVAILABLE', 503);
      marker = { key: confirmed.marker_object_key, versionId: confirmed.marker_version_id,
        sha256: confirmed.marker_sha256, bytes: confirmed.marker_bytes };
    }
    const image = await this.d.recovery.readCommitted(ownerId, id,
      { ...copied, marker } satisfies CommittedRecordImage);
    if (image.revision !== revision) throw new ServiceError('RECOVERY_RECORD_UNAVAILABLE', 503);
  }
  private async requireAcknowledged(ownerId: string, id: string, revision: number) {
    if (!this.d.requireRecovery) return;
    const row = await this.d.db.prepare(`SELECT v.record_object_key,m.marker_object_key,
      ${exactLegacy} AS legacy FROM pa_records r
      LEFT JOIN pa_record_recovery_versions v
        ON v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision
      LEFT JOIN pa_record_commit_markers m
        ON m.owner_id=v.owner_id AND m.record_id=v.record_id AND m.revision=v.revision
      WHERE r.owner_id=? AND r.record_id=? AND r.revision=?`).bind(ownerId, id, revision)
      .first<{ record_object_key: string | null; marker_object_key: string | null; legacy: number }>();
    if (!row) throw new ServiceError('ARCHIVE_CHANGED', 409);
    if (!row.record_object_key) {
      if (row.legacy === 1) return;
      throw new ServiceError('RECOVERY_PENDING', 503);
    }
    if (row.marker_object_key) return;
    if (!this.d.recovery) throw new ServiceError('RECOVERY_PENDING', 503);
    try { await this.verifiedRecoveryReference(ownerId, id, revision); }
    catch { throw new ServiceError('RECOVERY_PENDING', 503); }
  }
  private async ensureCurrentRecovery(row: Row, session?: Session) {
    if (!this.d.recovery) return;
    if (session && session.ownerId !== row.owner_id) throw new ServiceError('SESSION_INVALID', 401);
    const existing = await this.d.db.prepare(`SELECT 1 AS found FROM pa_record_recovery_versions
      WHERE owner_id=? AND record_id=? AND revision=?`).bind(row.owner_id, row.record_id, row.revision)
      .first<{ found: number }>();
    if (existing) {
      await this.verifiedRecoveryReference(row.owner_id, row.record_id, row.revision);
      return;
    }
    const baseline = await this.d.db.prepare(`SELECT 1 AS found FROM pa_records r
      WHERE r.owner_id=? AND r.record_id=? AND r.revision=? AND ${exactLegacy}`)
      .bind(row.owner_id, row.record_id, row.revision).first<{ found: number }>();
    if (!baseline) throw new ServiceError('RECOVERY_PENDING', 503);
    const data = row.deleted ? null : await this.metadata(row);
    const encrypted = data === null ? null : await this.encryptedPhoto(row, data);
    if (row.quota_bytes !== (row.deleted ? 0 : bytes(row.metadata).byteLength + (encrypted?.length ?? 0))) {
      throw new ServiceError('ARCHIVE_ACCOUNTING_UNAVAILABLE', 503);
    }
    const copied = await this.d.recovery.copy({ ownerId: row.owner_id, recordId: row.record_id,
      revision: row.revision, initialFingerprint: row.initial_fingerprint,
      initialOperation: row.initial_operation, metadata: row.deleted ? null : new Uint8Array(bytes(row.metadata)),
      photoKey: row.photo_key, photoBytes: row.photo_bytes, quotaBytes: row.quota_bytes,
      deleted: row.deleted === 1, photoCiphertext: encrypted });
    await this.d.db.prepare(`INSERT OR IGNORE INTO pa_record_recovery_versions(owner_id,record_id,revision,
      record_object_key,record_version_id,record_sha256,record_bytes,
      photo_object_key,photo_version_id,photo_sha256,photo_bytes,committed_at)
      SELECT ?,?,?,?,?,?,?,?,?,?,?,? FROM pa_records r WHERE r.owner_id=? AND r.record_id=?
      AND r.revision=? AND ${exactLegacy}${session ? ` AND ${activeSession}` : ''}`)
      .bind(row.owner_id, row.record_id, row.revision, copied.record.key,
        copied.record.versionId, copied.record.sha256, copied.record.bytes,
        copied.photo?.key ?? null, copied.photo?.versionId ?? null,
        copied.photo?.sha256 ?? null, copied.photo?.bytes ?? null, this.d.now(),
        row.owner_id, row.record_id, row.revision,
        ...(session ? this.sessionBindings(session) : [])).run();
    await this.verifiedRecoveryReference(row.owner_id, row.record_id, row.revision);
  }
  /** Bounded internal maintenance. Launch still requires an owner-wide audit
   * with zero missing or pending revisions, not merely one successful page.
   */
  async repairRecoveryBatch(limit = 20, options: { includeLegacy?: boolean } = {}) {
    if (!this.d.recovery) throw new ServiceError('RECOVERY_COPY_UNAVAILABLE', 503);
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new ServiceError('INVALID_PAGE_SIZE');
    const cursor = await this.d.db.prepare(`SELECT last_owner_id,last_record_id
      FROM pa_recovery_repair_cursor WHERE singleton=1`)
      .first<{ last_owner_id: string; last_record_id: string }>();
    if (!cursor) throw new ServiceError('RECOVERY_RECORD_UNAVAILABLE', 503);
    const pending = `
      (EXISTS(SELECT 1 FROM pa_record_recovery_versions v
        WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
        OR ${options.includeLegacy === false ? '0' : exactLegacy})
      AND NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m
        WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)`;
    const after = await this.d.db.prepare(`SELECT r.* FROM pa_records r
      JOIN pa_owners o ON o.owner_id=r.owner_id
      WHERE o.purge_fence_id IS NULL AND ${pending}
      AND (r.owner_id>? OR (r.owner_id=? AND r.record_id>?))
      ORDER BY r.owner_id,r.record_id LIMIT ?`)
      .bind(cursor.last_owner_id, cursor.last_owner_id, cursor.last_record_id, limit).all<Row>();
    const rows = after.results.length ? after.results : (await this.d.db.prepare(`SELECT r.*
      FROM pa_records r JOIN pa_owners o ON o.owner_id=r.owner_id
      WHERE o.purge_fence_id IS NULL AND ${pending}
      ORDER BY r.owner_id,r.record_id LIMIT ?`)
      .bind(limit).all<Row>()).results;
    let failed = 0;
    for (const row of rows) {
      try {
        await this.ensureCurrentRecovery(row);
        await this.d.db.prepare(`DELETE FROM pa_recovery_repair_failures WHERE owner_id=? AND record_id=?`)
          .bind(row.owner_id, row.record_id).run();
      } catch (error) {
        failed++;
        const code = error instanceof ServiceError ? error.code : 'RECOVERY_REPAIR_UNAVAILABLE';
        await this.d.db.prepare(`INSERT INTO pa_recovery_repair_failures(owner_id,record_id,
          error_code,attempts,last_attempt_at) VALUES(?,?,?,1,?)
          ON CONFLICT(owner_id,record_id) DO UPDATE SET error_code=excluded.error_code,
          attempts=attempts+1,last_attempt_at=excluded.last_attempt_at`)
          .bind(row.owner_id, row.record_id, code, this.d.now()).run();
      }
    }
    if (rows.length) await this.d.db.prepare(`UPDATE pa_recovery_repair_cursor
      SET last_owner_id=?,last_record_id=? WHERE singleton=1`)
      .bind(rows.at(-1)!.owner_id, rows.at(-1)!.record_id).run();
    return { processed: rows.length, failed };
  }
  /** Local D1 coverage only. Zero gaps is necessary but cannot replace an
   * S3 inventory and actual restore drill before the service is enabled.
   */
  async recoveryLedgerCoverage() {
    const counts = await this.d.db.prepare(`SELECT count(*) AS total,
      coalesce(sum(CASE WHEN m.marker_object_key IS NOT NULL THEN 1 ELSE 0 END),0) AS confirmed,
      coalesce(sum(CASE WHEN v.record_object_key IS NULL AND ${exactLegacy}
        THEN 1 ELSE 0 END),0) AS legacy_unbacked,
      coalesce(sum(CASE WHEN v.record_object_key IS NOT NULL AND m.marker_object_key IS NULL
        THEN 1 ELSE 0 END),0) AS pending_marker,
      coalesce(sum(CASE WHEN v.record_object_key IS NULL AND NOT ${exactLegacy}
        THEN 1 ELSE 0 END),0) AS unknown_unbacked
      FROM pa_records r LEFT JOIN pa_record_recovery_versions v
        ON v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision
      LEFT JOIN pa_record_commit_markers m
        ON m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision`)
      .first<{ total: number; confirmed: number; legacy_unbacked: number;
        pending_marker: number; unknown_unbacked: number }>();
    if (!counts || Object.values(counts).some(value => !Number.isSafeInteger(value) || value < 0)
      || counts.total !== counts.confirmed + counts.legacy_unbacked
        + counts.pending_marker + counts.unknown_unbacked) {
      throw new ServiceError('RECOVERY_RECORD_UNAVAILABLE', 503);
    }
    return { total: counts.total, confirmed: counts.confirmed,
      legacyUnbacked: counts.legacy_unbacked, pendingMarker: counts.pending_marker,
      unknownUnbacked: counts.unknown_unbacked };
  }
  private async encryptedPhoto(row: Row, expected: Metadata): Promise<Uint8Array | null> {
    if (!row.photo_key) return null;
    const object = await this.d.bucket.get(row.photo_key);
    if (!object || object.size > 30 * 1024 * 1024) throw new ServiceError('ARCHIVE_PHOTO_UNAVAILABLE', 503);
    const encrypted = new Uint8Array(await object.arrayBuffer());
    const opened = await this.d.keys.open(encrypted,
      { ownerId: row.owner_id, purpose: 'record', recordId: `${row.record_id}/photo` });
    if (opened.length !== expected.photoBytes || await sha256(opened) !== expected.photoSHA256) {
      throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
    }
    return encrypted;
  }
  private async metadata(row: Row): Promise<Metadata> {
    try {
      const opened = await this.d.keys.open(new Uint8Array(bytes(row.metadata)),
        { ownerId: row.owner_id, purpose: 'record', recordId: `${row.record_id}/document` });
      const data = JSON.parse(new TextDecoder().decode(opened)) as Metadata;
      if (data.version !== 1 || data.ownerId !== row.owner_id || data.recordId !== row.record_id
        || data.revision !== row.revision || data.photoBytes !== row.photo_bytes
        || (data.photoSHA256 === null) !== (row.photo_key === null)) throw new Error();
      data.document = validateDocument(data.document);
      if ((data.document.photoFile === null) !== (row.photo_key === null)
        || (data.photoSHA256 !== null && !/^[0-9a-f]{64}$/.test(data.photoSHA256))) throw new Error();
      return data;
    } catch { throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503); }
  }
  private async unchanged(token: string, session: Session, row: Row, authorize?:()=>Promise<Session>) {
    const current = await (authorize ? authorize() : this.d.auth.requireSession(token));
    if (current.ownerId !== session.ownerId) throw new ServiceError('SESSION_INVALID', 401);
    const latest = await this.row(session.ownerId, row.record_id);
    if (!latest || latest.deleted) throw new ServiceError('RECORD_NOT_FOUND', 404);
    if (latest.revision !== row.revision) throw new ServiceError('REVISION_CONFLICT', 409);
  }
  async usage(token: string) {
    const session = await this.d.auth.requireSession(token);
    // One SQL snapshot: do not mix a committed record count with an earlier
    // reservation total. No photo download, decryption or membership lookup.
    const row = await this.d.db.prepare(`SELECT i.owner_id AS inventory_owner,
      coalesce(i.used_bytes,0) AS used_bytes, coalesce(i.reserved_bytes,0) AS reserved_bytes,
      d.live_count AS saved_records,
      d.record_count AS record_identifiers,
      (SELECT count(*) FROM pa_uploads u WHERE u.owner_id=o.owner_id) AS pending_records,
      d.record_bytes AS record_bytes,
      (SELECT coalesce(sum(reserved_bytes),0) FROM pa_uploads u WHERE u.owner_id=o.owner_id) AS upload_bytes
      ,d.pending_ack AS unacknowledged_records,d.accounting_valid
      FROM pa_owners o LEFT JOIN pa_inventory i ON i.owner_id=o.owner_id
      LEFT JOIN pa_owner_record_counters d ON d.owner_id=o.owner_id
      WHERE o.owner_id=? AND ${activeSession}`)
      .bind(session.ownerId, ...this.sessionBindings(session)).first<UsageRow>();
    const current = await this.d.auth.requireSession(token);
    if (!row || current.ownerId !== session.ownerId || current.sessionHash !== session.sessionHash) {
      throw new ServiceError('SESSION_INVALID', 401);
    }
    if (this.d.requireRecovery && row.unacknowledged_records > 0) {
      throw new ServiceError('RECOVERY_PENDING', 503);
    }
    const counters = [row.used_bytes, row.reserved_bytes, row.saved_records, row.record_identifiers,
      row.pending_records, row.record_bytes, row.upload_bytes, row.unacknowledged_records];
    if (row.accounting_valid !== 1 || counters.some(value => !Number.isSafeInteger(value) || value < 0)
      || !Number.isSafeInteger(row.used_bytes + row.reserved_bytes)
      || !Number.isSafeInteger(row.record_identifiers + row.pending_records)
      || row.saved_records > row.record_identifiers || row.unacknowledged_records > row.record_identifiers
      || row.used_bytes !== row.record_bytes || row.reserved_bytes !== row.upload_bytes
      || (!row.inventory_owner && counters.some(value => value !== 0))) {
      // Missing/corrupt accounting is not an empty archive. Never repair it by
      // dropping records or by reporting fabricated free capacity.
      throw new ServiceError('ARCHIVE_ACCOUNTING_UNAVAILABLE', 503);
    }
    const allocated = row.used_bytes + row.reserved_bytes;
    const trial = await this.d.toolTrial?.usage(session.ownerId);
    const limitBytes = trial ? Math.max(1, Math.min(this.d.quotaBytes, allocated + trial.remainingBytes)) : this.d.quotaBytes;
    const maximumRecords = trial ? Math.max(1, Math.min(this.d.maximumRecords,
      row.saved_records + row.pending_records + trial.remainingRecords)) : this.d.maximumRecords;
    return { version: 1, accounting: 'encrypted-records-v1', toolSnapshots: { maximumIndexVersion: trial ? 3 : 4, strictPartDeletion: true, metadataBatchVersion: this.d.requireOwnerRecovery && !!this.d.auth.requireToolMetadataBatchSession && this.d.ownerRecovery?.supportsMetadataBatch() ? 1 : 0 },
      storage: { usedBytes: row.used_bytes, reservedBytes: row.reserved_bytes, limitBytes,
        availableBytes: Math.max(0, limitBytes - allocated), overLimit: allocated > limitBytes },
      records: { saved: row.saved_records, pending: row.pending_records, maximumRecords,
        // Keep tombstones for replay protection, but do not let lifetime deletions
        // exhaust the number of records a customer may currently keep.
        creationLimitReached: row.saved_records + row.pending_records >= maximumRecords },
      ...(this.d.productQuotaSettings ? { productQuota: pendingProductQuota(this.d.productQuotaSettings) } : {}) };
  }
  async list(token: string, after = '', limit = 20, visibleOnly = false) {
    if (after) recordId(after);
    if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw new ServiceError('INVALID_PAGE_SIZE');
    const session = await this.d.auth.requireSession(token);
    const generation = await this.generation(session.ownerId);
    const rows = await this.d.db.prepare(`SELECT *, NOT EXISTS(SELECT 1 FROM pa_tool_part_delete_claims c
      WHERE c.owner_id=pa_records.owner_id AND c.part_id=pa_records.record_id) AS tool_reusable
      FROM pa_records WHERE owner_id=? AND deleted=0 AND record_id>?
      ${visibleOnly ? `AND NOT EXISTS(SELECT 1 FROM pa_tool_record_sources s
        WHERE s.owner_id=pa_records.owner_id AND s.record_id=pa_records.record_id
        AND (s.kind<>'index' OR s.upload_snapshot_id IS NOT NULL))` : ''}
      ORDER BY record_id LIMIT ?`).bind(session.ownerId, after, limit + 1).all<Row & { tool_reusable: number }>();
    const items = [];
    for (const row of rows.results.slice(0, limit)) {
      await this.requireAcknowledged(session.ownerId, row.record_id, row.revision);
      const document = (await this.metadata(row)).document;
      // Old clients validate every list item before hiding transport records.
      // Fragments are readable by ID, but must never reach their flat parser.
      if (document.toolBackup && isToolFragmentPath(document.toolBackup.path)) continue;
      items.push({ recordId: row.record_id, revision: row.revision, document,
        ...(document.toolBackup?.kind === 'photo' ? { toolPhotoReusable: row.tool_reusable === 1 } : {}) });
    }
    await this.d.auth.requireSession(token);
    if (await this.generation(session.ownerId) !== generation) throw new ServiceError('ARCHIVE_CHANGED', 409);
    return { items, generation, nextCursor: rows.results.length > limit ? rows.results[limit - 1]!.record_id : null };
  }
  async read(token: string, id: string) {
    const { photo, ...record } = await this.readBinary(token, id);
    return { ...record, photoBase64: encodePhoto(photo) };
  }
  async readBinary(token: string, id: string) {
    recordId(id);
    const session = await this.d.auth.requireSession(token);
    const row = await this.row(session.ownerId, id);
    if (!row || row.deleted) throw new ServiceError('RECORD_NOT_FOUND', 404);
    await this.requireAcknowledged(session.ownerId, id, row.revision);
    const data = await this.metadata(row);
    let photo: Uint8Array | null = null;
    if (row.photo_key) {
      const object = await this.d.bucket.get(row.photo_key);
      if (!object || object.size > 30 * 1024 * 1024) throw new ServiceError('ARCHIVE_PHOTO_UNAVAILABLE', 503);
      photo = await this.d.keys.open(new Uint8Array(await object.arrayBuffer()),
        { ownerId: session.ownerId, purpose: 'record', recordId: `${id}/photo` });
      if (photo.length !== data.photoBytes || await sha256(photo) !== data.photoSHA256) {
        throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
      }
    }
    await this.unchanged(token, session, row);
    return { recordId: id, revision: row.revision, document: data.document, photo,
      photoSHA256: data.photoSHA256 };
  }
  async validateRead(token: string, id: string, revision: number, ownerId: string) {
    const session = await this.d.auth.requireSession(token);
    if (session.ownerId !== ownerId) throw new ServiceError('SESSION_INVALID', 401);
    const row = await this.d.db.prepare('SELECT revision,deleted FROM pa_records WHERE owner_id=? AND record_id=?')
      .bind(session.ownerId, id).first<{ revision: number; deleted: number }>();
    if (!row || row.deleted) throw new ServiceError('RECORD_NOT_FOUND', 404);
    if (row.revision !== revision) throw new ServiceError('REVISION_CONFLICT', 409);
  }
  private metadataBatches():ToolMetadataBatches {
    const continuation=this.d.auth.requireToolMetadataBatchSession;
    if(!continuation || !this.d.requireOwnerRecovery || !this.d.ownerRecovery?.supportsMetadataBatch())throw new ServiceError('PRESERVATION_NOT_CONFIGURED',503);
    return new ToolMetadataBatches(this.d.db,{requireSession:token=>this.d.auth.requireSession(token),
      requireToolMetadataBatchSession:(token,id)=>continuation.call(this.d.auth,token,id)},this.d.now);
  }
  async beginMetadataBatch(token:string,input:unknown){
    const batches=this.metadataBatches();
    let covered:Session|undefined;
    try{covered=await this.d.auth.requireSession(token);}catch{}
    // Seed a missing derived cursor before the first part can uncover the owner.
    if(covered)await this.d.ownerRecovery?.copyCurrent(this.d.db,covered.ownerId,this.d.now());
    return batches.begin(token,input);
  }
  stageMetadataBatch(token:string,batchId:string,id:string,raw:Uint8Array){
    return this.metadataBatches().stage(token,batchId,id,raw,(input,authorize,nonce)=>this.putInternal(token,id,input,{id:batchId,nonce,authorize}));
  }
  finishMetadataBatch(token:string,batchId:string){
    return this.metadataBatches().finish(token,batchId,async owner=>
      (await this.d.ownerRecovery!.copyCurrentStep(this.d.db,owner,this.d.now())).status==='complete');
  }
  recoverMetadataBatch(token:string,batchId:string){
    return this.metadataBatches().recover(token,batchId,async owner=>
      (await this.d.ownerRecovery!.copyCurrentStep(this.d.db,owner,this.d.now())).status==='complete');
  }
  async put(token: string, id: string, input: unknown) {
    return this.putInternal(token,id,input);
  }
  private async putInternal(token:string,id:string,input:unknown,batch?:{id:string;nonce:string;authorize:()=>Promise<Session>}) {
    const authorize=batch?.authorize ?? (()=>this.d.auth.requireSession(token));
    const activeSession=batch ? `${activeSessionBase} AND EXISTS(SELECT 1 FROM pa_tool_metadata_batches b
      JOIN pa_sessions bs ON bs.owner_id=b.owner_id WHERE bs.session_hash=? AND b.batch_id='${batch.id}'
      AND b.owner_epoch=bs.owner_epoch AND b.batch_nonce='${batch.nonce}' AND b.state='open')` : activeSessionBase;
    const sessionBindings=(session:Session)=>[...this.sessionBindings(session),...(batch?[session.sessionHash]:[])];
    const acknowledge=async(owner:string)=>{if(!batch)await this.acknowledgeOwnerInventory(owner);};
    recordId(id);
    const session = await authorize();
    // Bound every PUT before decoding, hashing, key use or backup writes. Even
    // edits carry the photo input, although its unchanged S3 copy is reused.
    const encoded = input && typeof input === 'object'
      ? (input as Record<string, unknown>).photoBase64 : undefined;
    const plannedPhoto = typeof encoded === 'string'
      ? Math.min(MAX_PHOTO_BYTES, Math.ceil(encoded.length / 4) * 3) : 0;
    const plannedBytes = plannedPhoto + 512 * 1024 + 8192;
    const trial = await this.d.toolTrial?.admit(session.ownerId, id, input);
    this.requireRecovery();
    await this.requireWritePolicy();
    if (!trial) await this.d.mutationAdmission?.admitMutation(session.ownerId, plannedBytes);
    const existing = await this.row(session.ownerId, id);
    if (existing?.deleted) throw new ServiceError('RECORD_DELETED', 409);
    const pilotAccess = trial ? { expiresAt: Math.min(trial.grant.ends_at, trial.grant.valid_until) }
      : !existing && await this.d.pilotStorageAccess?.allowed(session.ownerId);
    if (!trial && !existing && (this.d.requireIntakeControl || this.d.intakeControl)) {
      if (!this.d.intakeControl) throw new ServiceError('PRESERVATION_INTAKE_PAUSED', 503);
      // Authenticate membership before spending the shared allowance. Classify
      // by the server-owned row, never by caller-supplied expectedRevision.
      if (!pilotAccess) await this.paid(session.ownerId);
      // O(1) conservative estimate; no base64 decoding or hashing before admission.
      // Malformed input still consumes an attempt, but never exceeds the photo cap.
      await this.d.intakeControl.admit(plannedBytes);
    }
    if (this.d.requireOwnerRecovery && !batch) {
      await this.d.ownerRecovery!.copyCurrent(this.d.db, session.ownerId, this.d.now());
    }
    if (!input || typeof input !== 'object') throw new ServiceError('INVALID_RECORD');
    const request = input as Record<string, unknown>;
    if (Object.keys(request).some((key) => !['document', 'photoBase64', 'expectedRevision', 'consentVersion'].includes(key))) {
      throw new ServiceError('INVALID_RECORD');
    }
    const document = trial?.document ?? validateDocument(request.document);
    const photo = trial ? trial.photo : decodePhoto(request.photoBase64);
    if ((photo === null) !== (document.photoFile === null)) throw new ServiceError('INVALID_RECORD');
    const photoSHA256 = trial ? trial.photoSHA256 : photo === null ? null : await sha256(photo);
    if (document.toolBackup?.kind === 'photo' && document.toolBackup.sha256 !== photoSHA256) throw new ServiceError('INVALID_RECORD');
    if (document.toolBackup && document.toolBackup.kind !== 'photo'
      && await sha256(Uint8Array.from(atob(document.toolBackup.payload), c => c.charCodeAt(0))) !== document.toolBackup.sha256) throw new ServiceError('INVALID_RECORD');
    if (document.toolBackup && request.expectedRevision !== null) throw new ServiceError('REVISION_CONFLICT', 409);
    let toolIndexGeneration: number | null = null;
    let sharedToolReferences: string[] = [];
    const appHead = parseAppRecordHead(document);
    let appHeadVersion: number | null = null;
    const parsedIndex = document.toolBackup?.kind === 'index' ? parseToolNode(document.toolBackup) : null;
    const uploadSnapshotID = parsedIndex?.version === 4 ? parsedIndex.uploadSnapshotID.toLowerCase() : null;
    const assertTransferActive = async () => {
      if (document.toolBackup && await this.d.db.prepare(`SELECT 1 FROM pa_tool_snapshot_abandonments
        WHERE owner_id=? AND snapshot_id IN (?,?)`).bind(session.ownerId,
          document.toolBackup.snapshotId,uploadSnapshotID ?? document.toolBackup.snapshotId).first()) {
        throw new ServiceError('TOOL_SNAPSHOT_ABANDONED', 409);
      }
    };
    await assertTransferActive();
    if (appHead) {
      toolIndexGeneration = await this.generation(session.ownerId);
      const target = await this.row(session.ownerId, appHead.snapshotID.toLowerCase());
      if (!target || target.deleted || target.revision !== 1) throw new ServiceError('REVISION_CONFLICT', 409);
      const index = (await this.metadata(target)).document.toolBackup;
      if (!index || index.kind !== 'index' || index.snapshotId !== target.record_id
        || index.sha256 !== appHead.indexHash || !isCompleteToolRoot(parseToolNode(index))
        || await sha256(Uint8Array.from(atob(index.payload), c => c.charCodeAt(0))) !== index.sha256
        || await this.d.db.prepare('SELECT 1 FROM pa_tool_part_delete_claims WHERE owner_id=? AND part_id=?')
          .bind(session.ownerId, target.record_id).first()) throw new ServiceError('REVISION_CONFLICT', 409);
      appHeadVersion = parseToolNode(index).version;
      sharedToolReferences = [target.record_id];
    }
    if (document.toolBackup?.kind === 'index') {
      if (document.toolBackup.snapshotId !== id) throw new ServiceError('INVALID_RECORD');
      toolIndexGeneration = await this.generation(session.ownerId);
      const index = parsedIndex!;
      const refs = index.version === 4 ? toolNodeReferences(index) : toolIndexRecordIDs(document.toolBackup);
      if (index.version === 4) await validateToolNodePaths(index);
      const verifiedPaths = new Set<string>();
      if ((index.version === 3 || (index.version === 4 && index.files)) && index.previousIndexID) {
        const priorRow = await this.row(session.ownerId,index.previousIndexID.toLowerCase());
        if (priorRow && !priorRow.deleted && priorRow.revision === 1) {
          const priorPart = (await this.metadata(priorRow)).document.toolBackup;
          if (priorPart?.kind === 'index' && priorPart.snapshotId === priorRow.record_id) {
            const priorIndex = parseToolNode(priorPart);
            if ((priorIndex.version === 3 || (index.version === 4 && priorIndex.version === 4 && priorIndex.files))
              && await sha256(Uint8Array.from(atob(priorPart.payload), c => c.charCodeAt(0))) === priorPart.sha256) {
              const signature = (file: import('./documents').ToolIndexFile, snapshotID: string) => JSON.stringify([
                file.path,file.bytes,file.sha256,file.records.map(id=>id.toLowerCase()),
                (file.sourceSnapshotID ?? snapshotID).toLowerCase(),
              ]);
              const priorFiles = new Set(priorIndex.files!.map(file=>signature(file,priorIndex.snapshotID)));
              for (const file of index.files!) if (priorFiles.has(signature(file,index.snapshotID))) verifiedPaths.add(file.path);
            }
          }
        }
      }
      if (index.version >= 2) sharedToolReferences = refs;
      // Bound each existence query below D1's parameter limit. Authentication
      // below opens metadata with KMS, but never downloads photo bodies.
      for (let at = 0; at < refs.length; at += 90) {
        const batch = refs.slice(at, at + 90);
        const result = await this.d.db.prepare(`SELECT record_id FROM pa_records WHERE owner_id=? AND deleted=0
          AND revision=1 AND record_id IN (${batch.map(() => '?').join(',')})
          AND NOT EXISTS(SELECT 1 FROM pa_tool_part_delete_claims c WHERE c.owner_id=pa_records.owner_id AND c.part_id=pa_records.record_id)`)
          .bind(session.ownerId, ...batch).all();
        if (result.results.length !== batch.length) throw new ServiceError('REVISION_CONFLICT', 409);
      }
      if (index.version === 4 && index.children) {
        // At most sixteen immediate immutable children. Every descendant was
        // checked when its node committed; references protect the full graph.
        for (const child of index.children) {
          const row = await this.row(session.ownerId, child.snapshotID.toLowerCase());
          if (!row || row.deleted || row.revision !== 1) throw new ServiceError('REVISION_CONFLICT', 409);
          const part = (await this.metadata(row)).document.toolBackup;
          if (!part || part.kind !== 'index' || part.snapshotId !== row.record_id || part.sha256 !== child.sha256
            || await sha256(Uint8Array.from(atob(part.payload), c => c.charCodeAt(0))) !== child.sha256) throw new ServiceError('INVALID_RECORD');
          const node = parseToolNode(part);
          if (node.version !== 4 || node.prefix !== child.prefix) throw new ServiceError('INVALID_RECORD');
          const actual = summarizeToolNode(node);
          if (actual.fileCount !== child.fileCount || actual.nodeCount !== child.nodeCount
            || actual.toolMask !== child.toolMask || actual.manifestMask !== child.manifestMask) throw new ServiceError('INVALID_RECORD');
        }
      }
      // Validate real immutable pieces, never a client-declared hash alone.
      // The final inventory CAS covers mutations while KMS is awaited.
      // A prior authenticated immutable v3 index already verified these exact
      // path/size/hash/source/record tuples. Recheck every live D1 dependency and
      // claim above, but decrypt only new/changed pieces. The final generation
      // CAS fences deletion of either the prior index or any reused piece.
      const files = index.files ?? [];
      const pieces = files.filter(file=>!verifiedPaths.has(file.path))
        .flatMap(file => file.records.map((partID, offset) => ({ file, partID, offset })));
      const chunksByPath = new Map<string, Uint8Array[]>();
      let nextPiece = 0, failed = false;
      const verifyPieces = async () => {
        while (!failed) {
          const task = pieces[nextPiece++];
          if (!task) return;
          const { file, partID, offset } = task;
          try {
          const stored = await this.row(session.ownerId, partID.toLowerCase());
          if (!stored || stored.deleted || stored.revision !== 1) throw new ServiceError('REVISION_CONFLICT', 409);
          const opened = await this.metadata(stored), piece = opened.document.toolBackup;
          const source = (file.sourceSnapshotID ?? index.snapshotID).toLowerCase();
          const photoFile = file.path.endsWith('.jpg');
          if (!piece || piece.snapshotId !== source || piece.path !== file.path
            || piece.kind !== (photoFile ? 'photo' : 'json') || piece.part !== offset
            || piece.count !== file.records.length
            || (photoFile && (opened.photoBytes !== file.bytes || opened.photoSHA256 !== file.sha256
              || piece.sha256 !== file.sha256))) throw new ServiceError('INVALID_RECORD');
          if (!photoFile) {
            const chunks = chunksByPath.get(file.path) ?? [];
            chunks[offset] = Uint8Array.from(atob(piece.payload), c => c.charCodeAt(0));
            chunksByPath.set(file.path, chunks);
          }
          } catch (error) { failed = true; throw error; }
        }
      };
      try {
        // Bound in-flight KMS reads; a 200-piece snapshot must not serialize
        // hundreds of network round trips into the native 60-second request.
        // Retain only JSON chunks (at most 999 * 48 KiB), never photo bytes.
        const checked = await Promise.allSettled(Array.from({ length: Math.min(8, pieces.length) }, verifyPieces));
        const rejected = checked.find(result => result.status === 'rejected');
        if (rejected?.status === 'rejected') throw rejected.reason;
        for (const file of files.filter(file => !file.path.endsWith('.jpg') && !verifiedPaths.has(file.path))) {
          const chunks = chunksByPath.get(file.path);
          if (!chunks || chunks.length !== file.records.length || chunks.some(chunk => !chunk)) throw new ServiceError('INVALID_RECORD');
          if (chunks.reduce((n, chunk) => n + chunk.length, 0) !== file.bytes) throw new ServiceError('INVALID_RECORD');
          const combined = new Uint8Array(file.bytes);
          let offset = 0;
          for (const chunk of chunks) { combined.set(chunk, offset); offset += chunk.length; }
          try { if (await sha256(combined) !== file.sha256) throw new ServiceError('INVALID_RECORD'); }
          finally { combined.fill(0); }
        }
      } finally {
        for (const chunks of chunksByPath.values()) for (const chunk of chunks) chunk?.fill(0);
      }
    }
    const initialFingerprint = trial?.fingerprint ?? await sha256(JSON.stringify({ document, photoSHA256 }));
    if (request.expectedRevision === null && existing) {
      if (existing.initial_fingerprint !== initialFingerprint) throw new ServiceError('REVISION_CONFLICT', 409);
      await this.metadata(existing); // Corrupted data is never returned as a successful retry.
      await this.ensureCurrentRecovery(existing, session);
      await this.unchanged(token, session, existing,authorize);
      await acknowledge(session.ownerId);
      await assertTransferActive();
      return { recordId: id, revision: existing.revision };
    }
    if (request.expectedRevision !== null) {
      const expected = revisionValue(request.expectedRevision);
      if (this.d.recovery && existing && !existing.deleted && existing.revision === expected + 1) {
        const latest = await this.metadata(existing);
        const retryDocument = { ...document, updatedAt: latest.document.updatedAt };
        if (latest.photoSHA256 === photoSHA256
          && JSON.stringify(latest.document) === JSON.stringify(retryDocument)) {
          await this.ensureCurrentRecovery(existing, session);
          await this.unchanged(token, session, existing,authorize);
          await acknowledge(session.ownerId);
          return { recordId: id, revision: existing.revision };
        }
      }
      if (!existing || existing.revision !== expected) throw new ServiceError('REVISION_CONFLICT', 409);
      await this.ensureCurrentRecovery(existing, session);
      const old = await this.metadata(existing);
      if (old.document.toolBackup) throw new ServiceError('REVISION_CONFLICT', 409);
      if (!!parseAppRecordHead(old.document) !== !!appHead) throw new ServiceError('REVISION_CONFLICT', 409);
      const oldHead = parseAppRecordHead(old.document);
      if (oldHead && appHeadVersion !== 4) {
        const oldIndexRow = await this.row(session.ownerId, oldHead.snapshotID.toLowerCase());
        if (!oldIndexRow || oldIndexRow.deleted || oldIndexRow.revision !== 1) throw new ServiceError('REVISION_CONFLICT', 409);
        const oldPart = (await this.metadata(oldIndexRow)).document.toolBackup;
        if (!oldPart || oldPart.kind !== 'index' || oldPart.sha256 !== oldHead.indexHash
          || parseToolNode(oldPart).version === 4) throw new ServiceError('REVISION_CONFLICT', 409);
      }
      if (old.photoSHA256 !== photoSHA256) throw new ServiceError('PHOTO_REPLACEMENT_REQUIRES_NEW_RECORD', 409);
      // Server update time; captured/written dates are not invented or silently replaced.
      document.updatedAt = new Date(this.d.now()).toISOString();
      const metadata = await this.d.keys.seal(new TextEncoder().encode(JSON.stringify({ ...old,
        revision: expected + 1, document } satisfies Metadata)),
      { ownerId: session.ownerId, purpose: 'record', recordId: `${id}/document` });
      if (metadata.length > 512 * 1024) throw new ServiceError('ARCHIVE_TOO_LARGE', 413);
      const encrypted = this.d.recovery ? await this.encryptedPhoto(existing, old) : null;
      if (this.d.recovery && existing.quota_bytes !== bytes(existing.metadata).byteLength + (encrypted?.length ?? 0)) {
        throw new ServiceError('ARCHIVE_ACCOUNTING_UNAVAILABLE', 503);
      }
      const replacement: StoredRecordImage = { ownerId: session.ownerId, recordId: id,
        revision: expected + 1, initialFingerprint: existing.initial_fingerprint,
        initialOperation: existing.initial_operation, metadata,
        photoKey: existing.photo_key, photoBytes: existing.photo_bytes,
        quotaBytes: metadata.length + (encrypted?.length ?? 0), deleted: false,
        photoCiphertext: encrypted };
      const priorPhoto = this.d.recovery && encrypted !== null
        ? await this.d.db.prepare(`SELECT photo_object_key,photo_version_id,photo_sha256,photo_bytes
          FROM pa_record_recovery_versions WHERE owner_id=? AND record_id=? AND revision=?`)
          .bind(session.ownerId, id, expected)
          .first<{ photo_object_key: string | null; photo_version_id: string | null;
            photo_sha256: string | null; photo_bytes: number | null }>() : null;
      if (this.d.recovery && encrypted !== null && (!priorPhoto?.photo_object_key
        || !priorPhoto.photo_version_id || !priorPhoto.photo_sha256
        || !priorPhoto.photo_bytes)) throw new ServiceError('RECOVERY_PENDING', 503);
      const reusedPhoto = priorPhoto?.photo_object_key ? {
        key: priorPhoto.photo_object_key, versionId: priorPhoto.photo_version_id!,
        sha256: priorPhoto.photo_sha256!, bytes: priorPhoto.photo_bytes!,
      } : undefined;
      const copied = this.d.recovery ? await this.d.recovery.copy(replacement, reusedPhoto) : null;
      // Existing edits remain possible without membership; quota overage stops only new records.
      if (copied || appHead) {
        const results = await this.d.db.batch([
          this.d.db.prepare(`UPDATE pa_records SET revision=revision+1,metadata=?,
            quota_bytes=quota_bytes-length(metadata)+? WHERE owner_id=? AND record_id=? AND revision=? AND deleted=0
            AND ${activeSession} AND (? IS NULL OR (SELECT generation FROM pa_inventory WHERE owner_id=?)=?)
            AND NOT EXISTS(SELECT 1 FROM pa_tool_snapshot_abandonments WHERE owner_id=? AND snapshot_id=?)
            RETURNING revision`).bind(bytes(metadata), metadata.length, session.ownerId, id,
              expected, ...sessionBindings(session), toolIndexGeneration, session.ownerId, toolIndexGeneration,
              session.ownerId,appHead?.snapshotID.toLowerCase() ?? ''),
          ...(copied ? [this.recoveryReference(session.ownerId, id, expected + 1, copied)] : []),
          ...(appHead ? [
            this.d.db.prepare(`DELETE FROM pa_tool_snapshot_references WHERE owner_id=? AND snapshot_id=?
              AND EXISTS(SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=? AND revision=? AND metadata=?)`)
              .bind(session.ownerId, id, session.ownerId, id, expected + 1, bytes(metadata)),
            this.d.db.prepare(`INSERT INTO pa_tool_snapshot_references(owner_id,snapshot_id,part_id,source_revision)
              SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=? AND revision=? AND metadata=?)`)
              .bind(session.ownerId, id, appHead.snapshotID.toLowerCase(), expected + 1,
                session.ownerId, id, expected + 1, bytes(metadata)),
          ] : []),
        ]);
        if (results[0]?.results.length !== 1 || (copied && results[1]?.results.length !== 1)) {
          await authorize();
          throw new ServiceError('REVISION_CONFLICT', 409);
        }
        if (copied) await this.verifiedRecoveryReference(session.ownerId, id, expected + 1);
        await acknowledge(session.ownerId);
        return { recordId: id, revision: expected + 1 };
      }
      const updated = await this.d.db.prepare(`UPDATE pa_records SET revision=revision+1,metadata=?,
        quota_bytes=quota_bytes-length(metadata)+? WHERE owner_id=? AND record_id=? AND revision=? AND deleted=0
        AND ${activeSession} RETURNING revision`).bind(bytes(metadata), metadata.length, session.ownerId, id, expected,
        ...sessionBindings(session)).first<{ revision: number }>();
      if (!updated) { await authorize(); throw new ServiceError('REVISION_CONFLICT', 409); }
      await acknowledge(session.ownerId);
      return { recordId: id, revision: updated.revision };
    }
    if (request.consentVersion !== 'managed-preservation-v1') throw new ServiceError('PRESERVATION_CONSENT_REQUIRED', 403);
    // A missing operator limit must stop only new intake. Reads, exports,
    // edits, removals and backup repair remain available to existing owners.
    if (this.d.requireGlobalAdmissionLimit && this.d.globalActiveBytesLimit === undefined) {
      throw new ServiceError('PRESERVATION_NOT_CONFIGURED', 503);
    }
    if (!pilotAccess) await this.paid(session.ownerId);
    if (photo !== null && !await this.d.photos.validateJPEG(photo)) throw new ServiceError('INVALID_JPEG');
    const operation = crypto.randomUUID();
    const key = `personal/${session.ownerId}/${id}/${operation}`;
    const sealedPhoto = photo === null ? null : await this.d.keys.seal(photo,
      { ownerId: session.ownerId, purpose: 'record', recordId: `${id}/photo` });
    const metadata = await this.d.keys.seal(new TextEncoder().encode(JSON.stringify({ version: 1, ownerId: session.ownerId,
      recordId: id, revision: 1, document, photoSHA256, photoBytes: photo?.length ?? 0 } satisfies Metadata)),
    { ownerId: session.ownerId, purpose: 'record', recordId: `${id}/document` });
    if (metadata.length > 512 * 1024 || (sealedPhoto?.length ?? 0) > 30 * 1024 * 1024) throw new ServiceError('ARCHIVE_TOO_LARGE', 413);
    const size = metadata.length + (sealedPhoto?.length ?? 0);
    await this.d.db.prepare('INSERT OR IGNORE INTO pa_inventory(owner_id) VALUES(?)').bind(session.ownerId).run();
    const reservationFence = trial ? this.d.toolTrial!.fence(trial)
      : pilotAccess ? this.d.pilotStorageAccess!.fence(session.ownerId) : { sql: '1', bindings: [] };
    const reserved = await this.d.db.prepare(`INSERT INTO pa_uploads(operation_id,owner_id,record_id,object_key,reserved_bytes,expires_at)
      SELECT ?,?,?,?,?,? FROM pa_inventory WHERE owner_id=? AND used_bytes+reserved_bytes+?<=?
      AND used_bytes=(SELECT record_bytes FROM pa_owner_record_counters WHERE owner_id=pa_inventory.owner_id AND accounting_valid=1)
      AND (? IS NULL OR ((SELECT coalesce(sum(record_bytes),0) FROM pa_owner_record_counters)
        +(SELECT coalesce(sum(reserved_bytes),0) FROM pa_uploads))<=?-?
        AND (SELECT coalesce(sum(record_bytes),0) FROM pa_owner_record_counters)=(SELECT coalesce(sum(used_bytes),0) FROM pa_inventory)
        AND NOT EXISTS(SELECT 1 FROM pa_owners o LEFT JOIN pa_owner_record_counters d ON d.owner_id=o.owner_id WHERE d.owner_id IS NULL OR d.accounting_valid<>1))
      AND ((SELECT live_count FROM pa_owner_record_counters WHERE owner_id=?)
        +(SELECT count(*) FROM pa_uploads WHERE owner_id=?))< ? AND ${activeSession} AND ${reservationFence.sql}
      RETURNING operation_id`).bind(operation, session.ownerId, id, key, size, this.d.now() + 600_000,
      session.ownerId, size, this.d.quotaBytes,
      this.d.globalActiveBytesLimit ?? null, this.d.globalActiveBytesLimit ?? null, size,
      session.ownerId, session.ownerId, this.d.maximumRecords, ...sessionBindings(session), ...reservationFence.bindings)
      .first<{ operation_id: string }>();
    if (!reserved) { await authorize(); throw new ServiceError('ARCHIVE_CAPACITY_REACHED', 409); }
    try {
      if (sealedPhoto !== null) {
        const write = () => this.d.bucket.put(key, sealedPhoto, { httpMetadata: { contentType: 'application/octet-stream' } });
        const stored = this.d.ownerWriteLease
          ? await this.d.ownerWriteLease.withOwnerWrite(session.ownerId, write) : await write();
        if (!stored) throw new ServiceError('ARCHIVE_STORAGE_UNAVAILABLE', 503);
        if (this.d.recovery) {
          const confirmed = await this.d.bucket.get(key);
          if (!confirmed || confirmed.size !== sealedPhoto.length || confirmed.size > 30 * 1024 * 1024) {
            throw new ServiceError('ARCHIVE_STORAGE_UNAVAILABLE', 503);
          }
          const confirmedBytes = new Uint8Array(await confirmed.arrayBuffer());
          try {
            if (await sha256(confirmedBytes) !== await sha256(sealedPhoto)) {
              throw new ServiceError('ARCHIVE_STORAGE_UNAVAILABLE', 503);
            }
          } finally {
            // R2 returned a dedicated readback buffer. Recovery uses sealedPhoto,
            // so this verification copy can be released after both hashes finish.
            (confirmedBytes.buffer as ArrayBuffer).transfer(0);
          }
        }
      }
      const copied = this.d.recovery ? await this.d.recovery.copy({ ownerId: session.ownerId,
        recordId: id, revision: 1, initialFingerprint, initialOperation: operation,
        metadata, photoKey: sealedPhoto === null ? null : key, photoBytes: photo?.length ?? 0,
        quotaBytes: size, deleted: false, photoCiphertext: sealedPhoto }) : null;
      if (!pilotAccess) await this.paid(session.ownerId);
      const commitFence = trial ? this.d.toolTrial!.fence(trial)
        : pilotAccess ? this.d.pilotStorageAccess!.fence(session.ownerId) : { sql: '1', bindings: [] };
      // Commit reference and consume its reservation in one D1 transaction.
      const result = await this.d.db.batch([
        this.d.db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,
          metadata,photo_key,photo_bytes,quota_bytes)
          SELECT ?,?,1,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pa_uploads WHERE operation_id=? AND state='active' AND expires_at>?)
          AND ${activeSession} AND ${commitFence.sql} AND NOT EXISTS(SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?)
          AND (? IS NULL OR (SELECT generation FROM pa_inventory WHERE owner_id=?)=?)
          AND NOT EXISTS(SELECT 1 FROM pa_tool_snapshot_abandonments WHERE owner_id=? AND snapshot_id IN (?,?)) RETURNING revision`)
          .bind(session.ownerId, id, initialFingerprint, operation, bytes(metadata), photo === null ? null : key, photo?.length ?? 0,
            size, operation, this.d.now(), ...sessionBindings(session), ...commitFence.bindings, session.ownerId, id,
            toolIndexGeneration, session.ownerId, toolIndexGeneration, session.ownerId,
            document.toolBackup?.snapshotId ?? appHead?.snapshotID.toLowerCase() ?? '',
            uploadSnapshotID ?? document.toolBackup?.snapshotId ?? ''),
        this.d.db.prepare(`DELETE FROM pa_uploads WHERE operation_id=? AND EXISTS
          (SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=? AND initial_operation=?)`)
          .bind(operation, session.ownerId, id, operation),
        ...(copied ? [this.recoveryReference(session.ownerId, id, 1, copied)] : []),
        ...(trial ? this.d.toolTrial!.committed(trial, operation) : []),
        ...Array.from({ length: Math.ceil(sharedToolReferences.length / 30) }, (_, batch) => {
          const ids = sharedToolReferences.slice(batch * 30, batch * 30 + 30);
          return this.d.db.prepare(`INSERT INTO pa_tool_snapshot_references(owner_id,snapshot_id,part_id)
            SELECT ?,?,column1 FROM (VALUES ${ids.map(() => '(?)').join(',')})
            WHERE EXISTS(SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=? AND initial_operation=? AND deleted=0)`)
            .bind(session.ownerId, id, ...ids, session.ownerId, id, operation);
        }),
        ...(document.toolBackup ? [this.d.db.prepare(`INSERT INTO pa_tool_record_sources(owner_id,record_id,snapshot_id,kind,upload_snapshot_id)
          SELECT owner_id,record_id,?,?,? FROM pa_records WHERE owner_id=? AND record_id=? AND initial_operation=? AND deleted=0`)
          .bind(document.toolBackup.snapshotId, document.toolBackup.kind, uploadSnapshotID, session.ownerId, id, operation)] : []),
      ]);
      if (result[0]?.results.length !== 1 || (copied && result[2]?.results.length !== 1)) {
        await authorize();
        throw new ServiceError('REVISION_CONFLICT', 409);
      }
      await this.verifiedRecoveryReference(session.ownerId, id, 1);
      await acknowledge(session.ownerId);
      await assertTransferActive();
      return { recordId: id, revision: 1 };
    } catch (error) {
      // Never remove an object that was successfully committed even if its reply was lost.
      await this.abandon(operation);
      const committed = await this.row(session.ownerId, id);
      if (committed && !committed.deleted && committed.initial_fingerprint === initialFingerprint) {
        await this.ensureCurrentRecovery(committed, session);
        await this.unchanged(token, session, committed,authorize);
        await acknowledge(session.ownerId);
        await assertTransferActive();
        return { recordId: id, revision: committed.revision };
      }
      throw error;
    }
  }
  private async abandon(operation: string) {
    return abandonUpload(this.d, operation);
  }
  async remove(token: string, id: string, expected: number, requireUnreferenced = false) {
    recordId(id); revisionValue(expected);
    const session = await this.d.auth.requireSession(token);
    this.requireRecovery();
    await this.requireWritePolicy();
    const row = await this.row(session.ownerId, id);
    if (!row) throw new ServiceError('RECORD_NOT_FOUND', 404);
    if (row.deleted && row.revision === expected + 1) {
      // Finish this exact committed deletion before the owner snapshot, whose
      // coverage deliberately refuses a missing record commit marker.
      await this.ensureCurrentRecovery(row, session);
      await this.acknowledgeOwnerInventory(session.ownerId);
      return { recordId: id, revision: row.revision };
    }
    if (row.deleted || row.revision !== expected) throw new ServiceError('REVISION_CONFLICT', 409);
    if (this.d.requireOwnerRecovery) {
      await this.d.ownerRecovery!.copyCurrent(this.d.db, session.ownerId, this.d.now());
    }
    const currentDocument = (await this.metadata(row)).document;
    if (parseAppRecordHead(currentDocument)) throw new ServiceError('TOOL_PART_REFERENCED', 409);
    const tool = currentDocument.toolBackup;
    const node = tool?.kind === 'index' ? parseToolNode(tool) : null;
    const childNodes = node?.version === 4 && node.children ? toolNodeReferences(node) : [];
    if (requireUnreferenced && (!tool || tool.kind === 'index')) throw new ServiceError('INVALID_RECORD');
    if (tool) {
      // Claim before creating the external delete intent. New indexes cannot
      // bind this piece during the S3/D1 gap, including after an uncertain retry.
      await this.d.db.prepare(`INSERT OR IGNORE INTO pa_tool_part_delete_claims(owner_id,part_id)
        SELECT ?,? WHERE ${activeSession}
        AND NOT EXISTS(SELECT 1 FROM pa_tool_snapshot_references WHERE owner_id=? AND part_id=?)
        AND (?=0 OR NOT EXISTS(SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=? AND deleted=0))`)
        .bind(session.ownerId, id, ...this.sessionBindings(session), session.ownerId, id,
          requireUnreferenced ? 1 : 0, session.ownerId, tool.snapshotId).run();
      const locked = await this.d.db.prepare(`SELECT 1 FROM pa_tool_part_delete_claims WHERE owner_id=? AND part_id=?`)
        .bind(session.ownerId, id).first();
      if (!locked) { await this.d.auth.requireSession(token); throw new ServiceError('TOOL_PART_REFERENCED', 409); }
      // A prior legacy deletion claim is not permission for a strict caller to
      // remove a piece while its original index is still alive.
      if (requireUnreferenced && await this.d.db.prepare(`SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=? AND deleted=0`)
        .bind(session.ownerId, tool.snapshotId).first()) throw new ServiceError('TOOL_PART_REFERENCED', 409);
    }
    await this.ensureCurrentRecovery(row, session);
    const copied = this.d.recovery ? await this.d.recovery.copy({ ownerId: session.ownerId,
      recordId: id, revision: expected + 1, initialFingerprint: row.initial_fingerprint,
      initialOperation: row.initial_operation, metadata: null, photoKey: null,
      photoBytes: 0, quotaBytes: 0, deleted: true, photoCiphertext: null }) : null;
    // The owner-bound S3 intent must be durable before D1 can hide the record.
    // Without a post-CAS marker, restore quarantines the older live photo.
    const intent = copied ? await this.d.recovery!.prepareDelete(session.ownerId, id, expected, copied) : null;
    const result = await this.d.db.batch([
      ...(intent ? [this.d.db.prepare(`INSERT OR IGNORE INTO pa_record_delete_intents(owner_id,record_id,
        target_revision,record_object_key,intent_object_key,intent_version_id,intent_sha256,
        intent_bytes,created_at)
        SELECT ?,?,?,?,?,?,?,?,? FROM pa_records WHERE owner_id=? AND record_id=?
        AND revision=? AND deleted=0 AND ${activeSession}`)
        .bind(session.ownerId, id, expected + 1, copied!.record.key, intent.key,
          intent.versionId, intent.sha256, intent.bytes, this.d.now(), session.ownerId, id,
          expected, ...this.sessionBindings(session))] : []),
      this.d.db.prepare(`INSERT OR IGNORE INTO pa_pending_deletes(object_key,created_at)
        SELECT photo_key,? FROM pa_records WHERE owner_id=? AND record_id=? AND revision=? AND deleted=0
        AND photo_key IS NOT NULL AND ${activeSession}`).bind(this.d.now(), session.ownerId, id, expected, ...this.sessionBindings(session)),
      this.d.db.prepare(`UPDATE pa_records SET revision=revision+1,deleted=1,metadata=NULL,photo_key=NULL,photo_bytes=0,quota_bytes=0
        WHERE owner_id=? AND record_id=? AND revision=? AND deleted=0 AND ${activeSession} RETURNING revision`)
        .bind(session.ownerId, id, expected, ...this.sessionBindings(session)),
      ...(copied ? [this.recoveryReference(session.ownerId, id, expected + 1, copied)] : []),
      // Existing SQL triggers claim ordinary leaf pieces. Radix children are
      // indexes themselves, so retire their last parent edge in this same D1
      // transaction. A shared child with another live parent is preserved.
      ...(childNodes.length ? [this.d.db.prepare(`INSERT OR IGNORE INTO pa_tool_part_delete_claims(owner_id,part_id)
        SELECT owner_id,record_id FROM pa_records WHERE owner_id=? AND deleted=0 AND revision=1
        AND record_id IN (${childNodes.map(() => '?').join(',')})
        AND EXISTS(SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=? AND deleted=1 AND revision=?)
        AND NOT EXISTS(SELECT 1 FROM pa_tool_snapshot_references f WHERE f.owner_id=pa_records.owner_id AND f.part_id=pa_records.record_id)`)
        .bind(session.ownerId, ...childNodes, session.ownerId, id, expected + 1)] : []),
    ]);
    const updateIndex = intent ? 2 : 1;
    if (result[updateIndex]?.results.length !== 1
      || (copied && result[updateIndex + 1]?.results.length !== 1)) {
      await this.d.auth.requireSession(token); throw new ServiceError('REVISION_CONFLICT', 409);
    }
    await this.verifiedRecoveryReference(session.ownerId, id, expected + 1);
    await this.acknowledgeOwnerInventory(session.ownerId);
    return { recordId: id, revision: expected + 1 };
  }
  async abandonToolSnapshot(token: string, snapshotID: string) {
    recordId(snapshotID);
    const session = await this.d.auth.requireSession(token);
    this.requireRecovery();
    await this.requireWritePolicy();
    await this.acknowledgeOwnerInventory(session.ownerId);
    const generation = await this.generation(session.ownerId);
    // A concurrently published head wins. No snapshot may be cancelled after
    // it becomes the accepted dataset; all later part commits check this fence.
    const result = await this.d.db.batch([
      this.d.db.prepare(`INSERT OR IGNORE INTO pa_tool_snapshot_abandonments(owner_id,snapshot_id,abandoned_at)
        SELECT ?,?,? WHERE ${activeSession}
        AND (SELECT generation FROM pa_inventory WHERE owner_id=?)=?
        AND NOT EXISTS(SELECT 1 FROM pa_tool_snapshot_references WHERE owner_id=? AND part_id=?)`)
        .bind(session.ownerId, snapshotID, this.d.now(), ...this.sessionBindings(session), session.ownerId, generation, session.ownerId, snapshotID),
      // Both indexed source sets stay in D1. No owner-sized JS array, IN list
      // or one-statement-per-part batch, including before the root is uploaded.
      this.d.db.prepare(`INSERT OR IGNORE INTO pa_tool_part_delete_claims(owner_id,part_id)
        SELECT r.owner_id,r.record_id FROM pa_records r JOIN (
          SELECT record_id FROM pa_tool_record_sources WHERE owner_id=? AND snapshot_id=?
          UNION SELECT record_id FROM pa_tool_record_sources WHERE owner_id=? AND upload_snapshot_id=?
        ) source ON source.record_id=r.record_id
        WHERE r.owner_id=? AND r.deleted=0 AND r.revision=1 AND ${activeSession}
          AND EXISTS(SELECT 1 FROM pa_tool_snapshot_abandonments WHERE owner_id=? AND snapshot_id=?)
          AND NOT EXISTS(SELECT 1 FROM pa_tool_snapshot_references f WHERE f.owner_id=r.owner_id AND f.part_id=r.record_id)`)
        .bind(session.ownerId,snapshotID,session.ownerId,snapshotID,session.ownerId,
          ...this.sessionBindings(session),session.ownerId,snapshotID),
    ]);
    if (!result[0]?.meta.changes && !await this.d.db.prepare(`SELECT 1 FROM pa_tool_snapshot_abandonments
      WHERE owner_id=? AND snapshot_id=?`).bind(session.ownerId, snapshotID).first()) throw new ServiceError('REVISION_CONFLICT', 409);
    await this.acknowledgeOwnerInventory(session.ownerId);
    return { snapshotId: snapshotID };
  }
  async toolCleanupCandidates(token: string, after = '') {
    if (after) recordId(after);
    const session = await this.d.auth.requireSession(token);
    const rows = (await this.d.db.prepare(`SELECT r.* FROM pa_tool_part_delete_claims c JOIN pa_records r
      ON r.owner_id=c.owner_id AND r.record_id=c.part_id WHERE c.owner_id=? AND r.deleted=0 AND r.revision=1
      AND NOT EXISTS(SELECT 1 FROM pa_tool_snapshot_references f WHERE f.owner_id=c.owner_id AND f.part_id=c.part_id)
      AND c.part_id>? ORDER BY c.part_id LIMIT 201`).bind(session.ownerId, after).all<Row>()).results;
    const items: { recordId: string; kind: string }[] = [];
    for (let offset = 0; offset < Math.min(rows.length,200); offset += 8) {
      const found = await Promise.all(rows.slice(offset,Math.min(offset+8,200)).map(async row => {
        const part = (await this.metadata(row)).document.toolBackup;
        if (!part) return null;
        if (part.kind === 'index') { if (parseToolNode(part).version < 3) return null; }
        else if (await this.d.db.prepare(`SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=? AND deleted=0`)
          .bind(session.ownerId, part.snapshotId).first()) return null;
        return { recordId: row.record_id, kind: part.kind };
      }));
      for (const item of found) if (item) items.push(item);
    }
    const nextCursor = items.length > 50 ? items[49]!.recordId : rows.length > 200 ? rows[199]!.record_id : null;
    return { items: items.slice(0, 50), hasMore: nextCursor !== null, nextCursor };
  }
  async cleanup(limit = 20) { return cleanupArchive(this.d, limit); }
}

type CleanupDependencies = Pick<Dependencies, 'db' | 'bucket' | 'now'>;
async function abandonUpload(d: CleanupDependencies, operation: string) {
    const claimed = await d.db.prepare(`UPDATE pa_uploads SET state='cleaning' WHERE operation_id=?
      AND NOT EXISTS(SELECT 1 FROM pa_records WHERE initial_operation=? AND deleted=0) RETURNING object_key`)
      .bind(operation, operation).first<{ object_key: string }>();
    if (!claimed) return;
    // Keep the object name for repeated cleanup after interrupted/late writes.
    await d.db.batch([
      d.db.prepare('INSERT OR IGNORE INTO pa_pending_deletes(object_key,created_at) VALUES(?,?)')
        .bind(claimed.object_key, d.now()),
      d.db.prepare("DELETE FROM pa_uploads WHERE operation_id=? AND state='cleaning'").bind(operation),
    ]);
    try { await d.bucket.delete(claimed.object_key); } catch { /* durable deletion queue retries */ }
  }
// Maintenance intentionally does not depend on Apple, membership or decryption keys.
export async function cleanupArchive(d: CleanupDependencies, limit = 20) {
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new ServiceError('INVALID_CLEANUP_LIMIT');
    const expired = await d.db.prepare('SELECT operation_id FROM pa_uploads WHERE expires_at<=? ORDER BY expires_at LIMIT ?')
      .bind(d.now(), limit).all<{ operation_id: string }>();
    for (const item of expired.results) await abandonUpload(d, item.operation_id);
    const pending = await d.db.prepare(`SELECT object_key,created_at FROM pa_pending_deletes
      WHERE next_attempt_at<=? ORDER BY next_attempt_at,created_at,object_key LIMIT ?`)
      .bind(d.now(), limit).all<{ object_key: string; created_at: number }>();
    let failures = 0;
    for (const item of pending.results) {
      // Requeue before external I/O so a failed item cannot starve the following ones.
      await d.db.prepare('UPDATE pa_pending_deletes SET next_attempt_at=? WHERE object_key=?')
        .bind(d.now() + 3_600_000, item.object_key).run();
      try {
      const live = await d.db.prepare('SELECT 1 AS found FROM pa_records WHERE photo_key=? AND deleted=0')
        .bind(item.object_key).first();
      if (live) throw new ServiceError('CLEANUP_REFERENCE_CONFLICT', 503);
      await d.bucket.delete(item.object_key);
      // Seven days' repeated deletion protects bounded delayed writes. Final
      // orphan reconciliation/backup purge must be verified before activation.
      if (item.created_at < d.now() - 7 * 86_400_000) {
        await d.db.prepare('DELETE FROM pa_pending_deletes WHERE object_key=? AND created_at=?')
          .bind(item.object_key, item.created_at).run();
      }
      } catch { failures++; }
    }
    if (failures) throw new ServiceError('CLEANUP_INCOMPLETE', 503);
}
