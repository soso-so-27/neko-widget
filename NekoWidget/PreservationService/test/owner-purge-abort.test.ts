import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { OwnerPurgeAbort } from '../src/owner-purge-abort';
import type { PurgeFence } from '../src/owner-purge-fence';
import { OwnerPurgeIntentLedger } from '../src/owner-purge-intent-ledger';
import type { PurgeIntentEvent, PurgeIntentReference } from '../src/s3-purge-intent';

const db = (env as unknown as { DB: D1Database }).DB;
const day = 86_400_000;
const now = 1_800_000_000_000;

async function fixture() {
  const ownerId = crypto.randomUUID();
  const intentId = crypto.randomUUID();
  const candidate = { ownerId, episode: 1, revision: 1, dueAt: now - day,
    deliveredAt: now - 31 * day, deliveryEventId: `delivery-${crypto.randomUUID()}` };
  const fence: PurgeFence = { fenceId: intentId, ownerId, ownerEpoch: 1,
    inventoryGeneration: 0, candidate };
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,
    created_at,purge_fence_id) VALUES(?,?,1,1,?,?)`)
    .bind(ownerId, crypto.randomUUID(), now - 400 * day, intentId).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(ownerId).run();
  await db.prepare(`INSERT INTO pa_purge_fences(fence_id,owner_id,state,owner_epoch,
    inventory_generation,retention_episode,retention_revision,due_at,delivered_at,
    delivery_event_id,contact_updated_at,created_at,updated_at,lease_expires_at)
    VALUES(?,?,'fenced',1,0,1,1,?,?,?,?,?,?,?)`)
    .bind(intentId, ownerId, candidate.dueAt, candidate.deliveredAt,
      candidate.deliveryEventId, now - 40 * day, now, now, now + 10 * 60_000).run();
  const events = new Map<string, PurgeIntentEvent>();
  const store = {
    putOnce: async (event: PurgeIntentEvent): Promise<PurgeIntentReference> => {
      const old = events.get(event.stage);
      if (old && JSON.stringify(old) !== JSON.stringify(event)) throw Error('changed S3 event');
      events.set(event.stage, event);
      return { key: `purge/v1/${ownerId}/${intentId}/${event.stage}`,
        versionId: `v-${event.stage}`, sha256: 'a'.repeat(64), bytes: 10 };
    },
    listOwnerVersionsPage: async () => ({ versions: [...events.values()].map(event => ({
      key: `purge/v1/${ownerId}/${intentId}/${event.stage}`,
      versionId: `v-${event.stage}`, deleteMarker: false, bytes: 10 })), nextCursor: null }),
    referenceForListedVersion: async (item: { key: string; versionId: string }) => ({
      ...item, sha256: 'a'.repeat(64), bytes: 10 }),
    readExact: async (ref: { versionId: string }) => {
      const event = events.get(ref.versionId.slice(2));
      if (!event) throw Error('missing exact version');
      return event;
    },
  };
  const ledger = new OwnerPurgeIntentLedger(db, store);
  const prepared: PurgeIntentEvent = { version: 1, ownerId, intentId,
    stage: 'prepared', ownerEpoch: fence.ownerEpoch,
    inventoryGeneration: fence.inventoryGeneration,
    retentionEpisode: candidate.episode, retentionRevision: candidate.revision,
    dueAt: candidate.dueAt, recordedAt: now, manifestSha256: null };
  await ledger.append(prepared);
  return { fence, store, ledger, events };
}

it('records an exact-version abort without re-enabling the owner and retries idempotently', async () => {
  const f = await fixture();
  const abort = new OwnerPurgeAbort(db, f.store, f.ledger, () => now + 1);
  await abort.claimAndRecordAbort(f.fence);
  await abort.claimAndRecordAbort(f.fence);
  expect([...f.events.keys()].sort()).toEqual(['aborted', 'prepared']);
  expect(await db.prepare(`SELECT state FROM pa_purge_execution_claims
    WHERE owner_id=? AND intent_id=?`).bind(f.fence.ownerId, f.fence.fenceId).first())
    .toMatchObject({ state: 'aborted' });
  expect(await db.prepare('SELECT disabled,purge_fence_id FROM pa_owners WHERE owner_id=?')
    .bind(f.fence.ownerId).first())
    .toMatchObject({ disabled: 1, purge_fence_id: f.fence.fenceId });
});

it('keeps a failed S3 abort claim disabled for retry', async () => {
  const f = await fixture();
  const abort = new OwnerPurgeAbort(db, f.store, { append: async () => {
    throw Error('S3 unavailable');
  } }, () => now + 1);
  await expect(abort.claimAndRecordAbort(f.fence))
    .rejects.toMatchObject({ code: 'OWNER_PURGE_ABORT_UNAVAILABLE' });
  expect(await db.prepare(`SELECT state FROM pa_purge_execution_claims
    WHERE owner_id=? AND intent_id=?`).bind(f.fence.ownerId, f.fence.fenceId).first())
    .toMatchObject({ state: 'aborting' });
  expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?')
    .bind(f.fence.ownerId).first()).toMatchObject({ disabled: 1 });
});

it('resumes after S3 abort is recorded but D1 claim is still aborting', async () => {
  const f = await fixture();
  const claimedAt = now + 1;
  await db.prepare(`INSERT INTO pa_purge_execution_claims(owner_id,intent_id,state,
    owner_epoch,inventory_generation,retention_episode,retention_revision,due_at,
    manifest_sha256,claimed_at) VALUES(?,?,'aborting',1,0,1,1,?,NULL,?)`)
    .bind(f.fence.ownerId, f.fence.fenceId, f.fence.candidate.dueAt, claimedAt).run();
  await f.ledger.append({ ...f.events.get('prepared')!, stage: 'aborted', recordedAt: claimedAt });
  await new OwnerPurgeAbort(db, f.store, f.ledger, () => now + 2)
    .claimAndRecordAbort(f.fence);
  expect(await db.prepare(`SELECT state FROM pa_purge_execution_claims
    WHERE owner_id=? AND intent_id=?`).bind(f.fence.ownerId, f.fence.fenceId).first())
    .toMatchObject({ state: 'aborted' });
  expect(f.events.size).toBe(2);
});

it('refuses an externally erasing intent even when D1 has only prepared', async () => {
  const f = await fixture();
  const prepared = f.events.get('prepared')!;
  await f.store.putOnce({ ...prepared, stage: 'erasing', recordedAt: now + 1,
    manifestSha256: 'b'.repeat(64) });
  const abort = new OwnerPurgeAbort(db, f.store, f.ledger, () => now + 2);
  await expect(abort.claimAndRecordAbort(f.fence))
    .rejects.toMatchObject({ code: 'OWNER_PURGE_ABORT_UNAVAILABLE' });
  expect(await db.prepare(`SELECT count(*) AS count FROM pa_purge_execution_claims
    WHERE owner_id=?`).bind(f.fence.ownerId).first()).toMatchObject({ count: 0 });
});
