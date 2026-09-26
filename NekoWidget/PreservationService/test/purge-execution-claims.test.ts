import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';

const db = (env as unknown as { DB: D1Database }).DB;
const day = 86_400_000;
const now = 1_800_000_000_000;

async function fixture() {
  const ownerId = crypto.randomUUID();
  const intentId = crypto.randomUUID();
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,
    created_at,purge_fence_id) VALUES(?,?,1,1,?,?)`)
    .bind(ownerId, crypto.randomUUID(), now - 400 * day, intentId).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(ownerId).run();
  await db.prepare(`INSERT INTO pa_purge_fences(fence_id,owner_id,state,owner_epoch,
    inventory_generation,retention_episode,retention_revision,due_at,delivered_at,
    delivery_event_id,contact_updated_at,created_at,updated_at,lease_expires_at)
    VALUES(?,?,'fenced',1,0,1,1,?,?,?,?,?,?,?)`)
    .bind(intentId, ownerId, now - day, now - 31 * day,
      `delivery-${crypto.randomUUID()}`, now - 40 * day, now, now, now + 10 * 60_000).run();
  const append = async (stage: 'prepared' | 'aborted' | 'erasing' | 'completed',
    recordedAt: number, manifest: string | null = null) => db.prepare(`INSERT INTO pa_owner_purge_events(
      owner_id,intent_id,stage,owner_epoch,inventory_generation,retention_episode,
      retention_revision,due_at,recorded_at,manifest_sha256,s3_object_key,s3_version_id,
      s3_sha256,s3_bytes) VALUES(?,?,?,1,0,1,1,?,?,?,?,?,?,1)`)
      .bind(ownerId, intentId, stage, now - day, recordedAt, manifest,
        `purge/v1/${ownerId}/${intentId}/${stage}`, `v-${stage}`, 'a'.repeat(64)).run();
  const claim = (state: 'aborting' | 'erasing', manifest: string | null = null,
    claimedAt = now + 1) =>
    db.prepare(`INSERT INTO pa_purge_execution_claims(owner_id,intent_id,state,
      owner_epoch,inventory_generation,retention_episode,retention_revision,due_at,
      manifest_sha256,claimed_at) VALUES(?,?,?,1,0,1,1,?,?,?)`)
      .bind(ownerId, intentId, state, now - day, manifest, claimedAt).run();
  return { ownerId, intentId, append, claim };
}

it('requires a prepared external reference before claiming either branch', async () => {
  const f = await fixture();
  await expect(f.claim('aborting')).rejects.toThrow();
  await f.append('prepared', now);
  await f.claim('aborting');
  expect(await db.prepare(`SELECT state FROM pa_purge_execution_claims
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.intentId).first())
    .toMatchObject({ state: 'aborting' });
  expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ disabled: 1 });
  await expect(db.prepare(`UPDATE pa_purge_execution_claims
    SET state='aborted',finished_at=? WHERE owner_id=? AND intent_id=?`)
    .bind(now + 3, f.ownerId, f.intentId).run()).rejects.toThrow();
  await f.append('aborted', now + 2);
  await db.prepare(`UPDATE pa_purge_execution_claims
    SET state='aborted',finished_at=? WHERE owner_id=? AND intent_id=?`)
    .bind(now + 3, f.ownerId, f.intentId).run();
  await expect(db.prepare('DELETE FROM pa_purge_execution_claims WHERE owner_id=?')
    .bind(f.ownerId).run()).rejects.toThrow();
});

