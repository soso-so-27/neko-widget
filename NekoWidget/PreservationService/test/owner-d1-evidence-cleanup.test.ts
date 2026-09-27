import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { OwnerD1EvidenceCleanup } from '../src/owner-d1-evidence-cleanup';
import { OwnerD1Eraser } from '../src/owner-d1-erase';
import { OwnerPurgeCompletion } from '../src/owner-purge-completion';
import { OwnerPurgeIntentLedger } from '../src/owner-purge-intent-ledger';
import { inspectOwnerD1Residue } from '../src/owner-d1-residue';
import type { PurgeIntentEvent, PurgeIntentReference,
  S3PurgeIntentStore } from '../src/s3-purge-intent';
import type { S3PurgeManifestStore } from '../src/s3-purge-manifest';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';

const db = (env as unknown as { DB: D1Database }).DB;
const day = 86_400_000;
const root = 'b'.repeat(64);
const hash = 'a'.repeat(64);

async function completedOwner() {
  const ownerId = crypto.randomUUID();
  const intentId = crypto.randomUUID();
  const otherOwnerId = crypto.randomUUID();
  const now = Date.now();
  const dueAt = now - 400 * day;
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,
    created_at,purge_fence_id) VALUES(?,?,1,1,?,?)`)
    .bind(ownerId, crypto.randomUUID(), now - 400 * day, intentId).run();
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,created_at)
    VALUES(?,?,?)`).bind(otherOwnerId, crypto.randomUUID(), now).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(ownerId).run();
  await db.prepare(`INSERT INTO pa_membership_links(owner_id,billing_account_id,
    created_at) VALUES(?,?,?)`).bind(ownerId, crypto.randomUUID(), now).run();
  await db.prepare(`INSERT INTO pa_purge_fences(fence_id,owner_id,state,
    owner_epoch,inventory_generation,retention_episode,retention_revision,
    due_at,delivered_at,delivery_event_id,contact_updated_at,
    created_at,updated_at,lease_expires_at)
    VALUES(?,?,'fenced',1,0,1,1,?,?,?,?,?,?,?)`)
    .bind(intentId, ownerId, dueAt, now - 31 * day,
      `delivery-${crypto.randomUUID()}`, now - 40 * day,
      now, now, now + 600_000).run();
  await db.prepare(`INSERT INTO pa_purge_manifests(owner_id,intent_id,
    owner_epoch,inventory_generation,record_digest,records,r2_count,s3_count,
    r2_bytes,s3_bytes,chunk_count,sha256,created_at,sealed_at)
    VALUES(?,?,1,0,?,0,0,0,0,0,0,?,?,?)`)
    .bind(ownerId, intentId, hash, root, now, now + 1).run();
  await db.prepare(`INSERT INTO pa_purge_manifest_remote_refs(owner_id,
    intent_id,ordinal,s3_object_key,s3_version_id,s3_sha256,s3_bytes,
    confirmed_at) VALUES(?,?,-1,?,'header-v1',?,100,?)`)
    .bind(ownerId, intentId,
      `purge-plan/v1/${ownerId}/${intentId}/header`, hash, now + 1).run();
  await db.prepare(`INSERT INTO pa_purge_manifest_remote_seals(owner_id,
    intent_id,root_sha256,sealed_at) VALUES(?,?,?,?)`)
    .bind(ownerId, intentId, root, now + 1).run();
  const events: PurgeIntentEvent[] = [];
  const ref = (stage: PurgeIntentEvent['stage']): PurgeIntentReference => ({
    key: `purge/v1/${ownerId}/${intentId}/${stage}`,
    versionId: `v-${stage}`, sha256: hash, bytes: 100,
  });
  for (const [stage, offset] of [['prepared', 0], ['erasing', 2]] as const) {
    await db.prepare(`INSERT INTO pa_owner_purge_events(owner_id,intent_id,
      stage,owner_epoch,inventory_generation,retention_episode,
      retention_revision,due_at,recorded_at,manifest_sha256,
      s3_object_key,s3_version_id,s3_sha256,s3_bytes)
      VALUES(?,?,?,1,0,1,1,?,?,?,?,?,?,100)`)
      .bind(ownerId, intentId, stage, dueAt, now + offset,
        stage === 'erasing' ? root : null,
        ref(stage).key, ref(stage).versionId, hash).run();
    events.push({ version: 1, ownerId, intentId, stage, ownerEpoch: 1,
      inventoryGeneration: 0, retentionEpisode: 1, retentionRevision: 1,
      dueAt, recordedAt: now + offset,
      manifestSha256: stage === 'erasing' ? root : null });
  }
  await db.prepare(`INSERT INTO pa_purge_execution_claims(owner_id,intent_id,
    state,owner_epoch,inventory_generation,retention_episode,
    retention_revision,due_at,manifest_sha256,claimed_at)
    VALUES(?,?,'erasing',1,0,1,1,?,?,?)`)
    .bind(ownerId, intentId, dueAt, root, now + 3).run();
  const intentStore = {
    listOwnerVersionsPage: async () => ({ versions: events.map(event => ({
      key: ref(event.stage).key, versionId: ref(event.stage).versionId,
      deleteMarker: false, bytes: 100 })), nextCursor: null }),
    referenceForListedVersion: async (item: { key: string; versionId: string }) =>
      ({ ...item, sha256: hash, bytes: 100 }),
    readExact: async (reference: PurgeIntentReference) => {
      const value = events.find(item => reference.key === ref(item.stage).key
        && reference.versionId === ref(item.stage).versionId);
      if (!value) throw new Error('missing external event');
      return value;
    },
    putOnce: async (event: PurgeIntentEvent) => {
      events.push(event);
      return ref(event.stage);
    },
  } as unknown as S3PurgeIntentStore;
  const planStore = { loadPublished: async () => ({ ownerId, intentId,
    ownerEpoch: 1, inventoryGeneration: 0, sha256: root })
  } as unknown as S3PurgeManifestStore;
  const bucket = { list: async () => ({ objects: [], truncated: false,
    delimitedPrefixes: [] }) } as unknown as R2Bucket;
  const recovery = { listOwnerVersionsPage: async () =>
    ({ versions: [], nextCursor: null }) } as unknown as S3RecoveryCopy;
  const eraser = new OwnerD1Eraser({ db, bucket, recovery, intentStore,
    planStore, statusForBillingAccount: async () => 'expired', enabled: 'YES' });
  for (let step = 0; step < 30; step++) {
    if ((await eraser.step(ownerId, intentId, root)).state === 'owner-erased') break;
  }
  expect((await inspectOwnerD1Residue(db, ownerId)).contentTotal).toBe(0);
  const completion = new OwnerPurgeCompletion({ db, bucket, recovery,
    intentStore, intentLedger: new OwnerPurgeIntentLedger(db, intentStore),
    planStore, now: () => now + 5, enabled: 'YES' });
  await completion.complete(ownerId, intentId, root);
  return { ownerId, intentId, otherOwnerId, now, events, bucket, recovery,
    intentStore, completedRef: ref('completed') };
}

