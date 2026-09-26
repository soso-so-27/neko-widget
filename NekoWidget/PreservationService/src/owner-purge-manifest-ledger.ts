import { ServiceError } from './contracts';
import { purgeManifestChunkBytes, purgeManifestChunkDigest,
  purgeManifestRootDigest, type PurgeManifest } from './owner-purge-manifest';

const hex = /^[0-9a-f]{64}$/u;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const uuidPart = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const recordPart = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const photoKey = new RegExp(`^personal/(${uuidPart})/${recordPart}/${uuidPart}$`, 'u');
const recoveryKey = new RegExp(`^recovery/v1/(${uuidPart})/(?:photo|record|manifest|owner)/${uuidPart}$`, 'u');
const unavailable = () => new ServiceError('OWNER_PURGE_MANIFEST_LEDGER_UNAVAILABLE', 503);
interface HeaderRow {
  owner_id: string; intent_id: string; owner_epoch: number;
  inventory_generation: number; record_digest: string; records: number;
  r2_count: number; s3_count: number; r2_bytes: number; s3_bytes: number;
  chunk_count: number; sha256: string; created_at: number; sealed_at: number | null;
}
interface ChunkRow {
  ordinal: number; kind: string; item_count: number; sha256: string;
  bytes: number; payload: string;
}
type Descriptor = Pick<ChunkRow, 'ordinal' | 'kind' | 'sha256' | 'bytes' | 'item_count'>;

/** Stages a deletion plan in immutable, owner-scoped D1 rows. It does not
 * erase data. Each method is independently retryable, so a controller can
 * limit work per invocation instead of exceeding Worker subrequest budgets.
 */
export class OwnerPurgeManifestLedger {
  constructor(private readonly db: D1Database) {}

  private readHeader(ownerId: string, intentId: string): Promise<HeaderRow | null> {
    return this.db.prepare(`SELECT * FROM pa_purge_manifests WHERE owner_id=? AND intent_id=?`)
      .bind(ownerId, intentId).first<HeaderRow>();
  }

  private async verifySummary(manifest: PurgeManifest): Promise<void> {
    if (manifest?.version !== 1 || !uuid.test(manifest.ownerId)
      || !uuid.test(manifest.intentId) || !hex.test(manifest.sha256)
      || !hex.test(manifest.recordDigest)
      || !Number.isSafeInteger(manifest.ownerEpoch) || manifest.ownerEpoch < 1
      || !Number.isSafeInteger(manifest.inventoryGeneration)
      || manifest.inventoryGeneration < 0
      || !Number.isSafeInteger(manifest.records) || manifest.records < 0
      || manifest.records > 100_000
      || !Number.isSafeInteger(manifest.r2Count) || manifest.r2Count < 0
      || manifest.r2Count > 100_000
      || !Number.isSafeInteger(manifest.s3Count) || manifest.s3Count < 0
      || manifest.s3Count > 100_000
      || !Number.isSafeInteger(manifest.r2Bytes) || manifest.r2Bytes < 0
      || !Number.isSafeInteger(manifest.s3Bytes) || manifest.s3Bytes < 0
      || !Array.isArray(manifest.chunks) || manifest.chunks.length > 1564) throw unavailable();
    let r2 = 0;
    let s3 = 0;
    let r2Bytes = 0;
    let s3Bytes = 0;
    let pastS3 = false;
    let lastR2 = '';
    let lastS3Key = '';
    let lastS3Version = '';
    for (let i = 0; i < manifest.chunks.length; i++) {
      const chunk = manifest.chunks[i]!;
      if (chunk.ordinal !== i || !['r2', 's3'].includes(chunk.kind)
        || !hex.test(chunk.sha256) || !Number.isSafeInteger(chunk.bytes)
        || chunk.bytes < 1 || chunk.bytes > 512 * 1024
        || !Array.isArray(chunk.items) || chunk.items.length < 1
        || chunk.items.length > 128 || (pastS3 && chunk.kind === 'r2')) throw unavailable();
      if (chunk.kind === 's3') {
        pastS3 = true;
        s3 += chunk.items.length;
        for (const item of chunk.items) {
          if (!('versionId' in item) || recoveryKey.exec(item.key)?.[1] !== manifest.ownerId
            || typeof item.versionId !== 'string' || !item.versionId
            || item.versionId === 'null' || item.versionId.length > 1024
            || item.key < lastS3Key
            || (item.key === lastS3Key && item.versionId <= lastS3Version)
            || typeof item.deleteMarker !== 'boolean'
            || (item.deleteMarker ? item.bytes !== null
              : !Number.isSafeInteger(item.bytes) || item.bytes === null || item.bytes < 0)) {
            throw unavailable();
          }
          lastS3Key = item.key;
          lastS3Version = item.versionId;
          if (!item.deleteMarker) {
            if (!Number.isSafeInteger(s3Bytes + item.bytes!)) throw unavailable();
            s3Bytes += item.bytes!;
          }
        }
      } else {
        r2 += chunk.items.length;
        for (const item of chunk.items) {
          if (!('version' in item) || photoKey.exec(item.key)?.[1] !== manifest.ownerId
            || item.key <= lastR2 || typeof item.version !== 'string'
            || !item.version || item.version.length > 1024
            || !Number.isSafeInteger(item.bytes) || item.bytes < 1
            || !Number.isSafeInteger(r2Bytes + item.bytes)) throw unavailable();
          lastR2 = item.key;
          r2Bytes += item.bytes;
        }
      }
    }
    if (r2 !== manifest.r2Count || s3 !== manifest.s3Count
      || r2Bytes !== manifest.r2Bytes || s3Bytes !== manifest.s3Bytes) throw unavailable();
    if (await purgeManifestRootDigest(manifest) !== manifest.sha256) throw unavailable();
  }

