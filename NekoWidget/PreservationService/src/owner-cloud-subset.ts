import { ServiceError } from './contracts';
import type { OwnerCloudInventory } from './owner-cloud-inventory';
import type { PurgeManifest } from './owner-purge-manifest';
import type { OwnerPhoto } from './owner-photo-inventory';
import type { RecoveryVersion } from './s3-recovery-copy';

const unavailable = () => new ServiceError('OWNER_CLOUD_SUBSET_UNAVAILABLE', 503);
export type RemainingCloudItems = { r2: readonly OwnerPhoto[];
  s3: readonly RecoveryVersion[] };

/** After partial erasure the actual cloud inventory may shrink, but never
 * acquire an unlisted key/version or changed bytes. The caller must first
 * verify the manifest against every version of the external S3 plan and the
 * erasing event; this comparison alone grants no deletion authority.
 */
export function remainingCloudItems(manifest: PurgeManifest,
  current: OwnerCloudInventory): RemainingCloudItems {
  try {
    if (!manifest || !current || manifest.ownerId !== current.ownerId) {
      throw unavailable();
    }
    const r2 = new Map<string, OwnerPhoto>();
    const s3 = new Map<string, RecoveryVersion>();
    for (const chunk of manifest.chunks) {
      if (chunk.kind === 'r2') {
        for (const item of chunk.items) {
          if (!('version' in item) || r2.has(item.key)) throw unavailable();
          r2.set(item.key, item);
        }
      } else if (chunk.kind === 's3') {
        for (const item of chunk.items) {
          if (!('versionId' in item)) throw unavailable();
          const key = `${item.key}\0${item.versionId}`;
          if (s3.has(key)) throw unavailable();
          s3.set(key, item);
        }
      } else throw unavailable();
    }
    if (r2.size !== manifest.r2Count || s3.size !== manifest.s3Count) {
      throw unavailable();
    }
    const remainR2: OwnerPhoto[] = [];
    const remainS3: RecoveryVersion[] = [];
    const seenR2 = new Set<string>();
    const seenS3 = new Set<string>();
    for (const item of current.r2Objects) {
      const expected = r2.get(item.key);
      if (!expected || seenR2.has(item.key) || expected.version !== item.version
        || expected.bytes !== item.bytes) throw unavailable();
      seenR2.add(item.key);
      remainR2.push(item);
    }
    for (const item of current.s3Versions) {
      const key = `${item.key}\0${item.versionId}`;
      const expected = s3.get(key);
      if (!expected || seenS3.has(key) || expected.deleteMarker !== item.deleteMarker
        || expected.bytes !== item.bytes) throw unavailable();
      seenS3.add(key);
      remainS3.push(item);
    }
    remainR2.sort((a, b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
    remainS3.sort((a, b) => a.key < b.key ? -1 : a.key > b.key ? 1
      : a.versionId < b.versionId ? -1 : a.versionId > b.versionId ? 1 : 0);
    return { r2: remainR2, s3: remainS3 };
  } catch { throw unavailable(); }
}
