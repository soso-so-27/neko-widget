import { ServiceError } from './contracts';
import type { OwnerPhoto } from './owner-photo-inventory';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const recordUuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const ownerPattern = new RegExp(`^${uuid}$`, 'u');
const photoPattern = new RegExp(`^personal/(${uuid})/${recordUuid}/${uuid}$`, 'u');
const unavailable = () => new ServiceError('R2_PHOTO_PURGE_UNAVAILABLE', 503);

/** One manifest-listed object, never a prefix or arbitrary key. R2's Worker
 * delete API has no version precondition. The caller must hold the owner's
 * write fence, block all other bucket writers, verify an externally sealed
 * plan and fresh eligibility, and re-list the entire owner prefix afterward.
 * The return value is not proof that the whole owner was erased.
 */
export async function requestManifestPhotoDeletion(bucket: R2Bucket, ownerId: string,
  item: OwnerPhoto): Promise<'deleted' | 'already-absent'> {
  if (!ownerPattern.test(ownerId) || !item || photoPattern.exec(item.key)?.[1] !== ownerId
    || !item.key.startsWith(`personal/${ownerId}/`)
    || typeof item.version !== 'string' || !item.version || item.version.length > 1024
    || !Number.isSafeInteger(item.bytes) || item.bytes < 1
    || item.bytes > 30 * 1024 * 1024
    || Object.keys(item).sort().join(',') !== 'bytes,key,version') throw unavailable();
  try {
    const before = await bucket.head(item.key);
    if (!before) return 'already-absent';
    if (before.key !== item.key || before.version !== item.version
      || before.size !== item.bytes) throw unavailable();
    await bucket.delete(item.key);
    if (await bucket.head(item.key)) throw unavailable();
    return 'deleted';
  } catch { throw unavailable(); }
}