  private matches(header: HeaderRow | null, m: PurgeManifest): boolean {
    return !!header && header.owner_id === m.ownerId && header.intent_id === m.intentId
      && header.owner_epoch === m.ownerEpoch
      && header.inventory_generation === m.inventoryGeneration
      && header.record_digest === m.recordDigest && header.records === m.records
      && header.r2_count === m.r2Count && header.s3_count === m.s3Count
      && header.r2_bytes === m.r2Bytes && header.s3_bytes === m.s3Bytes
      && header.chunk_count === m.chunks.length && header.sha256 === m.sha256;
  }

  async open(manifest: PurgeManifest, createdAt: number): Promise<void> {
    try {
      await this.verifySummary(manifest);
      if (!Number.isSafeInteger(createdAt) || createdAt < 1) throw unavailable();
      let header = await this.readHeader(manifest.ownerId, manifest.intentId);
      if (!header) {
        try {
          await this.db.prepare(`INSERT INTO pa_purge_manifests(owner_id,intent_id,
            owner_epoch,inventory_generation,record_digest,records,r2_count,s3_count,
            r2_bytes,s3_bytes,chunk_count,sha256,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`)
            .bind(manifest.ownerId, manifest.intentId, manifest.ownerEpoch,
              manifest.inventoryGeneration, manifest.recordDigest, manifest.records,
              manifest.r2Count, manifest.s3Count, manifest.r2Bytes, manifest.s3Bytes,
              manifest.chunks.length, manifest.sha256, createdAt).run();
        } catch { /* Resolve a same-key race by exact read-back. */ }
        header = await this.readHeader(manifest.ownerId, manifest.intentId);
      }
      if (!this.matches(header, manifest) || header!.created_at > createdAt) {
        throw unavailable();
      }
    } catch { throw unavailable(); }
  }

