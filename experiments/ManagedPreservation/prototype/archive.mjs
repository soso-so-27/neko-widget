// Offline experiment only. No production credentials, Apple APIs, R2, or CloudKit.
// Server-managed JWE keys: NOT end-to-end encryption and NOT a key-backup system.
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { CompactEncrypt, compactDecrypt, decodeProtectedHeader } from 'jose';

export class ArchiveError extends Error {
  constructor(code) { super(code); this.name = 'ArchiveError'; this.code = code; }
}
const fail = (code) => { throw new ArchiveError(code); };
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const validID = (id) => typeof id === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(id);
const requireID = (id) => { if (!validID(id)) fail('INVALID_RECORD_ID'); };
const requireRevision = (n) => {
  if (!Number.isSafeInteger(n) || n < 1) fail('INVALID_REVISION');
};
const validateNote = (note) => {
  if (typeof note !== 'string' || Buffer.byteLength(note, 'utf8') > 16_384) fail('INVALID_NOTE');
  return note;
};
const validateMetadata = (metadata) => {
  const date = (value) => value === null || (typeof value === 'string'
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$/.test(value)
    && Number.isFinite(Date.parse(value)));
  if (!metadata || !date(metadata.capturedAt) || !date(metadata.recordedAt)
    || !(metadata.catName === null || (typeof metadata.catName === 'string' && metadata.catName.length <= 100))) {
    fail('INVALID_METADATA');
  }
  // No location, PhotoKit ID, recipient, or payment identity is copied.
  return { capturedAt: metadata.capturedAt, recordedAt: metadata.recordedAt, catName: metadata.catName };
};

export class OfflineArchive {
  #db; #identity; #keys; #activeKeyId; #newSaveAccess;

