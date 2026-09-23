import { ServiceError } from './contracts';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const idPattern = new RegExp(`^${uuid}$`, 'u');
const recordUuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const recordIdPattern = new RegExp(`^${recordUuid}$`, 'u');
const photoKeyPattern = new RegExp(`^personal/(${uuid})/(${recordUuid})/${uuid}$`, 'u');
const unavailable = () => new ServiceError('ARCHIVE_INVENTORY_UNAVAILABLE', 503);

interface OwnerRow {
  owner_id: string; epoch: number; disabled: number; inventory_owner: string | null;
  generation: number; reserved_bytes: number; pending_uploads: number;
}
interface RecordRow {
  record_id: string; revision: number; deleted: number; photo_key: string | null;
}
export type FencedRecord = { recordId: string; revision: number; deleted: boolean; photoKey: string | null };
export type FencedRecordCursor = { ownerId: string; epoch: number; generation: number; lastRecordId: string };
export type FencedRecordPage = {
  records: FencedRecord[]; epoch: number; generation: number; nextCursor: FencedRecordCursor | null;
};

/** Advisory DB references after owner revocation/fencing. This checks only the
 * primary DB: a future purge must separately prove billing, notice delivery,
 * all R2/S3 versions and a durable deletion ledger before touching data.
 */
export async function listFencedRecordReferencesPage(db: D1Database, ownerId: string,
  cursor?: FencedRecordCursor, limit = 100): Promise<FencedRecordPage> {
  if (!idPattern.test(ownerId) || !Number.isInteger(limit) || limit < 1 || limit > 100
    || (cursor && (cursor.ownerId !== ownerId || !recordIdPattern.test(cursor.lastRecordId)
      || !Number.isSafeInteger(cursor.epoch) || cursor.epoch < 0
      || !Number.isSafeInteger(cursor.generation) || cursor.generation < 0))) throw unavailable();
  try {
    // D1 batch reads both statements in a single transaction on the primary.
    const [ownerResult, recordResult] = await db.batch([
      db.prepare(`SELECT o.owner_id,o.epoch,o.disabled,i.owner_id AS inventory_owner,
        COALESCE(i.generation,0) AS generation,COALESCE(i.reserved_bytes,0) AS reserved_bytes,
        (SELECT COUNT(*) FROM pa_uploads u WHERE u.owner_id=o.owner_id) AS pending_uploads
        FROM pa_owners o LEFT JOIN pa_inventory i ON i.owner_id=o.owner_id WHERE o.owner_id=?`)
        .bind(ownerId),
      db.prepare(`SELECT record_id,revision,deleted,photo_key FROM pa_records
        WHERE owner_id=? AND record_id>? ORDER BY record_id LIMIT ?`)
        .bind(ownerId, cursor?.lastRecordId ?? '', limit + 1),
    ]);
    const owner = ownerResult?.results[0] as OwnerRow | undefined;
    if (!ownerResult?.success || !recordResult?.success || !owner || owner.owner_id !== ownerId
      || owner.disabled !== 1 || !Number.isSafeInteger(owner.epoch) || owner.epoch < 0
      || !Number.isSafeInteger(owner.generation) || owner.generation < 0
      || owner.reserved_bytes !== 0 || owner.pending_uploads !== 0
      || (cursor && (cursor.epoch !== owner.epoch || cursor.generation !== owner.generation))) {
      throw unavailable();
    }
    const rows = recordResult.results as unknown as RecordRow[];
    if (rows.length > 0 && !owner.inventory_owner) throw unavailable();
    const records: FencedRecord[] = [];
    let last = cursor?.lastRecordId ?? '';
    for (const row of rows.slice(0, limit)) {
      if (!recordIdPattern.test(row.record_id) || row.record_id <= last
        || !Number.isSafeInteger(row.revision) || row.revision < 1
        || (row.deleted !== 0 && row.deleted !== 1)
        || (row.deleted === 1 && row.photo_key !== null)
        || (row.photo_key !== null && (photoKeyPattern.exec(row.photo_key)?.[1] !== ownerId
          || photoKeyPattern.exec(row.photo_key)?.[2] !== row.record_id))) throw unavailable();
      records.push({ recordId: row.record_id, revision: row.revision,
        deleted: row.deleted === 1, photoKey: row.photo_key });
      last = row.record_id;
    }
    return { records, epoch: owner.epoch, generation: owner.generation,
      nextCursor: rows.length > limit ? { ownerId, epoch: owner.epoch,
        generation: owner.generation, lastRecordId: last } : null };
  } catch { throw unavailable(); }
}