it('rejects erasure after lease expiry but still permits a safe abort', async () => {
  const f = await fixture();
  await f.append('prepared', now);
  await expect(db.prepare(`INSERT INTO pa_purge_execution_claims(owner_id,intent_id,state,
    owner_epoch,inventory_generation,retention_episode,retention_revision,due_at,
    manifest_sha256,claimed_at) VALUES(?,?,'erasing',1,0,1,1,?,?,?)`)
    .bind(f.ownerId, f.intentId, now - day, 'b'.repeat(64),
      now + 11 * 60_000).run()).rejects.toThrow();
  await db.prepare(`INSERT INTO pa_purge_execution_claims(owner_id,intent_id,state,
    owner_epoch,inventory_generation,retention_episode,retention_revision,due_at,
    manifest_sha256,claimed_at) VALUES(?,?,'aborting',1,0,1,1,?,NULL,?)`)
    .bind(f.ownerId, f.intentId, now - day, now + 11 * 60_000).run();
  expect(await db.prepare(`SELECT state FROM pa_purge_execution_claims
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.intentId).first())
    .toMatchObject({ state: 'aborting' });
});

it('cannot complete an erasure claim without matching prepared, erasing and completed events', async () => {
  const f = await fixture();
  const manifest = 'b'.repeat(64);
  await db.prepare(`INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at)
    VALUES(?,?,?)`).bind(f.ownerId, crypto.randomUUID(), now - 400 * day).run();
  await expect(db.prepare('DELETE FROM pa_membership_links WHERE owner_id=?')
    .bind(f.ownerId).run()).rejects.toThrow();
  await f.append('prepared', now);
  await expect(f.claim('erasing', manifest)).rejects.toThrow();
  await db.prepare(`INSERT INTO pa_purge_manifests(owner_id,intent_id,owner_epoch,
    inventory_generation,record_digest,records,r2_count,s3_count,r2_bytes,s3_bytes,
    chunk_count,sha256,created_at) VALUES(?,?,1,0,?,0,0,0,0,0,0,?,?)`)
    .bind(f.ownerId, f.intentId, 'a'.repeat(64), manifest, now + 1).run();
  await f.append('erasing', now + 2, manifest);
  await expect(f.claim('erasing', manifest, now + 3)).rejects.toThrow();
  await db.prepare(`UPDATE pa_purge_manifests SET sealed_at=?
    WHERE owner_id=? AND intent_id=?`).bind(now + 2, f.ownerId, f.intentId).run();
  await expect(f.claim('erasing', manifest, now + 3)).rejects.toThrow();
  await db.prepare(`INSERT INTO pa_purge_manifest_remote_refs(owner_id,intent_id,
    ordinal,s3_object_key,s3_version_id,s3_sha256,s3_bytes,confirmed_at)
    VALUES(?,?,-1,?,'header-v1',?,100,?)`)
    .bind(f.ownerId, f.intentId,
      `purge-plan/v1/${f.ownerId}/${f.intentId}/header`, 'c'.repeat(64), now + 2).run();
  await db.prepare(`INSERT INTO pa_purge_manifest_remote_seals(owner_id,intent_id,
    root_sha256,sealed_at) VALUES(?,?,?,?)`)
    .bind(f.ownerId, f.intentId, manifest, now + 2).run();
  await f.claim('erasing', manifest, now + 3);
  expect(await db.prepare('SELECT COUNT(*) AS n FROM pa_purge_d1_erasing_authority WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ n: 1 });
  await db.prepare('DELETE FROM pa_membership_links WHERE owner_id=?').bind(f.ownerId).run();
  expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ disabled: 1 });
  await expect(db.prepare('DELETE FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).run()).rejects.toThrow(); // child rows still exist
  await db.prepare('DELETE FROM pa_owner_recovery_generations WHERE owner_id=?')
    .bind(f.ownerId).run();
  await db.prepare('DELETE FROM pa_inventory WHERE owner_id=?').bind(f.ownerId).run();
  await db.prepare('DELETE FROM pa_purge_fences WHERE owner_id=?').bind(f.ownerId).run();
  await db.prepare('DELETE FROM pa_owners WHERE owner_id=?').bind(f.ownerId).run();
  expect(await db.prepare('SELECT owner_id FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).first()).toBeNull();
  await expect(db.prepare(`UPDATE pa_purge_execution_claims
    SET state='completed',finished_at=? WHERE owner_id=? AND intent_id=?`)
    .bind(now + 4, f.ownerId, f.intentId).run()).rejects.toThrow();
  await f.append('completed', now + 3, manifest);
  await db.prepare(`UPDATE pa_purge_execution_claims
    SET state='completed',finished_at=? WHERE owner_id=? AND intent_id=?`)
    .bind(now + 4, f.ownerId, f.intentId).run();
  expect(await db.prepare(`SELECT state,manifest_sha256 FROM pa_purge_execution_claims
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.intentId).first())
    .toMatchObject({ state: 'completed', manifest_sha256: manifest });
  expect(await db.prepare('SELECT COUNT(*) AS n FROM pa_purge_d1_erasing_authority WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ n: 0 });
  await expect(db.prepare(`UPDATE pa_purge_execution_claims SET state='aborted'
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.intentId).run()).rejects.toThrow();
});
