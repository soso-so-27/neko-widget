import { ServiceError, sha256, type ArchiveDocument, type KeyCustody, type MembershipAuthority,
  type PhotoValidator, type Session } from './contracts';
import { decodePhoto, encodePhoto, recordId, validateDocument } from './documents';

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
  record_bytes: number; upload_bytes: number;
}
interface Dependencies {
  db: D1Database; bucket: R2Bucket; keys: KeyCustody; membership: MembershipAuthority; photos: PhotoValidator;
  auth: { requireSession(token: string): Promise<Session> }; now: () => number; quotaBytes: number; maximumRecords: number;
}
const bytes = (value: unknown): ArrayBuffer => {
  if (value instanceof ArrayBuffer) return value;
  if (value instanceof Uint8Array || Array.isArray(value)) return new Uint8Array(value).buffer;
  throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
};
const activeSession = `EXISTS(SELECT 1 FROM pa_sessions s JOIN pa_owners o ON o.owner_id=s.owner_id
  WHERE s.session_hash=? AND s.owner_id=? AND s.expires_at>? AND o.disabled=0 AND s.owner_epoch=o.epoch)`;
const revisionValue = (value: unknown): number => {
  if (!Number.isSafeInteger(value) || (value as number) < 1) throw new ServiceError('INVALID_REVISION');
  return value as number;
};

