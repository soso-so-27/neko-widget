import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { reconcileFencedPrimaryInventory,
  reconcileFencedPurgePrimaryInventory } from '../src/owner-primary-reconciliation';

const { DB: db, ARCHIVE: archive } = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };

async function fixture(): Promise<{ ownerId: string; recordId: string; photoKey: string }> {
  const ownerId = crypto.randomUUID();
  const recordId = crypto.randomUUID();
  const photoKey = `personal/${ownerId}/${recordId}/${crypto.randomUUID()}`;
  await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,disabled,created_at) VALUES(?,?,1,1)')
    .bind(ownerId, crypto.randomUUID()).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(ownerId).run();
  await db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,
    initial_operation,metadata,photo_key,photo_bytes,quota_bytes,deleted)
    VALUES(?,?,1,'synthetic','synthetic',?,?,?,?,0)`)
    .bind(ownerId, recordId, new Uint8Array([1]).buffer, photoKey, 1, 2).run();
  return { ownerId, recordId, photoKey };
}

it('reconciles current photo references without altering either store', async () => {
  const { ownerId, photoKey } = await fixture();
  await archive.put(photoKey, new Uint8Array([1]));
  const result = await reconcileFencedPrimaryInventory(db, archive, ownerId);
  expect(result).toMatchObject({ ownerId, records: 1, photos: 1, photoKeys: [photoKey] });
  expect((await archive.head(photoKey))?.size).toBe(1);
  expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?').bind(ownerId).first())
    .toMatchObject({ disabled: 1 });
});

it('rejects a missing photo and an unreferenced R2 object', async () => {
  const { ownerId, recordId, photoKey } = await fixture();
  await expect(reconcileFencedPrimaryInventory(db, archive, ownerId))
    .rejects.toMatchObject({ code: 'PRIMARY_INVENTORY_UNAVAILABLE' });
  await archive.put(photoKey, new Uint8Array([1]));
  const orphan = `personal/${ownerId}/${recordId}/${crypto.randomUUID()}`;
  await archive.put(orphan, new Uint8Array([2]));
  await expect(reconcileFencedPrimaryInventory(db, archive, ownerId))
    .rejects.toMatchObject({ code: 'PRIMARY_INVENTORY_UNAVAILABLE' });
  expect((await reconcileFencedPurgePrimaryInventory(db, archive, ownerId)).photoKeys)
    .toEqual([orphan, photoKey].sort());
});

it('does not treat a missing referenced photo as an acceptable purge orphan', async () => {
  const { ownerId } = await fixture();
  await expect(reconcileFencedPurgePrimaryInventory(db, archive, ownerId))
    .rejects.toMatchObject({ code: 'PRIMARY_INVENTORY_UNAVAILABLE' });
});

it('rejects DB inventory changes while the R2 listing is in progress', async () => {
  const { ownerId, photoKey } = await fixture();
  await archive.put(photoKey, new Uint8Array([1]));
  const changingBucket = { list: async (options: R2ListOptions) => {
    const page = await archive.list(options);
    await db.prepare('UPDATE pa_inventory SET generation=generation+1 WHERE owner_id=?')
      .bind(ownerId).run();
    return page;
  } } as R2Bucket;
  await expect(reconcileFencedPrimaryInventory(db, changingBucket, ownerId))
    .rejects.toMatchObject({ code: 'PRIMARY_INVENTORY_UNAVAILABLE' });
});

it('rejects a cursor cycle even when each adjacent R2 page has a different token', async () => {
  const { ownerId } = await fixture();
  const cyclingBucket = { list: async (options: R2ListOptions) => ({
    objects: [], delimitedPrefixes: [], truncated: true,
    cursor: options.cursor === 'first' ? 'second' : 'first',
  }) } as unknown as R2Bucket;
  await expect(reconcileFencedPrimaryInventory(db, cyclingBucket, ownerId))
    .rejects.toMatchObject({ code: 'PRIMARY_INVENTORY_UNAVAILABLE' });
});
