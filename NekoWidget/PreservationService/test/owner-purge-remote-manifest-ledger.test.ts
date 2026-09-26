import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { buildOwnerPurgeManifest } from '../src/owner-purge-manifest';
import { OwnerPurgeManifestLedger } from '../src/owner-purge-manifest-ledger';
import { OwnerPurgeRemoteManifestLedger } from '../src/owner-purge-remote-manifest-ledger';
import type { PurgeFence } from '../src/owner-purge-fence';
import type { S3PurgeManifestStore } from '../src/s3-purge-manifest';

const db = (env as unknown as { DB: D1Database }).DB;
const now = 1_800_000_000_000;

it('requires every exact S3 reference and a full external audit before sealing', async () => {
  const ownerId = crypto.randomUUID();
  const intentId = crypto.randomUUID();
  const photoKey = `personal/${ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`;
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,
    created_at,purge_fence_id) VALUES(?,?,2,1,?,?)`)
    .bind(ownerId, crypto.randomUUID(), now - 1_000_000, intentId).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id,generation) VALUES(?,4)')
    .bind(ownerId).run();
  await db.prepare(`INSERT INTO pa_purge_fences(fence_id,owner_id,state,owner_epoch,
    inventory_generation,retention_episode,retention_revision,due_at,delivered_at,
    delivery_event_id,contact_updated_at,created_at,updated_at,lease_expires_at)
    VALUES(?,?,'fenced',2,4,1,1,?,?,?,?,?,?,?)`)
    .bind(intentId, ownerId, now - 100_000, now - 500_000,
      `delivery-${crypto.randomUUID()}`, now - 600_000,
      now, now, now + 600_000).run();
  const manifest = await buildOwnerPurgeManifest({ ownerId, fenceId: intentId,
    ownerEpoch: 2, inventoryGeneration: 4 } as PurgeFence,
  { ownerId, epoch: 2, generation: 4, records: 1, photos: 1,
    photoKeys: [photoKey], recordDigest: 'a'.repeat(64) },
  { ownerId, r2Objects: [{ key: photoKey, version: 'r2-v1', bytes: 8 }],
    r2Bytes: 8, s3Versions: [], s3VersionBytes: 0, s3DeleteMarkers: 0 });
  const local = new OwnerPurgeManifestLedger(db);
  await local.open(manifest, now + 1);
  await local.appendChunk(manifest, 0);
  await local.seal(manifest, now + 2);
  let remoteComplete = false;
  const store = {
    putChunk: async (_m: unknown, index: number) => ({
      key: `purge-plan/v1/${ownerId}/${intentId}/chunk/${String(index).padStart(6, '0')}`,
      versionId: 'chunk-v1', sha256: manifest.chunks[index]!.sha256,
      bytes: manifest.chunks[index]!.bytes }),
    putHeader: async () => ({ key: `purge-plan/v1/${ownerId}/${intentId}/header`,
      versionId: 'header-v1', sha256: 'b'.repeat(64), bytes: 100 }),
    loadPublished: async () => {
      if (!remoteComplete) throw Error('S3 plan incomplete');
      return manifest;
    },
    readExact: async () => new Uint8Array(1),
  } as unknown as S3PurgeManifestStore;
  const remote = new OwnerPurgeRemoteManifestLedger(db, store);
  await remote.copyHeader(manifest, now + 3);
  await expect(remote.seal(manifest, now + 4)).rejects.toMatchObject({
    code: 'PURGE_REMOTE_MANIFEST_UNAVAILABLE' });
  await remote.copyChunk(manifest, 0, now + 3);
  await remote.copyChunk(manifest, 0, now + 3);
  await expect(remote.seal(manifest, now + 4)).rejects.toMatchObject({
    code: 'PURGE_REMOTE_MANIFEST_UNAVAILABLE' });
  remoteComplete = true;
  await remote.seal(manifest, now + 4);
  await remote.seal(manifest, now + 5);
  expect(await db.prepare(`SELECT root_sha256 FROM pa_purge_manifest_remote_seals
    WHERE owner_id=? AND intent_id=?`).bind(ownerId, intentId).first())
    .toMatchObject({ root_sha256: manifest.sha256 });
});
