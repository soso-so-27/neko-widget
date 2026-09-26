import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';

const db = (env as unknown as { DB: D1Database }).DB;
const now = 1_800_000_000_000;
const day = 86_400_000;

it('requires external erasing proof before child-first D1 owner deletion under snapshot policy', async () => {
  await db.prepare(`UPDATE pa_recovery_write_policy SET owner_snapshot_required=1
    WHERE singleton=1`).run();
  try {
    const owner = crypto.randomUUID();
    const intent = crypto.randomUUID();
    const root = 'b'.repeat(64);
    await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,
      created_at,purge_fence_id) VALUES(?,?,1,1,?,?)`)
      .bind(owner, crypto.randomUUID(), now - 400 * day, intent).run();
    await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(owner).run();
    await db.prepare(`INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at)
      VALUES(?,?,?)`).bind(owner, crypto.randomUUID(), now - 400 * day).run();
    await db.prepare(`INSERT INTO pa_purge_fences(fence_id,owner_id,state,owner_epoch,
      inventory_generation,retention_episode,retention_revision,due_at,delivered_at,
      delivery_event_id,contact_updated_at,created_at,updated_at,lease_expires_at)
      VALUES(?,?,'fenced',1,0,1,1,?,?,?,?,?,?,?)`)
      .bind(intent, owner, now - day, now - 31 * day, `delivery-${crypto.randomUUID()}`,
        now - 40 * day, now, now, now + 10 * 60_000).run();
    const event = async (stage: 'prepared' | 'erasing' | 'completed', at: number,
      digest: string | null) => db.prepare(`INSERT INTO pa_owner_purge_events(
      owner_id,intent_id,stage,owner_epoch,inventory_generation,retention_episode,
      retention_revision,due_at,recorded_at,manifest_sha256,s3_object_key,
      s3_version_id,s3_sha256,s3_bytes) VALUES(?,?,?,1,0,1,1,?,?,?,?,?,?,1)`)
      .bind(owner, intent, stage, now - day, at, digest,
        `purge/v1/${owner}/${intent}/${stage}`, `v-${stage}`, 'a'.repeat(64)).run();
    await event('prepared', now, null);
    await expect(db.prepare('DELETE FROM pa_membership_links WHERE owner_id=?')
      .bind(owner).run()).rejects.toThrow();
    await expect(db.prepare('DELETE FROM pa_purge_fences WHERE owner_id=?')
      .bind(owner).run()).rejects.toThrow();
    await db.prepare(`INSERT INTO pa_purge_manifests(owner_id,intent_id,owner_epoch,
      inventory_generation,record_digest,records,r2_count,s3_count,r2_bytes,s3_bytes,
      chunk_count,sha256,created_at,sealed_at) VALUES(?,?,1,0,?,0,0,0,0,0,0,?,?,?)`)
      .bind(owner, intent, 'a'.repeat(64), root, now, now + 1).run();
    await db.prepare(`INSERT INTO pa_purge_manifest_remote_refs(owner_id,intent_id,
      ordinal,s3_object_key,s3_version_id,s3_sha256,s3_bytes,confirmed_at)
      VALUES(?,?,-1,?,'header-v1',?,100,?)`)
      .bind(owner, intent, `purge-plan/v1/${owner}/${intent}/header`,
        'c'.repeat(64), now + 1).run();
    await db.prepare(`INSERT INTO pa_purge_manifest_remote_seals(owner_id,intent_id,
      root_sha256,sealed_at) VALUES(?,?,?,?)`)
      .bind(owner, intent, root, now + 1).run();
    await event('erasing', now + 2, root);
    await expect(db.prepare('DELETE FROM pa_membership_links WHERE owner_id=?')
      .bind(owner).run()).rejects.toThrow();
    await db.prepare(`INSERT INTO pa_purge_execution_claims(owner_id,intent_id,state,
      owner_epoch,inventory_generation,retention_episode,retention_revision,due_at,
      manifest_sha256,claimed_at) VALUES(?,?,'erasing',1,0,1,1,?,?,?)`)
      .bind(owner, intent, now - day, root, now + 3).run();
    expect(await db.prepare('SELECT COUNT(*) AS n FROM pa_purge_d1_erasing_authority WHERE owner_id=?')
      .bind(owner).first()).toMatchObject({ n: 1 });
    await db.prepare('DELETE FROM pa_membership_links WHERE owner_id=?').bind(owner).run();
    await db.prepare('DELETE FROM pa_owner_recovery_generations WHERE owner_id=?')
      .bind(owner).run();
    await db.prepare('DELETE FROM pa_inventory WHERE owner_id=?').bind(owner).run();
    await db.prepare('DELETE FROM pa_purge_fences WHERE owner_id=?').bind(owner).run();
    await db.prepare('DELETE FROM pa_owners WHERE owner_id=?').bind(owner).run();
    expect(await db.prepare('SELECT owner_id FROM pa_owners WHERE owner_id=?')
      .bind(owner).first()).toBeNull();
    await event('completed', now + 4, root);
    await db.prepare(`UPDATE pa_purge_execution_claims SET state='completed',finished_at=?
      WHERE owner_id=? AND intent_id=?`).bind(now + 5, owner, intent).run();
    expect(await db.prepare(`SELECT state FROM pa_purge_execution_claims
      WHERE owner_id=? AND intent_id=?`).bind(owner, intent).first())
      .toMatchObject({ state: 'completed' });
  } finally {
    await db.prepare(`UPDATE pa_recovery_write_policy SET owner_snapshot_required=0
      WHERE singleton=1`).run();
  }
});
