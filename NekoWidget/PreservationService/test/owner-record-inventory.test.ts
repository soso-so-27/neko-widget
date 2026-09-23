import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { listFencedRecordReferencesPage } from '../src/owner-record-inventory';

const db = (env as unknown as { DB: D1Database }).DB;
const ids = {
  first: '00000000-0000-4000-8000-000000000001',
  second: '00000000-0000-4000-8000-000000000002',
  third: '00000000-0000-4000-8000-000000000003',
  photo: '00000000-0000-4000-8000-000000000004',
};
async function owner(disabled = 1) {
  const id = crypto.randomUUID();
  await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,disabled,created_at) VALUES(?,?,?,?)')
    .bind(id, crypto.randomUUID(), disabled, 1).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(id).run();
  return id;
}
async function record(ownerId: string, id: string, deleted = false, photoOwner = ownerId) {
  const photoKey = deleted ? null : `personal/${photoOwner}/${id}/${ids.photo}`;
  await db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,
    initial_operation,metadata,photo_key,photo_bytes,quota_bytes,deleted)
    VALUES(?,?,1,'synthetic','synthetic',?,?,?,?,?)`)
    .bind(ownerId, id, deleted ? null : new Uint8Array([1]).buffer,
      photoKey, deleted ? 0 : 1, deleted ? 0 : 2, deleted ? 1 : 0).run();
  return photoKey;
}

it('takes owner-bound, ordered pages of live and tombstoned references under a frozen owner', async () => {
  const id = await owner();
  const key = await record(id, ids.first); await record(id, ids.second, true);
  await record(id, ids.third); const other = await owner(); await record(other, ids.first);
  const first = await listFencedRecordReferencesPage(db, id, undefined, 2);
  expect(first.records).toEqual([
    { recordId: ids.first, revision: 1, deleted: false, photoKey: key },
    { recordId: ids.second, revision: 1, deleted: true, photoKey: null },
  ]);
  expect(first.nextCursor).toEqual({ ownerId: id, epoch: 0, generation: 3, lastRecordId: ids.second });
  expect(await listFencedRecordReferencesPage(db, id, first.nextCursor!, 2)).toEqual({
    records: [{ recordId: ids.third, revision: 1, deleted: false,
      photoKey: `personal/${id}/${ids.third}/${ids.photo}` }],
    epoch: 0, generation: 3, nextCursor: null,
  });
});

it('refuses active owners, pending writes, changed generations and foreign photo references', async () => {
  const active = await owner(0); await record(active, ids.first);
  await expect(listFencedRecordReferencesPage(db, active)).rejects
    .toMatchObject({ code: 'ARCHIVE_INVENTORY_UNAVAILABLE' });
  const id = await owner(); await record(id, ids.first); await record(id, ids.second);
  const first = await listFencedRecordReferencesPage(db, id, undefined, 1);
  await expect(listFencedRecordReferencesPage(db, id, { ...first.nextCursor!, ownerId: active }, 1))
    .rejects.toMatchObject({ code: 'ARCHIVE_INVENTORY_UNAVAILABLE' });
  await db.prepare(`INSERT INTO pa_uploads(operation_id,owner_id,record_id,object_key,reserved_bytes,expires_at)
    VALUES(?,?,?,?,1,10000)`).bind(crypto.randomUUID(), id, ids.third,
      `personal/${id}/${ids.third}/${ids.photo}`).run();
  await expect(listFencedRecordReferencesPage(db, id, first.nextCursor!, 1))
    .rejects.toMatchObject({ code: 'ARCHIVE_INVENTORY_UNAVAILABLE' });
  await db.prepare('DELETE FROM pa_uploads WHERE owner_id=?').bind(id).run();
  await record(id, ids.third);
  await expect(listFencedRecordReferencesPage(db, id, first.nextCursor!, 1))
    .rejects.toMatchObject({ code: 'ARCHIVE_INVENTORY_UNAVAILABLE' });
  const bad = await owner(); await record(bad, ids.first, false, active);
  await expect(listFencedRecordReferencesPage(db, bad)).rejects
    .toMatchObject({ code: 'ARCHIVE_INVENTORY_UNAVAILABLE' });
});

it('keeps legacy non-v4 record IDs within a fenced owner inventory', async () => {
  const id = await owner(); const oldRecordId = '00000000-0000-1000-8000-000000000010';
  const key = await record(id, oldRecordId);
  const page = await listFencedRecordReferencesPage(db, id);
  expect(page.records).toEqual([{ recordId: oldRecordId, revision: 1,
    deleted: false, photoKey: key }]);
});
