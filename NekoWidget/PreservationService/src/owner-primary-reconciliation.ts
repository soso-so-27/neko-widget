import { ServiceError } from './contracts';
import { listFencedRecordReferencesPage } from './owner-record-inventory';
import { listOwnerPhotoPage } from './owner-photo-inventory';

const unavailable = () => new ServiceError('PRIMARY_INVENTORY_UNAVAILABLE', 503);
const maximumItems = 100_000;

export type PrimaryInventory = {
  ownerId: string;
  epoch: number;
  generation: number;
  records: number;
  photos: number;
  /** SHA-256 of ordered record IDs, revisions, tombstones and photo keys. */
  recordDigest: string;
  /** Present only to support a later, separately authorized deletion plan. */
  photoKeys: string[];
};

/** Read-only cross-check of current D1 references and R2 objects for one
 * disabled owner. It is not deletion authority: billing, notice evidence,
 * owner fence, S3 versions, a durable deletion ledger and a second fresh
 * inventory must all be established separately before any removal.
 */
async function reconcile(db: D1Database, bucket: R2Bucket, ownerId: string,
  allowUnreferencedObjects: boolean): Promise<PrimaryInventory> {
  try {
    const references = new Set<string>();
    const recordTuples: [string, number, boolean, string | null][] = [];
    let records = 0;
    let recordPages = 0;
    let epoch: number | undefined;
    let generation: number | undefined;
    let recordCursor: Awaited<ReturnType<typeof listFencedRecordReferencesPage>>['nextCursor'] = null;
    do {
      if (++recordPages > 1_001) throw unavailable();
      const page = await listFencedRecordReferencesPage(db, ownerId, recordCursor ?? undefined);
      if (epoch !== undefined && (page.epoch !== epoch || page.generation !== generation)) {
        throw unavailable();
      }
      epoch = page.epoch;
      generation = page.generation;
      for (const item of page.records) {
        if (++records > maximumItems) throw unavailable();
        recordTuples.push([item.recordId, item.revision, item.deleted, item.photoKey]);
        if (item.photoKey !== null) {
          if (references.has(item.photoKey)) throw unavailable();
          references.add(item.photoKey);
        }
      }
      recordCursor = page.nextCursor;
    } while (recordCursor);

    const objects = new Set<string>();
    const seenPhotoCursors = new Set<string>();
    let photoPages = 0;
    let photoCursor: Awaited<ReturnType<typeof listOwnerPhotoPage>>['nextCursor'] = null;
    do {
      if (++photoPages > 2_000) throw unavailable();
      const page = await listOwnerPhotoPage(bucket, ownerId, photoCursor ?? undefined);
      for (const item of page.objects) {
        if (objects.size >= maximumItems || objects.has(item.key)
          || (!allowUnreferencedObjects && !references.has(item.key))) throw unavailable();
        objects.add(item.key);
      }
      photoCursor = page.nextCursor;
      if (photoCursor && (seenPhotoCursors.has(photoCursor.token)
        || seenPhotoCursors.size >= 2_000)) throw unavailable();
      if (photoCursor) seenPhotoCursors.add(photoCursor.token);
    } while (photoCursor);
    if (references.size > objects.size || [...references].some(key => !objects.has(key))
      || (!allowUnreferencedObjects && objects.size !== references.size)) throw unavailable();

    // A changed DB generation while R2 was listed invalidates this snapshot.
    const final = await listFencedRecordReferencesPage(db, ownerId, undefined, 1);
    if (final.epoch !== epoch || final.generation !== generation) throw unavailable();
    const serialized = new TextEncoder().encode(JSON.stringify(recordTuples));
    const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', serialized));
    const recordDigest = Array.from(hash, byte => byte.toString(16).padStart(2, '0')).join('');
    return { ownerId, epoch: epoch!, generation: generation!, records,
      photos: objects.size, recordDigest, photoKeys: [...objects].sort() };
  } catch { throw unavailable(); }
}

/** Pre-release reconciliation rejects any unreferenced R2 object. */
export async function reconcileFencedPrimaryInventory(db: D1Database,
  bucket: R2Bucket, ownerId: string): Promise<PrimaryInventory> {
  return reconcile(db, bucket, ownerId, false);
}

/** Erasure must include even an orphan left by a failed upload. Every live DB
 * photo reference must still exist, but extra owner-scoped R2 objects are
 * included in the deletion plan rather than silently abandoned.
 */
export async function reconcileFencedPurgePrimaryInventory(db: D1Database,
  bucket: R2Bucket, ownerId: string): Promise<PrimaryInventory> {
  return reconcile(db, bucket, ownerId, true);
}
