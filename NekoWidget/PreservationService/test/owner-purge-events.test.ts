import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';

const db = (env as unknown as { DB: D1Database }).DB;
const dueAt = 1_800_000_000_000;
const recordedAt = dueAt + 1_000;
const manifest = 'a'.repeat(64);

async function owner(): Promise<string> {
  const ownerId = crypto.randomUUID();
  await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
    .bind(ownerId, crypto.randomUUID(), dueAt - 400 * 86_400_000).run();
  return ownerId;
}

async function insert(ownerId: string, intentId: string,
  stage: 'prepared' | 'aborted' | 'erasing' | 'completed',
  options: { epoch?: number; manifest?: string | null; at?: number; key?: string } = {}): Promise<void> {
  await db.prepare(`INSERT INTO pa_owner_purge_events(owner_id,intent_id,stage,owner_epoch,
    inventory_generation,retention_episode,retention_revision,due_at,recorded_at,
    manifest_sha256,s3_object_key,s3_version_id,s3_sha256,s3_bytes)
    VALUES(?,?,?,?,8,1,4,?,?,?,?,'version-v1',?,100)`)
    .bind(ownerId, intentId, stage, options.epoch ?? 2, dueAt,
      options.at ?? recordedAt, options.manifest === undefined
        ? (stage === 'prepared' || stage === 'aborted' ? null : manifest)
        : options.manifest,
      options.key ?? `purge/v1/${ownerId}/${intentId}/${stage}`, 'b'.repeat(64)).run();
}

it('records only a consistent prepared-to-erasing-to-completed sequence', async () => {
  const ownerId = await owner();
  const intentId = crypto.randomUUID();
  await expect(insert(ownerId, intentId, 'erasing')).rejects.toThrow();
  await insert(ownerId, intentId, 'prepared');
  await expect(insert(ownerId, intentId, 'prepared')).rejects.toThrow();
  await expect(insert(ownerId, intentId, 'erasing', { epoch: 3 })).rejects.toThrow();
  await expect(insert(ownerId, intentId, 'erasing', { key: 'purge/v1/wrong' })).rejects.toThrow();
  await expect(insert(ownerId, intentId, 'completed')).rejects.toThrow();
  await insert(ownerId, intentId, 'erasing', { at: recordedAt + 1 });
  await expect(insert(ownerId, intentId, 'aborted')).rejects.toThrow();
  await expect(insert(ownerId, intentId, 'completed', { manifest: 'c'.repeat(64) }))
    .rejects.toThrow();
  await insert(ownerId, intentId, 'completed', { at: recordedAt + 2 });
  expect((await db.prepare('SELECT stage FROM pa_owner_purge_events WHERE owner_id=?')
    .bind(ownerId).all<{ stage: string }>()).results.map(row => row.stage).sort())
    .toEqual(['completed', 'erasing', 'prepared']);
  await expect(db.prepare(`UPDATE pa_owner_purge_events SET s3_version_id='changed'
    WHERE owner_id=?`).bind(ownerId).run()).rejects.toThrow();
});

it('allows pre-erasure abort but never an erasing event afterward', async () => {
  const ownerId = await owner();
  const intentId = crypto.randomUUID();
  await expect(insert(crypto.randomUUID(), crypto.randomUUID(), 'prepared')).rejects.toThrow();
  await insert(ownerId, intentId, 'prepared');
  await insert(ownerId, intentId, 'aborted', { at: recordedAt + 1 });
  await expect(insert(ownerId, intentId, 'erasing', { at: recordedAt + 2 }))
    .rejects.toThrow();
  await db.prepare('DELETE FROM pa_owner_recovery_generations WHERE owner_id=?')
    .bind(ownerId).run();
  await db.prepare('DELETE FROM pa_owners WHERE owner_id=?').bind(ownerId).run();
  expect((await db.prepare('SELECT count(*) AS n FROM pa_owner_purge_events WHERE owner_id=?')
    .bind(ownerId).first<{ n: number }>())?.n).toBe(2);
  // Cleanup requires a separately reviewed age-gated path; direct DELETE
  // must not silently discard this anti-resurrection reference.
  await expect(db.prepare('DELETE FROM pa_owner_purge_events WHERE owner_id=?')
    .bind(ownerId).run()).rejects.toThrow();
  expect((await db.prepare('SELECT count(*) AS n FROM pa_owner_purge_events WHERE owner_id=?')
    .bind(ownerId).first<{ n: number }>())?.n).toBe(2);
});