it('requires external completion, clears only completed owner evidence and consumes permits', async () => {
  const f = await completedOwner();
  const cleanup = (enabled: string, completedRef = f.completedRef) =>
    new OwnerD1EvidenceCleanup({ db, bucket: f.bucket, recovery: f.recovery,
      intentStore: f.intentStore, now: () => Date.now(), enabled })
      .step(f.ownerId, f.intentId, root, completedRef);
  const before = await inspectOwnerD1Residue(db, f.ownerId);
  await expect(cleanup('NO')).rejects.toMatchObject({ code: 'PURGE_EVIDENCE_CLEANUP_UNAVAILABLE' });
  await expect(cleanup('YES', { ...f.completedRef, versionId: 'wrong' }))
    .rejects.toMatchObject({ code: 'PURGE_EVIDENCE_CLEANUP_UNAVAILABLE' });
  expect(await inspectOwnerD1Residue(db, f.ownerId)).toEqual(before);
  await expect(db.prepare(`DELETE FROM pa_purge_execution_claims WHERE owner_id=?`)
    .bind(f.ownerId).run()).rejects.toThrow();
  let cleared = false;
  for (let i = 0; i < 12; i++) {
    const result = await cleanup('YES');
    const mid = await inspectOwnerD1Residue(db, f.ownerId);
    expect(mid.purgeWork.pa_purge_evidence_cleanup_permits).toBe(0);
    if (result.state === 'd1-cleared') { cleared = true; break; }
    expect(result.removed).toBeGreaterThan(0);
    expect(result.removed).toBeLessThanOrEqual(128);
  }
  expect(cleared).toBe(true);
  const after = await inspectOwnerD1Residue(db, f.ownerId);
  expect(after.contentTotal).toBe(0);
  expect(after.purgeWorkTotal).toBe(0);
  expect(await cleanup('YES')).toEqual({ state: 'd1-cleared', overdue: false });
  expect(await db.prepare('SELECT owner_id FROM pa_owners WHERE owner_id=?')
    .bind(f.otherOwnerId).first()).not.toBeNull();
  expect(f.events.map(event => event.stage)).toEqual(['prepared', 'erasing', 'completed']);
});