export class ArchiveStore {
  constructor(private readonly d: Dependencies) {
    if (!Number.isSafeInteger(d.quotaBytes) || d.quotaBytes < 1 || !Number.isSafeInteger(d.maximumRecords)
      || d.maximumRecords < 1) throw new ServiceError('PRESERVATION_NOT_CONFIGURED', 503);
  }
  private sessionBindings(session: Session): [string, string, number] {
    return [session.sessionHash, session.ownerId, this.d.now()];
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
  private async unchanged(token: string, session: Session, row: Row) {
    const current = await this.d.auth.requireSession(token);
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
      (SELECT count(*) FROM pa_records r WHERE r.owner_id=o.owner_id AND r.deleted=0) AS saved_records,
      (SELECT count(*) FROM pa_records r WHERE r.owner_id=o.owner_id) AS record_identifiers,
      (SELECT count(*) FROM pa_uploads u WHERE u.owner_id=o.owner_id) AS pending_records,
      (SELECT coalesce(sum(quota_bytes),0) FROM pa_records r WHERE r.owner_id=o.owner_id) AS record_bytes,
      (SELECT coalesce(sum(reserved_bytes),0) FROM pa_uploads u WHERE u.owner_id=o.owner_id) AS upload_bytes
      FROM pa_owners o LEFT JOIN pa_inventory i ON i.owner_id=o.owner_id
      WHERE o.owner_id=? AND ${activeSession}`)
      .bind(session.ownerId, ...this.sessionBindings(session)).first<UsageRow>();
    const current = await this.d.auth.requireSession(token);
    if (!row || current.ownerId !== session.ownerId || current.sessionHash !== session.sessionHash) {
      throw new ServiceError('SESSION_INVALID', 401);
    }
    const counters = [row.used_bytes, row.reserved_bytes, row.saved_records, row.record_identifiers,
      row.pending_records, row.record_bytes, row.upload_bytes];
    if (counters.some(value => !Number.isSafeInteger(value) || value < 0)
      || !Number.isSafeInteger(row.used_bytes + row.reserved_bytes)
      || !Number.isSafeInteger(row.record_identifiers + row.pending_records)
      || row.used_bytes !== row.record_bytes || row.reserved_bytes !== row.upload_bytes
      || (!row.inventory_owner && counters.some(value => value !== 0))) {
      // Missing/corrupt accounting is not an empty archive. Never repair it by
      // dropping records or by reporting fabricated free capacity.
      throw new ServiceError('ARCHIVE_ACCOUNTING_UNAVAILABLE', 503);
    }
    const allocated = row.used_bytes + row.reserved_bytes;
    return { version: 1, accounting: 'encrypted-records-v1',
      storage: { usedBytes: row.used_bytes, reservedBytes: row.reserved_bytes, limitBytes: this.d.quotaBytes,
        availableBytes: Math.max(0, this.d.quotaBytes - allocated), overLimit: allocated > this.d.quotaBytes },
      records: { saved: row.saved_records, pending: row.pending_records,
        // Keep tombstones for replay protection, but do not let lifetime deletions
        // exhaust the number of records a customer may currently keep.
        creationLimitReached: row.saved_records + row.pending_records >= this.d.maximumRecords } };
  }
  async list(token: string, after = '', limit = 20) {
    if (after) recordId(after);
    if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw new ServiceError('INVALID_PAGE_SIZE');
    const session = await this.d.auth.requireSession(token);
    const generation = await this.generation(session.ownerId);
    const rows = await this.d.db.prepare(`SELECT * FROM pa_records WHERE owner_id=? AND deleted=0 AND record_id>?
      ORDER BY record_id LIMIT ?`).bind(session.ownerId, after, limit + 1).all<Row>();
    const items = [];
    for (const row of rows.results.slice(0, limit)) items.push({ recordId: row.record_id, revision: row.revision,
      document: (await this.metadata(row)).document });
    await this.d.auth.requireSession(token);
    if (await this.generation(session.ownerId) !== generation) throw new ServiceError('ARCHIVE_CHANGED', 409);
    return { items, generation, nextCursor: rows.results.length > limit ? items.at(-1)!.recordId : null };
  }
  async read(token: string, id: string) {
    recordId(id);
    const session = await this.d.auth.requireSession(token);
    const row = await this.row(session.ownerId, id);
    if (!row || row.deleted) throw new ServiceError('RECORD_NOT_FOUND', 404);
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
    return { recordId: id, revision: row.revision, document: data.document, photoBase64: encodePhoto(photo),
      photoSHA256: data.photoSHA256 };
  }
  async put(token: string, id: string, input: unknown) {
    recordId(id);
    const session = await this.d.auth.requireSession(token);
    if (!input || typeof input !== 'object') throw new ServiceError('INVALID_RECORD');
    const request = input as Record<string, unknown>;
    if (Object.keys(request).some((key) => !['document', 'photoBase64', 'expectedRevision', 'consentVersion'].includes(key))) {
      throw new ServiceError('INVALID_RECORD');
    }
    const document = validateDocument(request.document);
    const photo = decodePhoto(request.photoBase64);
    if ((photo === null) !== (document.photoFile === null)) throw new ServiceError('INVALID_RECORD');
    const photoSHA256 = photo === null ? null : await sha256(photo);
    const initialFingerprint = await sha256(JSON.stringify({ document, photoSHA256 }));
    const existing = await this.row(session.ownerId, id);
    if (existing?.deleted) throw new ServiceError('RECORD_DELETED', 409);
    if (request.expectedRevision === null && existing) {
      if (existing.initial_fingerprint !== initialFingerprint) throw new ServiceError('REVISION_CONFLICT', 409);
      await this.metadata(existing); // Corrupted data is never returned as a successful retry.
      await this.unchanged(token, session, existing);
      return { recordId: id, revision: existing.revision };
    }
    if (request.expectedRevision !== null) {
      const expected = revisionValue(request.expectedRevision);
      if (!existing || existing.revision !== expected) throw new ServiceError('REVISION_CONFLICT', 409);
      const old = await this.metadata(existing);
      if (old.photoSHA256 !== photoSHA256) throw new ServiceError('PHOTO_REPLACEMENT_REQUIRES_NEW_RECORD', 409);
      // Server update time; captured/written dates are not invented or silently replaced.
      document.updatedAt = new Date(this.d.now()).toISOString();
      const metadata = await this.d.keys.seal(new TextEncoder().encode(JSON.stringify({ ...old,
        revision: expected + 1, document } satisfies Metadata)),
      { ownerId: session.ownerId, purpose: 'record', recordId: `${id}/document` });
      if (metadata.length > 512 * 1024) throw new ServiceError('ARCHIVE_TOO_LARGE', 413);
      // Existing edits remain possible without membership; quota overage stops only new records.
      const updated = await this.d.db.prepare(`UPDATE pa_records SET revision=revision+1,metadata=?,
        quota_bytes=quota_bytes-length(metadata)+? WHERE owner_id=? AND record_id=? AND revision=? AND deleted=0
        AND ${activeSession} RETURNING revision`).bind(bytes(metadata), metadata.length, session.ownerId, id, expected,
        ...this.sessionBindings(session)).first<{ revision: number }>();
      if (!updated) { await this.d.auth.requireSession(token); throw new ServiceError('REVISION_CONFLICT', 409); }
      return { recordId: id, revision: updated.revision };
    }
    if (request.consentVersion !== 'managed-preservation-v1') throw new ServiceError('PRESERVATION_CONSENT_REQUIRED', 403);
    await this.paid(session.ownerId);
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
    const reserved = await this.d.db.prepare(`INSERT INTO pa_uploads(operation_id,owner_id,record_id,object_key,reserved_bytes,expires_at)
      SELECT ?,?,?,?,?,? FROM pa_inventory WHERE owner_id=? AND used_bytes+reserved_bytes+?<=?
      AND ((SELECT count(*) FROM pa_records WHERE owner_id=? AND deleted=0)
        +(SELECT count(*) FROM pa_uploads WHERE owner_id=?))< ? AND ${activeSession}
      RETURNING operation_id`).bind(operation, session.ownerId, id, key, size, this.d.now() + 600_000,
      session.ownerId, size, this.d.quotaBytes, session.ownerId, session.ownerId, this.d.maximumRecords, ...this.sessionBindings(session))
      .first<{ operation_id: string }>();
    if (!reserved) { await this.d.auth.requireSession(token); throw new ServiceError('ARCHIVE_CAPACITY_REACHED', 409); }
    try {
      if (sealedPhoto !== null) {
        const stored = await this.d.bucket.put(key, bytes(sealedPhoto), { httpMetadata: { contentType: 'application/octet-stream' } });
        if (!stored) throw new ServiceError('ARCHIVE_STORAGE_UNAVAILABLE', 503);
      }
      await this.paid(session.ownerId);
      // Commit reference and consume its reservation in one D1 transaction.
      const result = await this.d.db.batch([
        this.d.db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,
          metadata,photo_key,photo_bytes,quota_bytes)
          SELECT ?,?,1,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pa_uploads WHERE operation_id=? AND state='active' AND expires_at>?)
          AND ${activeSession} AND NOT EXISTS(SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?) RETURNING revision`)
          .bind(session.ownerId, id, initialFingerprint, operation, bytes(metadata), photo === null ? null : key, photo?.length ?? 0,
            size, operation, this.d.now(), ...this.sessionBindings(session), session.ownerId, id),
        this.d.db.prepare(`DELETE FROM pa_uploads WHERE operation_id=? AND EXISTS
          (SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=? AND initial_operation=?)`)
          .bind(operation, session.ownerId, id, operation),
      ]);
      if (result[0]?.results.length !== 1) {
        await this.d.auth.requireSession(token);
        throw new ServiceError('REVISION_CONFLICT', 409);
      }
      return { recordId: id, revision: 1 };
    } catch (error) {
      // Never remove an object that was successfully committed even if its reply was lost.
      await this.abandon(operation);
      const committed = await this.row(session.ownerId, id);
      if (committed && !committed.deleted && committed.initial_fingerprint === initialFingerprint) {
        await this.unchanged(token, session, committed);
        return { recordId: id, revision: committed.revision };
      }
      throw error;
    }
  }
  private async abandon(operation: string) {
    return abandonUpload(this.d, operation);
  }
  async remove(token: string, id: string, expected: number) {
    recordId(id); revisionValue(expected);
    const session = await this.d.auth.requireSession(token);
    const row = await this.row(session.ownerId, id);
    if (!row) throw new ServiceError('RECORD_NOT_FOUND', 404);
    if (row.deleted && row.revision === expected + 1) return { recordId: id, revision: row.revision };
    if (row.deleted || row.revision !== expected) throw new ServiceError('REVISION_CONFLICT', 409);
    const result = await this.d.db.batch([
      this.d.db.prepare(`INSERT OR IGNORE INTO pa_pending_deletes(object_key,created_at)
        SELECT photo_key,? FROM pa_records WHERE owner_id=? AND record_id=? AND revision=? AND deleted=0
        AND photo_key IS NOT NULL AND ${activeSession}`).bind(this.d.now(), session.ownerId, id, expected, ...this.sessionBindings(session)),
      this.d.db.prepare(`UPDATE pa_records SET revision=revision+1,deleted=1,metadata=NULL,photo_key=NULL,photo_bytes=0,quota_bytes=0
        WHERE owner_id=? AND record_id=? AND revision=? AND deleted=0 AND ${activeSession} RETURNING revision`)
        .bind(session.ownerId, id, expected, ...this.sessionBindings(session)),
    ]);
    if (result[1]?.results.length !== 1) { await this.d.auth.requireSession(token); throw new ServiceError('REVISION_CONFLICT', 409); }
    return { recordId: id, revision: expected + 1 };
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
