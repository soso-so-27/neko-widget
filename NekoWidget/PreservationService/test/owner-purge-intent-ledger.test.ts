import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { OwnerPurgeIntentLedger } from '../src/owner-purge-intent-ledger';
import type { PurgeIntentEvent, PurgeIntentReference } from '../src/s3-purge-intent';

const db = (env as unknown as { DB: D1Database }).DB;
const dueAt = 1_800_000_000_000;

async function fixture() {
  const ownerId = crypto.randomUUID();
  const intentId = crypto.randomUUID();
  await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
    .bind(ownerId, crypto.randomUUID(), dueAt - 400 * 86_400_000).run();
  const event: PurgeIntentEvent = { version: 1, ownerId, intentId, stage: 'prepared',
    ownerEpoch: 0, inventoryGeneration: 0, retentionEpisode: 1, retentionRevision: 1,
    dueAt, recordedAt: dueAt + 1_000, manifestSha256: null };
  const reference: PurgeIntentReference = {
    key: `purge/v1/${ownerId}/${intentId}/prepared`, versionId: 'synthetic-v1',
    sha256: 'a'.repeat(64), bytes: 100 };
  return { ownerId, event, reference };
}

it('records an exact read-back S3 version once and accepts an identical retry', async () => {
  const f = await fixture();
  let calls = 0;
  const ledger = new OwnerPurgeIntentLedger(db, { putOnce: async () => {
    calls++;
    return f.reference;
  } });
  expect(await ledger.append(f.event)).toEqual(f.reference);
  expect(await ledger.append(f.event)).toEqual(f.reference);
  expect(calls).toBe(2);
  expect(await db.prepare(`SELECT s3_object_key,s3_version_id,s3_sha256,s3_bytes
    FROM pa_owner_purge_events WHERE owner_id=?`).bind(f.ownerId).first())
    .toMatchObject({ s3_object_key: f.reference.key, s3_version_id: f.reference.versionId,
      s3_sha256: f.reference.sha256, s3_bytes: f.reference.bytes });
  expect((await db.prepare('SELECT count(*) AS n FROM pa_owner_purge_events WHERE owner_id=?')
    .bind(f.ownerId).first<{ n: number }>())?.n).toBe(1);
});

it('does not create D1 evidence if the S3 write/read-back fails or returns a foreign key', async () => {
  const f = await fixture();
  const failed = new OwnerPurgeIntentLedger(db, { putOnce: async () => { throw Error('S3 down'); } });
  await expect(failed.append(f.event)).rejects.toThrow();
  const foreign = new OwnerPurgeIntentLedger(db, { putOnce: async () => ({ ...f.reference,
    key: f.reference.key.replace(f.ownerId, crypto.randomUUID()) }) });
  await expect(foreign.append(f.event))
    .rejects.toMatchObject({ code: 'OWNER_PURGE_INTENT_UNAVAILABLE' });
  expect((await db.prepare('SELECT count(*) AS n FROM pa_owner_purge_events WHERE owner_id=?')
    .bind(f.ownerId).first<{ n: number }>())?.n).toBe(0);
});

it('rejects an existing conflicting version and out-of-order erasure', async () => {
  const f = await fixture();
  const ledger = new OwnerPurgeIntentLedger(db, { putOnce: async () => f.reference });
  await ledger.append(f.event);
  const changed = new OwnerPurgeIntentLedger(db, { putOnce: async () => ({ ...f.reference,
    versionId: 'different-v2' }) });
  await expect(changed.append(f.event))
    .rejects.toMatchObject({ code: 'OWNER_PURGE_INTENT_UNAVAILABLE' });
  const second = await fixture();
  const erasing: PurgeIntentEvent = { ...second.event, stage: 'erasing',
    manifestSha256: 'b'.repeat(64), recordedAt: second.event.recordedAt + 1 };
  const erasingLedger = new OwnerPurgeIntentLedger(db, { putOnce: async () => ({
    ...second.reference, key: `purge/v1/${second.ownerId}/${second.event.intentId}/erasing` }) });
  await expect(erasingLedger.append(erasing))
    .rejects.toMatchObject({ code: 'OWNER_PURGE_INTENT_UNAVAILABLE' });
});
