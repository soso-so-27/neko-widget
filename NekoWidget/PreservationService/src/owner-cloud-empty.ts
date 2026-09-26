import { ServiceError } from './contracts';
import { inventoryOwnerCloudStorage } from './owner-cloud-inventory';
import type { S3RecoveryCopy } from './s3-recovery-copy';

const unavailable = () => new ServiceError('OWNER_CLOUD_NOT_EMPTY', 503);

/** Independent, read-only absence gate before any D1 content erasure and
 * again before a completed event. It covers R2 current objects and every
 * recovery/v1 S3 version/delete marker, not purge-intent/plan evidence.
 * Absence alone does not authorize D1 deletion: a matching external plan,
 * erasing claim and owner write fence are still required.
 */
export async function verifyOwnerCloudEmpty(bucket: R2Bucket,
  recovery: S3RecoveryCopy, ownerId: string): Promise<void> {
  try {
    for (let pass = 0; pass < 2; pass++) {
      const inventory = await inventoryOwnerCloudStorage(bucket, recovery, ownerId);
      if (inventory.r2Objects.length || inventory.r2Bytes || inventory.s3Versions.length
        || inventory.s3VersionBytes || inventory.s3DeleteMarkers) throw unavailable();
    }
  } catch { throw unavailable(); }
}
