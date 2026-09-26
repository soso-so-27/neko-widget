import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { OwnerD1Eraser } from '../src/owner-d1-erase';
import { inspectOwnerD1Residue } from '../src/owner-d1-residue';
import { OwnerPurgeCompletion } from '../src/owner-purge-completion';
import { OwnerPurgeIntentLedger } from '../src/owner-purge-intent-ledger';
import type { VerifiedMembershipStatus } from '../src/retention-ledger';
import type { PurgeIntentEvent, S3PurgeIntentStore } from '../src/s3-purge-intent';
import type { S3PurgeManifestStore } from '../src/s3-purge-manifest';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';

const db = (env as unknown as { DB: D1Database }).DB;
const now = 1_800_000_000_000;
const day = 86_400_000;

async function fixture() {
  const ownerId = crypto.randomUUID();
  const intentId = crypto.randomUUID();
  const root = 'b'.repeat(64);
  const dueAt = now - day;
  const billingAccountId = crypto.randomUUID();
  let status: VerifiedMembershipStatus = 'expired';
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,
    created_at,purge_fence_id) VALUES(?,?,1,1,?,?)`)
    .bind(ownerId, crypto.randomUUID(), now - 400 * day, intentId).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(ownerId).run();
  await db.prepare(`INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at)
    VALUES(?,?,?)`).bind(ownerId, billingAccountId, now - 400 * day).run();
  await db.prepare(`INSERT INTO pa_purge_fences(fence_id,owner_id,state,owner_epoch,
    inventory_generation,retention_episode,retention_revision,due_at,delivered_at,
    delivery_event_id,contact_updated_at,created_at,updated_at,lease_expires_at)
    VALUES(?,?,'fenced',1,0,1,1,?,?,?,?,?,?,?)`)
    .bind(intentId, ownerId, dueAt, now - 31 * day,
      `delivery-${crypto.randomUUID()}`, now - 40 * day,
      now, now, now + 10 * 60_000).run();
  await db.prepare(`INSERT INTO pa_purge_manifests(owner_id,intent_id,owner_epoch,
    inventory_generation,record_digest,records,r2_count,s3_count,r2_bytes,s3_bytes,
    chunk_count,sha256,created_at,sealed_at) VALUES(?,?,1,0,?,0,0,0,0,0,0,?,?,?)`)
    .bind(ownerId, intentId, 'a'.repeat(64), root, now, now + 1).run();
  await db.prepare(`INSERT INTO pa_purge_manifest_remote_refs(owner_id,intent_id,
    ordinal,s3_object_key,s3_version_id,s3_sha256,s3_bytes,confirmed_at)
    VALUES(?,?,-1,?,'header-v1',?,100,?)`)
    .bind(ownerId, intentId, `purge-plan/v1/${ownerId}/${intentId}/header`,
      'c'.repeat(64), now + 1).run();
  await db.prepare(`INSERT INTO pa_purge_manifest_remote_seals(owner_id,intent_id,
    root_sha256,sealed_at) VALUES(?,?,?,?)`)
    .bind(ownerId, intentId, root, now + 1).run();
  for (const stage of ['prepared', 'erasing'] as const) {
    await db.prepare(`INSERT INTO pa_owner_purge_events(owner_id,intent_id,stage,
      owner_epoch,inventory_generation,retention_episode,retention_revision,due_at,
      recorded_at,manifest_sha256,s3_object_key,s3_version_id,s3_sha256,s3_bytes)
      VALUES(?,?,?,1,0,1,1,?,?,?,?,?,?,1)`)
      .bind(ownerId, intentId, stage, dueAt,
        now + (stage === 'erasing' ? 2 : 0), stage === 'erasing' ? root : null,
        `purge/v1/${ownerId}/${intentId}/${stage}`, `v-${stage}`,
        'a'.repeat(64)).run();
  }
  await db.prepare(`INSERT INTO pa_purge_execution_claims(owner_id,intent_id,state,
    owner_epoch,inventory_generation,retention_episode,retention_revision,due_at,
    manifest_sha256,claimed_at) VALUES(?,?,'erasing',1,0,1,1,?,?,?)`)
    .bind(ownerId, intentId, dueAt, root, now + 3).run();
  const events: PurgeIntentEvent[] = (['prepared', 'erasing'] as const).map(
    (stage, index) => ({ version: 1, ownerId, intentId, stage,
      ownerEpoch: 1, inventoryGeneration: 0, retentionEpisode: 1,
      retentionRevision: 1, dueAt, recordedAt: now + index * 2,
      manifestSha256: stage === 'erasing' ? root : null }));
  const intentStore = {
    listOwnerVersionsPage: async () => ({ versions: events.map(event => ({
      key: `purge/v1/${ownerId}/${intentId}/${event.stage}`,
      versionId: `v-${event.stage}`, deleteMarker: false, bytes: 10 })),
      nextCursor: null }),
    referenceForListedVersion: async (item: { key: string; versionId: string }) =>
      ({ ...item, sha256: 'a'.repeat(64), bytes: 10 }),
    readExact: async (ref: { key: string }) => events.find(event =>
      ref.key.endsWith(`/${event.stage}`))!,
    putOnce: async (event: PurgeIntentEvent) => {
      const existing = events.find(item => item.stage === event.stage);
      if (existing && JSON.stringify(existing) !== JSON.stringify(event)) throw Error('immutable');
      if (!existing) events.push(event);
      return { key: `purge/v1/${ownerId}/${intentId}/${event.stage}`,
        versionId: `v-${event.stage}`, sha256: 'd'.repeat(64), bytes: 100 };
    },
  } as unknown as S3PurgeIntentStore;
  const planStore = { loadPublished: async () => ({ ownerId, intentId,
    ownerEpoch: 1, inventoryGeneration: 0, sha256: root })
  } as unknown as S3PurgeManifestStore;
  const bucket = { list: async () => ({ objects: [], truncated: false,
    delimitedPrefixes: [] }) } as unknown as R2Bucket;
  const recovery = { listOwnerVersionsPage: async () =>
    ({ versions: [], nextCursor: null }) } as unknown as S3RecoveryCopy;
  const make = (enabled = 'YES', otherBucket = bucket,
    check: (accountId: string) => Promise<VerifiedMembershipStatus>
      = async () => status) => new OwnerD1Eraser({
    db, bucket: otherBucket, recovery, intentStore, planStore,
    statusForBillingAccount: async accountId => {
      expect(accountId).toBe(billingAccountId);
      return check(accountId);
    }, enabled });
  const makeCompletion = (intentLedger: Pick<OwnerPurgeIntentLedger, 'append'>
    = new OwnerPurgeIntentLedger(db, intentStore)) => new OwnerPurgeCompletion({ db, bucket, recovery,
    intentStore, intentLedger,
    planStore, now: () => now + 5, enabled: 'YES' });
  return { ownerId, intentId, root, make, makeCompletion, intentStore,
    setStatus: (value: VerifiedMembershipStatus) => { status = value; } };
}

it('erases an owner in bounded, externally gated steps while retaining purge evidence', async () => {
  await db.prepare(`UPDATE pa_recovery_write_policy SET owner_snapshot_required=1
    WHERE singleton=1`).run();
  try {
    const f = await fixture();
    const eraser = f.make();
    const steps = [];
    for (let i = 0; i < 30; i++) {
      const step = await eraser.step(f.ownerId, f.intentId, f.root);
      steps.push(step);
      if (step.state === 'owner-erased') break;
    }
    expect(steps.at(-1)).toEqual({ state: 'owner-erased' });
    const residue = await inspectOwnerD1Residue(db, f.ownerId);
    expect(residue.contentTotal).toBe(0);
    expect(residue.purgeWork.pa_owner_purge_events).toBe(2);
    expect(residue.purgeWork.pa_purge_execution_claims).toBe(1);
  } finally {
    await db.prepare(`UPDATE pa_recovery_write_policy SET owner_snapshot_required=0
      WHERE singleton=1`).run();
  }
});

it('refuses D1 deletion while disabled or when cloud storage reappears', async () => {
  const f = await fixture();
  await expect(f.make('NO').step(f.ownerId, f.intentId, f.root)).rejects
    .toMatchObject({ code: 'OWNER_D1_ERASE_UNAVAILABLE' });
  const key = `personal/${f.ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`;
  const nonempty = { list: async () => ({ objects: [{ key, version: 'v1',
    size: 10 }], truncated: false, delimitedPrefixes: [] }) } as unknown as R2Bucket;
  await expect(f.make('YES', nonempty).step(f.ownerId, f.intentId, f.root)).rejects
    .toMatchObject({ code: 'OWNER_D1_ERASE_UNAVAILABLE' });
  expect(await db.prepare('SELECT owner_id FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).first()).not.toBeNull();
});

it('limits one invocation to 128 owner rows and resumes the same table', async () => {
  const f = await fixture();
  for (let i = 0; i < 129; i++) {
    await db.prepare(`INSERT INTO pa_sessions(session_hash,owner_id,owner_epoch,
      created_at,expires_at) VALUES(?,?,1,?,?)`)
      .bind(`${i}-${crypto.randomUUID()}`, f.ownerId, now, now + day).run();
  }
  const eraser = f.make();
  expect(await eraser.step(f.ownerId, f.intentId, f.root))
    .toMatchObject({ table: 'pa_sessions', removed: 128 });
  expect(await db.prepare('SELECT COUNT(*) AS n FROM pa_sessions WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ n: 1 });
  expect(await eraser.step(f.ownerId, f.intentId, f.root))
    .toMatchObject({ table: 'pa_sessions', removed: 1 });
  expect(await db.prepare('SELECT owner_id FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).first()).not.toBeNull();
});

it('stops later D1 steps on renewal without restoring already erased rows', async () => {
  const f = await fixture();
  const eraser = f.make();
  let beforeFinal = await inspectOwnerD1Residue(db, f.ownerId);
  for (let i = 0; i < 30 && beforeFinal.contentTotal > 2; i++) {
    expect((await eraser.step(f.ownerId, f.intentId, f.root)).state).toBe('progress');
    beforeFinal = await inspectOwnerD1Residue(db, f.ownerId);
  }
  expect(beforeFinal.contentTotal).toBe(2); // The next step is the final atomic batch.
  expect(beforeFinal.purgeWork.pa_purge_fences).toBe(1);
  f.setStatus('active');
  await expect(eraser.step(f.ownerId, f.intentId, f.root)).rejects
    .toMatchObject({ code: 'OWNER_D1_ERASE_UNAVAILABLE' });
  expect(await inspectOwnerD1Residue(db, f.ownerId)).toEqual(beforeFinal);
  expect(await db.prepare(`SELECT disabled,purge_fence_id FROM pa_owners
    WHERE owner_id=?`).bind(f.ownerId).first()).toMatchObject({
      disabled: 1, purge_fence_id: f.intentId });
  expect(beforeFinal.content.pa_membership_links).toBe(1);
  expect(beforeFinal.purgeWork.pa_purge_fences).toBe(1);
});

it('does not delete on grace, unknown or failed fresh membership checks', async () => {
  for (const denied of ['grace', 'unknown'] as const) {
    const f = await fixture();
    f.setStatus(denied);
    const before = await inspectOwnerD1Residue(db, f.ownerId);
    await expect(f.make().step(f.ownerId, f.intentId, f.root)).rejects
      .toMatchObject({ code: 'OWNER_D1_ERASE_UNAVAILABLE' });
    expect(await inspectOwnerD1Residue(db, f.ownerId)).toEqual(before);
  }
  const failed = await fixture();
  const before = await inspectOwnerD1Residue(db, failed.ownerId);
  await expect(failed.make('YES', undefined, async () => {
    throw new Error('membership lookup failed');
  }).step(failed.ownerId, failed.intentId, failed.root)).rejects
    .toMatchObject({ code: 'OWNER_D1_ERASE_UNAVAILABLE' });
  expect(await inspectOwnerD1Residue(db, failed.ownerId)).toEqual(before);
});

it('records completion only after all owner content and cloud versions are absent', async () => {
  const f = await fixture();
  const completion = f.makeCompletion();
  await expect(completion.complete(f.ownerId, f.intentId, f.root)).rejects
    .toMatchObject({ code: 'OWNER_PURGE_COMPLETION_UNAVAILABLE' });
  const eraser = f.make();
  for (let i = 0; i < 30; i++) {
    if ((await eraser.step(f.ownerId, f.intentId, f.root)).state === 'owner-erased') break;
  }
  await completion.complete(f.ownerId, f.intentId, f.root);
  await completion.complete(f.ownerId, f.intentId, f.root); // same S3 event, retryable
  expect(await db.prepare(`SELECT state FROM pa_purge_execution_claims
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.intentId).first())
    .toMatchObject({ state: 'completed' });
  expect(await db.prepare(`SELECT COUNT(*) AS n FROM pa_owner_purge_events
    WHERE owner_id=? AND intent_id=? AND stage='completed'`)
    .bind(f.ownerId, f.intentId).first()).toMatchObject({ n: 1 });
});

it('replays an S3 completed event after its D1 insert failed', async () => {
  const f = await fixture();
  const eraser = f.make();
  for (let i = 0; i < 30; i++) {
    if ((await eraser.step(f.ownerId, f.intentId, f.root)).state === 'owner-erased') break;
  }
  const interrupted = f.makeCompletion({ append: async event => {
    await f.intentStore.putOnce(event);
    throw Error('D1 unavailable after S3 commit');
  } });
  await expect(interrupted.complete(f.ownerId, f.intentId, f.root)).rejects
    .toMatchObject({ code: 'OWNER_PURGE_COMPLETION_UNAVAILABLE' });
  expect(await db.prepare(`SELECT state FROM pa_purge_execution_claims
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.intentId).first())
    .toMatchObject({ state: 'erasing' });
  await f.makeCompletion().complete(f.ownerId, f.intentId, f.root);
  expect(await db.prepare(`SELECT state FROM pa_purge_execution_claims
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.intentId).first())
    .toMatchObject({ state: 'completed' });
});
