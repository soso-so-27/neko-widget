import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { buildOwnerPurgeManifest } from '../src/owner-purge-manifest';
import { OwnerPurgeManifestLedger } from '../src/owner-purge-manifest-ledger';
import type { PurgeFence } from '../src/owner-purge-fence';

const db = (env as unknown as { DB: D1Database }).DB;
const now = 1_800_000_000_000;
const day = 86_400_000;

async function fixture() {
  const ownerId = crypto.randomUUID();
  const fenceId = crypto.randomUUID();
  const recordId = crypto.randomUUID();
  const photoKey = `personal/${ownerId}/${recordId}/${crypto.randomUUID()}`;
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,
    created_at,purge_fence_id) VALUES(?,?,2,1,?,?)`)
    .bind(ownerId, crypto.randomUUID(), now - 400 * day, fenceId).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id,generation) VALUES(?,4)')
    .bind(ownerId).run();
  await db.prepare(`INSERT INTO pa_purge_fences(fence_id,owner_id,state,owner_epoch,
    inventory_generation,retention_episode,retention_revision,due_at,delivered_at,
    delivery_event_id,contact_updated_at,created_at,updated_at,lease_expires_at)
    VALUES(?,?,'fenced',2,4,1,1,?,?,?,?,?,?,?)`)
    .bind(fenceId, ownerId, now - day, now - 31 * day,
      `delivery-${crypto.randomUUID()}`, now - 32 * day,
      now, now, now + 600_000).run();
  const fence = { ownerId, fenceId, ownerEpoch: 2, inventoryGeneration: 4 } as PurgeFence;
  const manifest = await buildOwnerPurgeManifest(fence,
    { ownerId, epoch: 2, generation: 4, records: 1, photos: 1,
      photoKeys: [photoKey], recordDigest: 'a'.repeat(64) },
    { ownerId, r2Objects: [{ key: photoKey, version: 'r2-v1', bytes: 8 }],
      r2Bytes: 8, s3Versions: [], s3VersionBytes: 0, s3DeleteMarkers: 0 });
  return { ownerId, fenceId, manifest };
}

it('persists each exact chunk, seals only a complete plan and gates erasing claims', async () => {
  const f = await fixture();
  const ledger = new OwnerPurgeManifestLedger(db);
  await ledger.open(f.manifest, now + 1);
  await ledger.open(f.manifest, now + 10);
  await expect(ledger.seal(f.manifest, now + 2)).rejects.toMatchObject({
    code: 'OWNER_PURGE_MANIFEST_LEDGER_UNAVAILABLE' });
  await ledger.appendChunk(f.manifest, 0);
  await ledger.appendChunk(f.manifest, 0);
  await ledger.seal(f.manifest, now + 2);
  await ledger.seal(f.manifest, now + 10);
  await expect(db.prepare(`UPDATE pa_purge_manifest_chunks SET payload='bad'
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.fenceId).run()).rejects.toThrow();
  await expect(db.prepare(`DELETE FROM pa_purge_manifest_chunks
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.fenceId).run()).rejects.toThrow();
  const append = async (stage: 'prepared' | 'erasing', recordedAt: number,
    hash: string | null) => db.prepare(`INSERT INTO pa_owner_purge_events(owner_id,intent_id,
      stage,owner_epoch,inventory_generation,retention_episode,retention_revision,
      due_at,recorded_at,manifest_sha256,s3_object_key,s3_version_id,s3_sha256,s3_bytes)
      VALUES(?,?,?,2,4,1,1,?,?,?,?,?,?,1)`)
      .bind(f.ownerId, f.fenceId, stage, now - day, recordedAt, hash,
        `purge/v1/${f.ownerId}/${f.fenceId}/${stage}`, `v-${stage}`,
        'b'.repeat(64)).run();
  await append('prepared', now, null);
  const claim = () => db.prepare(`INSERT INTO pa_purge_execution_claims(owner_id,
    intent_id,state,owner_epoch,inventory_generation,retention_episode,
    retention_revision,due_at,manifest_sha256,claimed_at)
    VALUES(?,?,'erasing',2,4,1,1,?,?,?)`)
    .bind(f.ownerId, f.fenceId, now - day, f.manifest.sha256, now + 4).run();
  await expect(claim()).rejects.toThrow();
  await append('erasing', now + 3, f.manifest.sha256);
  await expect(claim()).rejects.toThrow();
  const remote = (ordinal: number, key: string, sha256: string, bytes: number) =>
    db.prepare(`INSERT INTO pa_purge_manifest_remote_refs(owner_id,intent_id,ordinal,
      s3_object_key,s3_version_id,s3_sha256,s3_bytes,confirmed_at)
      VALUES(?,?,?,?,'synthetic-version',?,?,?)`)
      .bind(f.ownerId, f.fenceId, ordinal, key, sha256, bytes, now + 2).run();
  await expect(remote(0, `purge-plan/v1/${f.ownerId}/${f.fenceId}/chunk/000001`,
    f.manifest.chunks[0]!.sha256, f.manifest.chunks[0]!.bytes)).rejects.toThrow();
  await remote(0, `purge-plan/v1/${f.ownerId}/${f.fenceId}/chunk/000000`,
    f.manifest.chunks[0]!.sha256, f.manifest.chunks[0]!.bytes);
  const seal = () => db.prepare(`INSERT INTO pa_purge_manifest_remote_seals
    (owner_id,intent_id,root_sha256,sealed_at) VALUES(?,?,?,?)`)
    .bind(f.ownerId, f.fenceId, f.manifest.sha256, now + 3).run();
  await expect(seal()).rejects.toThrow();
  await remote(-1, `purge-plan/v1/${f.ownerId}/${f.fenceId}/header`,
    'c'.repeat(64), 100);
  await seal();
  await expect(db.prepare(`UPDATE pa_purge_manifest_remote_refs SET s3_version_id='other'
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.fenceId).run()).rejects.toThrow();
  await claim();
  expect(await db.prepare(`SELECT state,manifest_sha256 FROM pa_purge_execution_claims
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.fenceId).first())
    .toMatchObject({ state: 'erasing', manifest_sha256: f.manifest.sha256 });
});

it('refuses a plan whose claimed root or chunk bytes were changed', async () => {
  const f = await fixture();
  const ledger = new OwnerPurgeManifestLedger(db);
  await expect(ledger.open({ ...f.manifest, sha256: 'c'.repeat(64) }, now + 1))
    .rejects.toMatchObject({ code: 'OWNER_PURGE_MANIFEST_LEDGER_UNAVAILABLE' });
  await ledger.open(f.manifest, now + 1);
  const chunks = f.manifest.chunks.map(chunk => ({ ...chunk, bytes: chunk.bytes + 1 }));
  await expect(ledger.appendChunk({ ...f.manifest, chunks }, 0))
    .rejects.toMatchObject({ code: 'OWNER_PURGE_MANIFEST_LEDGER_UNAVAILABLE' });
});
