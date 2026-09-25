import { ServiceError } from './contracts';
import { inventoryOwnerCloudStorage, type OwnerCloudInventory } from './owner-cloud-inventory';
import { reconcileFencedPrimaryInventory, type PrimaryInventory } from './owner-primary-reconciliation';
import type { S3RecoveryCopy } from './s3-recovery-copy';

const unavailable = () => new ServiceError('OWNER_CLOUD_SNAPSHOT_UNAVAILABLE', 503);

export type OwnerCloudSnapshot = {
  ownerId: string;
  epoch: number;
  generation: number;
  records: number;
  photos: number;
  r2Bytes: number;
  s3Versions: number;
  s3VersionBytes: number;
  s3DeleteMarkers: number;
};

function physicalSignature(inventory: OwnerCloudInventory): string {
  const r2 = inventory.r2Objects.map(item => [item.key, item.version, item.bytes] as const)
    .sort((a, b) => a[0].localeCompare(b[0]));
  const s3 = inventory.s3Versions.map(item =>
    [item.key, item.versionId, item.deleteMarker, item.bytes] as const)
    .sort((a, b) => a[0] === b[0] ? a[1].localeCompare(b[1]) : a[0].localeCompare(b[0]));
  return JSON.stringify([r2, s3]);
}

function matchesPrimary(primary: PrimaryInventory, inventory: OwnerCloudInventory): boolean {
  if (primary.ownerId !== inventory.ownerId || primary.photos !== inventory.r2Objects.length) return false;
  const keys = inventory.r2Objects.map(item => item.key).sort();
  return keys.every((key, index) => key === primary.photoKeys[index]);
}

/** Two read-only physical passes around two primary checks. A write, missing
 * photo or changed S3 version invalidates the result. This is advisory usage
 * evidence, not a recovery guarantee or purge authorization: it does not
 * validate S3 contents against all D1 references, billing or notice evidence,
 * and the owner must remain fenced throughout any later destructive work.
 */
export async function snapshotFencedOwnerCloudStorage(db: D1Database, bucket: R2Bucket,
  s3: S3RecoveryCopy, ownerId: string): Promise<OwnerCloudSnapshot> {
  try {
    const firstPrimary = await reconcileFencedPrimaryInventory(db, bucket, ownerId);
    const firstCloud = await inventoryOwnerCloudStorage(bucket, s3, ownerId);
    if (!matchesPrimary(firstPrimary, firstCloud)) throw unavailable();
    const secondCloud = await inventoryOwnerCloudStorage(bucket, s3, ownerId);
    const secondPrimary = await reconcileFencedPrimaryInventory(db, bucket, ownerId);
    if (firstPrimary.epoch !== secondPrimary.epoch
      || firstPrimary.generation !== secondPrimary.generation
      || firstPrimary.records !== secondPrimary.records
      || firstPrimary.recordDigest !== secondPrimary.recordDigest
      || firstPrimary.photos !== secondPrimary.photos
      || !matchesPrimary(secondPrimary, secondCloud)
      || physicalSignature(firstCloud) !== physicalSignature(secondCloud)) throw unavailable();
    return { ownerId, epoch: secondPrimary.epoch, generation: secondPrimary.generation,
      records: secondPrimary.records, photos: secondPrimary.photos,
      r2Bytes: secondCloud.r2Bytes, s3Versions: secondCloud.s3Versions.length,
      s3VersionBytes: secondCloud.s3VersionBytes, s3DeleteMarkers: secondCloud.s3DeleteMarkers };
  } catch { throw unavailable(); }
}
