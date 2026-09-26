import { ServiceError } from './contracts';
import type { OwnerCloudInventory } from './owner-cloud-inventory';
import type { PrimaryInventory } from './owner-primary-reconciliation';
import type { PurgeFence } from './owner-purge-fence';
import type { OwnerPhoto } from './owner-photo-inventory';
import type { RecoveryVersion } from './s3-recovery-copy';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const recordUuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const ownerPattern = new RegExp(`^${uuid}$`, 'u');
const photoKeyPattern = new RegExp(`^personal/(${uuid})/${recordUuid}/${uuid}$`, 'u');
const recoveryKeyPattern = new RegExp(`^recovery/v1/(${uuid})/(?:photo|record|manifest|owner)/${uuid}$`, 'u');
const hexPattern = /^[0-9a-f]{64}$/u;
const maxItems = 100_000;
const chunkSize = 128;
const maxChunkBytes = 512 * 1024;
const unavailable = () => new ServiceError('OWNER_PURGE_MANIFEST_UNAVAILABLE', 503);
const asciiCompare = (a: string, b: string): number => a < b ? -1 : a > b ? 1 : 0;

export type PurgeManifestChunk = {
  ordinal: number;
  kind: 'r2' | 's3';
  sha256: string;
  bytes: number;
  items: readonly (OwnerPhoto | RecoveryVersion)[];
};
export type PurgeManifest = {
  version: 1;
  ownerId: string;
  intentId: string;
  ownerEpoch: number;
  inventoryGeneration: number;
  recordDigest: string;
  records: number;
  r2Count: number;
  s3Count: number;
  r2Bytes: number;
  s3Bytes: number;
  chunks: readonly PurgeManifestChunk[];
  sha256: string;
};

const digest = async (bytes: Uint8Array): Promise<string> =>
  [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as BufferSource))]
    .map(byte => byte.toString(16).padStart(2, '0')).join('');
const encode = (value: unknown): Uint8Array => new TextEncoder().encode(JSON.stringify(value));
export const purgeManifestChunkBytes = (ownerId: string, intentId: string,
  chunk: Pick<PurgeManifestChunk, 'ordinal' | 'kind' | 'items'>): Uint8Array =>
  encode({ version: 1, ownerId, intentId, ordinal: chunk.ordinal,
    kind: chunk.kind, items: chunk.items });
export const purgeManifestChunkDigest = digest;
export const purgeManifestRootDigest = async (manifest: Pick<PurgeManifest,
  'ownerId' | 'intentId' | 'ownerEpoch' | 'inventoryGeneration' | 'recordDigest'
  | 'records' | 'r2Count' | 's3Count' | 'r2Bytes' | 's3Bytes' | 'chunks'>): Promise<string> =>
  digest(encode({ version: 1, ownerId: manifest.ownerId, intentId: manifest.intentId,
    ownerEpoch: manifest.ownerEpoch, inventoryGeneration: manifest.inventoryGeneration,
    recordDigest: manifest.recordDigest, records: manifest.records,
    r2Count: manifest.r2Count, s3Count: manifest.s3Count,
    r2Bytes: manifest.r2Bytes, s3Bytes: manifest.s3Bytes,
    chunks: manifest.chunks.map(({ ordinal, kind, sha256, bytes }) =>
      ({ ordinal, kind, sha256, bytes })) }));

/** Canonical, bounded chunks rather than one D1 blob. This is only a
 * read-only proposed deletion plan. Persistence, external erasing proof,
 * fresh billing and a second inventory are separate required gates.
 */
