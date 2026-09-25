import { ServiceError } from './contracts';
import { listOwnerPhotoPage, type OwnerPhoto, type OwnerPhotoCursor } from './owner-photo-inventory';
import { S3RecoveryCopy, type RecoveryVersion, type RecoveryVersionCursor } from './s3-recovery-copy';

const unavailable = () => new ServiceError('OWNER_CLOUD_INVENTORY_UNAVAILABLE', 503);
const maximumItems = 100_000;
const maximumPages = 2_000;

export type OwnerCloudInventory = {
  ownerId: string;
  r2Objects: OwnerPhoto[];
  r2Bytes: number;
  s3Versions: RecoveryVersion[];
  s3VersionBytes: number;
  s3DeleteMarkers: number;
};

/** Read-only physical usage for one known owner, including old S3 versions.
 * This is neither account-wide billing nor deletion authority. It does not
 * include owner IDs missing from the caller's catalog, request charges,
 * delete-marker overhead, or a stable snapshot while writes are running.
 */
export async function inventoryOwnerCloudStorage(bucket: R2Bucket, s3: S3RecoveryCopy,
  ownerId: string): Promise<OwnerCloudInventory> {
  try {
    const r2Objects: OwnerPhoto[] = [];
    const r2Cursors = new Set<string>();
    let r2Bytes = 0;
    let r2Cursor: OwnerPhotoCursor | undefined;
    let pages = 0;
    do {
      if (++pages > maximumPages) throw unavailable();
      const page = await listOwnerPhotoPage(bucket, ownerId, r2Cursor);
      for (const object of page.objects) {
        if (r2Objects.length >= maximumItems || !Number.isSafeInteger(r2Bytes + object.bytes)) {
          throw unavailable();
        }
        r2Objects.push(object);
        r2Bytes += object.bytes;
      }
      r2Cursor = page.nextCursor ?? undefined;
      if (r2Cursor) {
        if (r2Cursors.has(r2Cursor.token)) throw unavailable();
        r2Cursors.add(r2Cursor.token);
      }
    } while (r2Cursor);

    const s3Versions: RecoveryVersion[] = [];
    const seenVersions = new Set<string>();
    const s3Cursors = new Set<string>();
    let s3VersionBytes = 0;
    let s3DeleteMarkers = 0;
    let s3Cursor: RecoveryVersionCursor | undefined;
    pages = 0;
    do {
      if (++pages > maximumPages) throw unavailable();
      const page = await s3.listOwnerVersionsPage(ownerId, s3Cursor);
      for (const version of page.versions) {
        const identity = `${version.key}\0${version.versionId}`;
        if (s3Versions.length >= maximumItems || seenVersions.has(identity)
          || !version.key.startsWith(`recovery/v1/${ownerId}/`)) throw unavailable();
        seenVersions.add(identity);
        if (version.deleteMarker) {
          if (version.bytes !== null) throw unavailable();
          s3DeleteMarkers++;
        } else {
          if (!Number.isSafeInteger(version.bytes) || version.bytes === null || version.bytes < 0
            || !Number.isSafeInteger(s3VersionBytes + version.bytes)) throw unavailable();
          s3VersionBytes += version.bytes;
        }
        s3Versions.push(version);
      }
      s3Cursor = page.nextCursor ?? undefined;
      if (s3Cursor) {
        const identity = `${s3Cursor.keyMarker}\0${s3Cursor.versionIdMarker ?? ''}`;
        if (s3Cursors.has(identity)) throw unavailable();
        s3Cursors.add(identity);
      }
    } while (s3Cursor);
    return { ownerId, r2Objects, r2Bytes, s3Versions, s3VersionBytes, s3DeleteMarkers };
  } catch { throw unavailable(); }
}
