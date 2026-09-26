import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { inspectOwnerD1Residue, ownerContentTables,
  ownerCursorTables, ownerD1DeleteOrder, purgeWorkTables } from '../src/owner-d1-residue';

const db = (env as unknown as { DB: D1Database }).DB;

it('classifies every D1 table with an owner_id column', async () => {
  const rows = (await db.prepare(`SELECT m.name FROM sqlite_master m
    WHERE m.type='table' AND m.name LIKE 'pa_%'
      AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) p WHERE p.name='owner_id')
    ORDER BY m.name`).all<{ name: string }>()).results.map(row => row.name);
  const classified = [...ownerContentTables, ...purgeWorkTables,
    ...ownerCursorTables].sort();
  expect(classified).toEqual(rows);
  expect(new Set(classified).size).toBe(classified.length);
});

it('keeps every owner row in child-before-parent FK deletion order', async () => {
  const sequence = [...ownerD1DeleteOrder];
  expect(sequence.filter(name => name !== 'pa_purge_fences').sort())
    .toEqual([...ownerContentTables].sort());
  expect(new Set(sequence).size).toBe(sequence.length);
  for (let child = 0; child < sequence.length; child++) {
    const references = (await db.prepare(`PRAGMA foreign_key_list(${sequence[child]})`)
      .all<{ table: string }>()).results;
    for (const reference of references) {
      const parent = sequence.indexOf(reference.table as typeof sequence[number]);
      if (parent >= 0) expect(child, `${sequence[child]} must precede ${reference.table}`)
        .toBeLessThan(parent);
    }
  }
});

it('counts every owner row, photo cleanup key and singleton cursor without reading content', async () => {
  const ownerId = crypto.randomUUID();
  const otherId = crypto.randomUUID();
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,created_at)
    VALUES(?,?,1)`).bind(ownerId, crypto.randomUUID()).run();
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,created_at)
    VALUES(?,?,1)`).bind(otherId, crypto.randomUUID()).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(ownerId).run();
  await db.prepare(`INSERT INTO pa_pending_deletes(object_key,created_at)
    VALUES(?,1)`).bind(`personal/${ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`).run();
  await db.prepare(`UPDATE pa_expiry_review_cursor SET owner_id=? WHERE id=1`)
    .bind(ownerId).run();
  const report = await inspectOwnerD1Residue(db, ownerId);
  expect(report.content.pa_owners).toBe(1);
  expect(report.content.pa_inventory).toBe(1);
  expect(report.content.pa_owner_recovery_generations).toBe(1);
  expect(report.contentTotal).toBe(3);
  expect(report.purgeWorkTotal).toBe(0);
  expect(report.pendingPhotoDeletes).toBe(1);
  expect(report.ownerCursors.pa_expiry_review_cursor).toBe(1);
  expect(report.ownerCursors.pa_notice_scan_cursor).toBe(0);
  expect(report.recoveryRepairCursors.pa_recovery_repair_cursor).toBe(0);
  await expect(inspectOwnerD1Residue(db, 'wrong-owner'))
    .rejects.toMatchObject({ code: 'OWNER_D1_RESIDUE_UNAVAILABLE' });
});
