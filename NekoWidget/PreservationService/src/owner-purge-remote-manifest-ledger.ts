import { ServiceError } from './contracts';
import type { PurgeManifest } from './owner-purge-manifest';
import type { PurgeManifestCopyReference,
  S3PurgeManifestStore } from './s3-purge-manifest';

const unavailable = () => new ServiceError('PURGE_REMOTE_MANIFEST_UNAVAILABLE', 503);
const hex = /^[0-9a-f]{64}$/u;
interface Header { sha256: string; chunk_count: number; sealed_at: number | null }
interface Row { ordinal: number; s3_object_key: string; s3_version_id: string;
  s3_sha256: string; s3_bytes: number }

/** Retryable external plan publication. No erasing event or physical delete
 * occurs here. Full S3 audit belongs in an offline/bounded controller, not a
 * single Free Worker invocation for a large owner.
 */
export class OwnerPurgeRemoteManifestLedger {
  constructor(private readonly db: D1Database,
    private readonly store: Pick<S3PurgeManifestStore,
      'putChunk' | 'putHeader' | 'readExact' | 'loadPublished'>) {}

  private async header(m: PurgeManifest): Promise<Header> {
    const row = await this.db.prepare(`SELECT sha256,chunk_count,sealed_at
      FROM pa_purge_manifests WHERE owner_id=? AND intent_id=?`)
      .bind(m.ownerId, m.intentId).first<Header>();
    if (!row || row.sha256 !== m.sha256 || row.chunk_count !== m.chunks.length
      || row.sealed_at === null) throw unavailable();
    return row;
  }

  private async record(m: PurgeManifest, ordinal: number,
    reference: PurgeManifestCopyReference, now: number): Promise<void> {
    if (!Number.isSafeInteger(now) || now < 1 || !hex.test(reference.sha256)
      || !reference.versionId || reference.versionId === 'null'
      || !Number.isSafeInteger(reference.bytes) || reference.bytes < 1
      || reference.bytes > 512 * 1024) throw unavailable();
    const expectedKey = ordinal === -1
      ? `purge-plan/v1/${m.ownerId}/${m.intentId}/header`
      : `purge-plan/v1/${m.ownerId}/${m.intentId}/chunk/${String(ordinal).padStart(6, '0')}`;
    if (reference.key !== expectedKey || (ordinal >= 0 &&
      (reference.sha256 !== m.chunks[ordinal]?.sha256
        || reference.bytes !== m.chunks[ordinal]?.bytes))) throw unavailable();
    const select = () => this.db.prepare(`SELECT ordinal,s3_object_key,s3_version_id,
      s3_sha256,s3_bytes FROM pa_purge_manifest_remote_refs
      WHERE owner_id=? AND intent_id=? AND ordinal=?`)
      .bind(m.ownerId, m.intentId, ordinal).first<Row>();
    let row = await select();
    if (!row) {
      try {
        await this.db.prepare(`INSERT INTO pa_purge_manifest_remote_refs
          (owner_id,intent_id,ordinal,s3_object_key,s3_version_id,s3_sha256,
          s3_bytes,confirmed_at) VALUES(?,?,?,?,?,?,?,?)`)
          .bind(m.ownerId, m.intentId, ordinal, reference.key,
            reference.versionId, reference.sha256, reference.bytes, now).run();
      } catch { /* Resolve a same-key race by exact read-back. */ }
      row = await select();
    }
    if (!row || row.ordinal !== ordinal || row.s3_object_key !== reference.key
      || row.s3_version_id !== reference.versionId
      || row.s3_sha256 !== reference.sha256
      || row.s3_bytes !== reference.bytes) throw unavailable();
  }

  async copyChunk(m: PurgeManifest, index: number, now: number): Promise<void> {
    try {
      await this.header(m);
      if (!Number.isSafeInteger(index) || index < 0 || index >= m.chunks.length) {
        throw unavailable();
      }
      const reference = await this.store.putChunk(m, index);
      await this.record(m, index, reference, now);
    } catch { throw unavailable(); }
  }

  async copyHeader(m: PurgeManifest, now: number): Promise<void> {
    try {
      await this.header(m);
      const reference = await this.store.putHeader(m);
      await this.record(m, -1, reference, now);
    } catch { throw unavailable(); }
  }

  async seal(m: PurgeManifest, now: number): Promise<void> {
    try {
      const header = await this.header(m);
      if (!Number.isSafeInteger(now) || now < header.sealed_at!) throw unavailable();
      const rows = (await this.db.prepare(`SELECT ordinal,s3_object_key,s3_version_id,
        s3_sha256,s3_bytes FROM pa_purge_manifest_remote_refs
        WHERE owner_id=? AND intent_id=? ORDER BY ordinal`)
        .bind(m.ownerId, m.intentId).all<Row>()).results;
      if (rows.length !== m.chunks.length + 1 || rows[0]?.ordinal !== -1) {
        throw unavailable();
      }
      for (let i = 1; i < rows.length; i++) {
        if (rows[i]?.ordinal !== i - 1) throw unavailable();
      }
      const published = await this.store.loadPublished(m.ownerId, m.intentId, m.sha256);
      if (published.sha256 !== m.sha256 || published.chunks.length !== m.chunks.length) {
        throw unavailable();
      }
      for (const row of rows) {
        await this.store.readExact({ key: row.s3_object_key,
          versionId: row.s3_version_id, sha256: row.s3_sha256,
          bytes: row.s3_bytes });
      }
      const select = () => this.db.prepare(`SELECT root_sha256,sealed_at
        FROM pa_purge_manifest_remote_seals WHERE owner_id=? AND intent_id=?`)
        .bind(m.ownerId, m.intentId)
        .first<{ root_sha256: string; sealed_at: number }>();
      let final = await select();
      if (!final) {
        try {
          await this.db.prepare(`INSERT INTO pa_purge_manifest_remote_seals
            (owner_id,intent_id,root_sha256,sealed_at) VALUES(?,?,?,?)`)
            .bind(m.ownerId, m.intentId, m.sha256, now).run();
        } catch { /* Resolve a same-key race by exact read-back. */ }
        final = await select();
      }
      if (!final || final.root_sha256 !== m.sha256 || final.sealed_at > now) {
        throw unavailable();
      }
    } catch { throw unavailable(); }
  }
}