export async function buildOwnerPurgeManifest(fence: PurgeFence, primary: PrimaryInventory,
  cloud: OwnerCloudInventory): Promise<PurgeManifest> {
  try {
    const ownerId = fence.ownerId;
    if (!ownerPattern.test(ownerId) || !ownerPattern.test(fence.fenceId)
      || !Number.isSafeInteger(fence.ownerEpoch) || fence.ownerEpoch < 1
      || !Number.isSafeInteger(fence.inventoryGeneration) || fence.inventoryGeneration < 0
      || primary.ownerId !== ownerId || cloud.ownerId !== ownerId
      || primary.epoch !== fence.ownerEpoch
      || primary.generation !== fence.inventoryGeneration
      || !hexPattern.test(primary.recordDigest)
      || !Number.isSafeInteger(primary.records) || primary.records < 0
      || !Number.isSafeInteger(primary.photos) || primary.photos < 0
      || primary.photos !== primary.photoKeys.length
      || cloud.r2Objects.length > maxItems || cloud.s3Versions.length > maxItems
      || cloud.r2Objects.length !== primary.photos) throw unavailable();
    const r2 = [...cloud.r2Objects].sort((a, b) => asciiCompare(a.key, b.key));
    const references = [...primary.photoKeys].sort();
    let r2Bytes = 0;
    for (let i = 0; i < r2.length; i++) {
      const item = r2[i]!;
      if (Object.keys(item).sort().join(',') !== 'bytes,key,version'
        || item.key !== references[i] || photoKeyPattern.exec(item.key)?.[1] !== ownerId
        || (i > 0 && item.key === r2[i - 1]!.key)
        || !item.version || item.version.length > 1024
        || !Number.isSafeInteger(item.bytes) || item.bytes < 1
        || !Number.isSafeInteger(r2Bytes + item.bytes)) throw unavailable();
      r2Bytes += item.bytes;
    }
    const s3 = [...cloud.s3Versions].sort((a, b) =>
      asciiCompare(a.key, b.key) || asciiCompare(a.versionId, b.versionId));
    let s3Bytes = 0;
    let markers = 0;
    for (let i = 0; i < s3.length; i++) {
      const item = s3[i]!;
      if (Object.keys(item).sort().join(',') !== 'bytes,deleteMarker,key,versionId'
        || recoveryKeyPattern.exec(item.key)?.[1] !== ownerId
        || !item.versionId || item.versionId === 'null' || item.versionId.length > 1024
        || (i > 0 && item.key === s3[i - 1]!.key
          && item.versionId === s3[i - 1]!.versionId)
        || typeof item.deleteMarker !== 'boolean'
        || (item.deleteMarker ? item.bytes !== null
          : !Number.isSafeInteger(item.bytes) || item.bytes === null || item.bytes < 0)) {
        throw unavailable();
      }
      if (item.deleteMarker) markers++;
      else {
        if (!Number.isSafeInteger(s3Bytes + item.bytes!)) throw unavailable();
        s3Bytes += item.bytes!;
      }
    }
    if (r2Bytes !== cloud.r2Bytes || s3Bytes !== cloud.s3VersionBytes
      || markers !== cloud.s3DeleteMarkers) throw unavailable();
    const chunks: PurgeManifestChunk[] = [];
    for (const [kind, items] of [['r2', r2], ['s3', s3]] as const) {
      for (let start = 0; start < items.length; start += chunkSize) {
        const segment = items.slice(start, start + chunkSize);
        const bytes = purgeManifestChunkBytes(ownerId, fence.fenceId,
          { ordinal: chunks.length, kind, items: segment });
        if (bytes.length < 1 || bytes.length > maxChunkBytes) throw unavailable();
        chunks.push({ ordinal: chunks.length, kind, sha256: await digest(bytes),
          bytes: bytes.length, items: segment });
      }
    }
    const root = { ownerId, intentId: fence.fenceId,
      ownerEpoch: fence.ownerEpoch, inventoryGeneration: fence.inventoryGeneration,
      recordDigest: primary.recordDigest, records: primary.records,
      r2Count: r2.length, s3Count: s3.length, r2Bytes, s3Bytes,
      chunks };
    return { version: 1, ownerId, intentId: fence.fenceId,
      ownerEpoch: fence.ownerEpoch, inventoryGeneration: fence.inventoryGeneration,
      recordDigest: primary.recordDigest, records: primary.records,
      r2Count: r2.length, s3Count: s3.length,
      r2Bytes, s3Bytes, chunks, sha256: await purgeManifestRootDigest(root) };
  } catch { throw unavailable(); }
}