  async appendChunk(manifest: PurgeManifest, index: number): Promise<void> {
    try {
      // The full manifest is validated by open() and seal(). Revalidating and
      // hashing every item for every chunk makes a large owner quadratic.
      // An unsealed or mismatched chunk has no deletion authority.
      if (manifest?.version !== 1 || !uuid.test(manifest.ownerId)
        || !uuid.test(manifest.intentId) || !hex.test(manifest.sha256)
        || !Array.isArray(manifest.chunks)) throw unavailable();
      if (!Number.isSafeInteger(index) || index < 0 || index >= manifest.chunks.length) {
        throw unavailable();
      }
      const chunk = manifest.chunks[index]!;
      const payload = purgeManifestChunkBytes(manifest.ownerId, manifest.intentId, chunk);
      if (payload.length !== chunk.bytes
        || await purgeManifestChunkDigest(payload) !== chunk.sha256) throw unavailable();
      const text = new TextDecoder().decode(payload);
      const header = await this.readHeader(manifest.ownerId, manifest.intentId);
      if (!this.matches(header, manifest)) throw unavailable();
      let row = await this.db.prepare(`SELECT ordinal,kind,item_count,sha256,bytes,payload
        FROM pa_purge_manifest_chunks WHERE owner_id=? AND intent_id=? AND ordinal=?`)
        .bind(manifest.ownerId, manifest.intentId, index).first<ChunkRow>();
      if (!row) {
        try {
          await this.db.prepare(`INSERT INTO pa_purge_manifest_chunks(owner_id,intent_id,
            ordinal,kind,item_count,sha256,bytes,payload) VALUES(?,?,?,?,?,?,?,?)`)
            .bind(manifest.ownerId, manifest.intentId, index, chunk.kind,
              chunk.items.length, chunk.sha256, chunk.bytes, text).run();
        } catch { /* Resolve a same-chunk race by exact read-back. */ }
        row = await this.db.prepare(`SELECT ordinal,kind,item_count,sha256,bytes,payload
          FROM pa_purge_manifest_chunks WHERE owner_id=? AND intent_id=? AND ordinal=?`)
          .bind(manifest.ownerId, manifest.intentId, index).first<ChunkRow>();
      }
      if (!row || row.ordinal !== index || row.kind !== chunk.kind
        || row.item_count !== chunk.items.length || row.sha256 !== chunk.sha256
        || row.bytes !== chunk.bytes || row.payload !== text) throw unavailable();
    } catch { throw unavailable(); }
  }

  async seal(manifest: PurgeManifest, sealedAt: number): Promise<void> {
    try {
      await this.verifySummary(manifest);
      if (!Number.isSafeInteger(sealedAt) || sealedAt < 1) throw unavailable();
      const header = await this.readHeader(manifest.ownerId, manifest.intentId);
      if (!this.matches(header, manifest) || header!.created_at > sealedAt) throw unavailable();
      const rows = (await this.db.prepare(`SELECT ordinal,kind,item_count,sha256,bytes
        FROM pa_purge_manifest_chunks WHERE owner_id=? AND intent_id=?
        ORDER BY ordinal`).bind(manifest.ownerId, manifest.intentId)
        .all<Descriptor>()).results;
      if (rows.length !== manifest.chunks.length) throw unavailable();
      for (let i = 0; i < rows.length; i++) {
        const row = rows[i]!;
        const chunk = manifest.chunks[i]!;
        if (row.ordinal !== i || row.kind !== chunk.kind
          || row.item_count !== chunk.items.length || row.sha256 !== chunk.sha256
          || row.bytes !== chunk.bytes) throw unavailable();
      }
      if (header!.sealed_at === null) {
        await this.db.prepare(`UPDATE pa_purge_manifests SET sealed_at=?
          WHERE owner_id=? AND intent_id=? AND sealed_at IS NULL`)
          .bind(sealedAt, manifest.ownerId, manifest.intentId).run();
      }
      const final = await this.readHeader(manifest.ownerId, manifest.intentId);
      if (!this.matches(final, manifest) || final!.sealed_at === null
        || final!.sealed_at > sealedAt) throw unavailable();
    } catch { throw unavailable(); }
  }
}