  constructor({ databasePath, initialize = false, identity, keys, activeKeyId, newSaveAccess }) {
    if (typeof identity?.requireOwner !== 'function' || !(keys instanceof Map)
      || typeof newSaveAccess !== 'function') fail('INVALID_SERVER_CONFIGURATION');
    // Recovery must not turn a missing database into an apparently empty archive.
    if (!initialize && !existsSync(databasePath)) fail('ARCHIVE_DATABASE_UNAVAILABLE');
    this.#identity = identity;
    this.#keys = keys;
    this.#activeKeyId = activeKeyId;
    this.#newSaveAccess = newSaveAccess;
    this.#db = new DatabaseSync(databasePath);
    this.#db.exec('PRAGMA busy_timeout = 1000; PRAGMA synchronous = FULL;');
    if (initialize) this.#db.exec(`CREATE TABLE IF NOT EXISTS archive_records (
        owner TEXT NOT NULL, record_id TEXT NOT NULL, revision INTEGER NOT NULL,
        ciphertext TEXT, deleted INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (owner, record_id),
        CHECK ((deleted = 0 AND ciphertext IS NOT NULL) OR (deleted = 1 AND ciphertext IS NULL))
      );
      CREATE TABLE IF NOT EXISTS archive_generations (owner TEXT PRIMARY KEY, generation INTEGER NOT NULL);`);
    try {
      this.#db.prepare('SELECT owner, record_id, revision, ciphertext, deleted FROM archive_records LIMIT 0').all();
      this.#db.prepare('SELECT owner, generation FROM archive_generations LIMIT 0').all();
    }
    catch { this.#db.close(); fail('ARCHIVE_DATABASE_UNAVAILABLE'); }
  }

  close() { this.#db.close(); }

  #generation(owner) {
    return this.#db.prepare('SELECT generation FROM archive_generations WHERE owner = ?').get(owner)?.generation ?? 0;
  }

  #bumpGeneration(owner) {
    this.#db.prepare(`INSERT INTO archive_generations (owner, generation) VALUES (?, 1)
      ON CONFLICT(owner) DO UPDATE SET generation = generation + 1`).run(owner);
  }

  #row(owner, recordId) {
    requireID(recordId);
    const row = this.#db.prepare('SELECT * FROM archive_records WHERE owner = ? AND record_id = ?').get(owner, recordId);
    if (!row || row.deleted) fail('RECORD_NOT_FOUND');
    return row;
  }

  #checkNewSave(owner) {
    // Trusted server callback, never a client-provided subscription flag.
    const access = this.#newSaveAccess(owner);
    if (!access || !['active', 'expired'].includes(access.entitlement)) fail('ACCESS_UNCONFIRMED');
    if (access.entitlement !== 'active') fail('NEW_SAVE_REQUIRES_MEMBERSHIP');
    if (access.consentVersion !== 'offline-explicit-v1') fail('PRESERVATION_CONSENT_REQUIRED');
  }

  #key(id) {
    const key = this.#keys.get(id);
    if (!(key instanceof Uint8Array) || key.byteLength !== 32) fail('ARCHIVE_KEY_UNAVAILABLE');
    return key;
  }

  async #encrypt(record) {
    const key = this.#key(this.#activeKeyId);
    return new CompactEncrypt(Buffer.from(JSON.stringify(record), 'utf8'))
      .setProtectedHeader({ alg: 'dir', enc: 'A256GCM', kid: this.#activeKeyId, typ: 'neko-offline-archive+jwe' })
      .encrypt(key);
  }

  async #decrypt(row) {
    let header;
    try { header = decodeProtectedHeader(row.ciphertext); } catch { fail('ARCHIVE_INTEGRITY_FAILED'); }
    if (header.alg !== 'dir' || header.enc !== 'A256GCM' || header.typ !== 'neko-offline-archive+jwe'
      || typeof header.kid !== 'string') fail('ARCHIVE_INTEGRITY_FAILED');
    const key = this.#key(header.kid);
    try {
      const { plaintext } = await compactDecrypt(row.ciphertext, key, {
        keyManagementAlgorithms: ['dir'], contentEncryptionAlgorithms: ['A256GCM'],
      });
      const record = JSON.parse(Buffer.from(plaintext).toString('utf8'));
      if (record.version !== 1 || record.owner !== row.owner || record.recordId !== row.record_id
        || record.revision !== row.revision || record.photo.mediaType !== 'image/jpeg') throw new Error();
      const bytes = Buffer.from(record.photo.base64, 'base64');
      if (bytes.length !== record.photo.byteLength || hash(bytes) !== record.photo.sha256) throw new Error();
      validateNote(record.note);
      validateMetadata(record.metadata);
      return record;
    } catch { fail('ARCHIVE_INTEGRITY_FAILED'); }
  }

  #transaction(operation) {
    this.#db.exec('BEGIN IMMEDIATE');
    try {
      const result = operation();
      this.#db.exec('COMMIT');
      return result;
    } catch (error) {
      this.#db.exec('ROLLBACK');
      throw error;
    }
  }

  async #confirmedRetry(session, owner, row, fingerprint) {
    if (row.deleted) fail('RECORD_ALREADY_EXISTS');
    const record = await this.#decrypt(row);
    if (record.initialContentSHA256 !== fingerprint) fail('RECORD_ALREADY_EXISTS');
    if (this.#identity.requireOwner(session) !== owner) fail('OWNER_CHANGED');
    if (this.#row(owner, row.record_id).revision !== record.revision) fail('REVISION_CONFLICT');
    return { recordId: row.record_id, revision: record.revision, alreadyPreserved: true };
  }

  async preserve(session, { recordId, photoBytes, note = '', metadata }) {
    const owner = this.#identity.requireOwner(session);
    requireID(recordId);
    // Fixture ceiling only; not the product quota or an image-decoder validation.
    if (!(photoBytes instanceof Uint8Array) || photoBytes.byteLength < 1 || photoBytes.byteLength > 2_097_152) {
      fail('INVALID_PHOTO_BYTES');
    }
    const bytes = Buffer.from(photoBytes);
    const record = {
      version: 1, owner, recordId, revision: 1,
      photo: { mediaType: 'image/jpeg', base64: bytes.toString('base64'), byteLength: bytes.length, sha256: hash(bytes) },
      note: validateNote(note), metadata: validateMetadata(metadata), consentVersion: 'offline-explicit-v1',
    };
    record.initialContentSHA256 = hash(Buffer.from(JSON.stringify([record.photo, record.note, record.metadata])));
    const existing = this.#db.prepare('SELECT * FROM archive_records WHERE owner = ? AND record_id = ?').get(owner, recordId);
    if (existing) return this.#confirmedRetry(session, owner, existing, record.initialContentSHA256);
    this.#checkNewSave(owner);
    const ciphertext = await this.#encrypt(record);
    // Recheck after async encryption: expiry, consent withdrawal, session expiry must win.
    if (this.#identity.requireOwner(session) !== owner) fail('OWNER_CHANGED');
    const concurrent = this.#transaction(() => {
      const row = this.#db.prepare('SELECT * FROM archive_records WHERE owner = ? AND record_id = ?').get(owner, recordId);
      if (row) return row;
      this.#checkNewSave(owner);
      this.#db.prepare('INSERT INTO archive_records (owner, record_id, revision, ciphertext) VALUES (?, ?, 1, ?)')
        .run(owner, recordId, ciphertext);
      this.#bumpGeneration(owner);
      return null;
    });
    if (concurrent) return this.#confirmedRetry(session, owner, concurrent, record.initialContentSHA256);
    return { recordId, revision: 1, alreadyPreserved: false };
  }

  list(session, { after = '', limit = 20 } = {}) {
    const owner = this.#identity.requireOwner(session);
    if (after !== '') requireID(after);
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) fail('INVALID_PAGE_SIZE');
    return this.#db.prepare(`SELECT record_id AS recordId, revision FROM archive_records
      WHERE owner = ? AND deleted = 0 AND record_id > ? ORDER BY record_id LIMIT ?`).all(owner, after, limit)
      .map((row) => ({ ...row }));
  }

  async read(session, recordId) {
    const owner = this.#identity.requireOwner(session);
    const record = await this.#decrypt(this.#row(owner, recordId));
    if (this.#identity.requireOwner(session) !== owner) fail('OWNER_CHANGED');
    // A delete or edit that won while decrypting must not produce a stale successful read.
    if (this.#row(owner, recordId).revision !== record.revision) fail('REVISION_CONFLICT');
    return {
      recordId, revision: record.revision, photoBytes: Buffer.from(record.photo.base64, 'base64'),
      photoSHA256: record.photo.sha256, mediaType: record.photo.mediaType,
      note: record.note, metadata: record.metadata,
    };
  }

  async editNote(session, { recordId, expectedRevision, note }) {
    const owner = this.#identity.requireOwner(session);
    requireRevision(expectedRevision);
    validateNote(note);
    const row = this.#row(owner, recordId);
    if (row.revision !== expectedRevision) fail('REVISION_CONFLICT');
    const record = await this.#decrypt(row);
    record.note = note;
    record.revision += 1;
    const ciphertext = await this.#encrypt(record);
    if (this.#identity.requireOwner(session) !== owner) fail('OWNER_CHANGED');
    return this.#transaction(() => {
      const result = this.#db.prepare(`UPDATE archive_records SET ciphertext = ?, revision = ?
        WHERE owner = ? AND record_id = ? AND revision = ? AND deleted = 0`)
        .run(ciphertext, record.revision, owner, recordId, expectedRevision);
      if (result.changes !== 1) fail('REVISION_CONFLICT');
      this.#bumpGeneration(owner);
      return { recordId, revision: record.revision };
    });
  }

  delete(session, { recordId, expectedRevision }) {
    const owner = this.#identity.requireOwner(session);
    requireRevision(expectedRevision);
    this.#row(owner, recordId);
    return this.#transaction(() => {
      const result = this.#db.prepare(`UPDATE archive_records SET ciphertext = NULL, deleted = 1, revision = revision + 1
        WHERE owner = ? AND record_id = ? AND revision = ? AND deleted = 0`).run(owner, recordId, expectedRevision);
      if (result.changes !== 1) fail('REVISION_CONFLICT');
      this.#bumpGeneration(owner);
      return { recordId, revision: expectedRevision + 1 };
    });
  }

  async *exportRecords(session) {
    // One record at a time. Any owner-scoped mutation invalidates this export;
    // the consumer must not label already-yielded partial results a complete backup.
    const owner = this.#identity.requireOwner(session);
    const generation = this.#generation(owner);
    const unchanged = () => {
      if (this.#identity.requireOwner(session) !== owner) fail('OWNER_CHANGED');
      if (this.#generation(owner) !== generation) fail('EXPORT_CHANGED');
    };
    let after = '';
    while (true) {
      unchanged();
      const page = this.list(session, { after });
      unchanged(); // Covers another DB writer between the generation read and page acquisition.
      if (!page.length) return;
      for (const item of page) {
        const record = await this.read(session, item.recordId);
        unchanged();
        if (record.revision !== item.revision) fail('REVISION_CONFLICT');
        yield {
          manifest: { recordId: record.recordId, revision: record.revision, mediaType: record.mediaType,
            photoSHA256: record.photoSHA256, photoBytes: record.photoBytes.length, ...record.metadata },
          photoBytes: record.photoBytes, noteText: Buffer.from(record.note, 'utf8'),
        };
        unchanged();
      }
      after = page.at(-1).recordId;
    }
  }
}
