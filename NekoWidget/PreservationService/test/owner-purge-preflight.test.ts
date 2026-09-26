import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { OwnerPurgePreflight } from '../src/owner-purge-preflight';
import { renewFencedPurgeLease } from '../src/owner-purge-lease';
import { OwnerPurgeManifestLedger } from '../src/owner-purge-manifest-ledger';
import type { PurgeFence } from '../src/owner-purge-fence';
import type { PurgeIntentEvent, S3PurgeIntentStore } from '../src/s3-purge-intent';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';

const db = (env as unknown as { DB: D1Database }).DB;
const now = 1_800_000_000_000;
const day = 86_400_000;

async function fixture() {
  const ownerId = crypto.randomUUID();
  const fenceId = crypto.randomUUID();
  const billingAccount = crypto.randomUUID();
  const deliveryEventId = `delivery-${crypto.randomUUID()}`;
  const deliveredAt = now - 31 * day;
  const dueAt = now - day;
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,epoch,disabled,
    created_at,purge_fence_id) VALUES(?,?,1,1,?,?)`)
    .bind(ownerId, crypto.randomUUID(), now - 400 * day, fenceId).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(ownerId).run();
  await db.prepare(`INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at)
    VALUES(?,?,?)`).bind(ownerId, billingAccount, now - 400 * day).run();
  await db.prepare(`INSERT INTO pa_notice_contacts(owner_id,sealed_email,source,
    verified_at,updated_at,email_tag) VALUES(?,?,'apple',?,?,?)`)
    .bind(ownerId, new Uint8Array([1]).buffer,
      now - 40 * day, now - 40 * day, 'b'.repeat(64)).run();
  await db.prepare(`INSERT INTO pa_retention(owner_id,revision,episode,
    verified_status,checked_at,expired_at,due_at,notice_not_before_at,
    final_notice_delivered_at,final_notice_receipt)
    VALUES(?,3,1,'expired',?,?,?,?,?,?)`)
    .bind(ownerId, now - 1_000, now - 366 * day, dueAt, now - 366 * day,
      deliveredAt, deliveryEventId).run();
  await db.prepare(`INSERT INTO pa_notice_submissions(message_id,owner_id,episode,
    retention_revision,due_at,contact_updated_at,recipient_tag,account_id,zone_id,
    subscription_id,domain,sender,submitted_at,delivered_at,delivery_event_id,
    provider_accepted_at,evidence_version)
    VALUES(?,?,1,2,?,?,?,?,?,?,?,?,?,?,?,?,2)`)
    .bind(`message-${crypto.randomUUID()}`, ownerId, dueAt, now - 40 * day,
      'a'.repeat(64), 'account', 'zone', 'subscription', 'example.test',
      'sender@example.test', deliveredAt - 1_000, deliveredAt,
      deliveryEventId, deliveredAt - 1_000).run();
  await db.prepare(`INSERT INTO pa_purge_fences(fence_id,owner_id,state,
    owner_epoch,inventory_generation,retention_episode,retention_revision,
    due_at,delivered_at,delivery_event_id,contact_updated_at,created_at,
    updated_at,lease_expires_at)
    VALUES(?,?,'fenced',1,0,1,3,?,?,?,?,?,?,?)`)
    .bind(fenceId, ownerId, dueAt, deliveredAt, deliveryEventId,
      now - 40 * day, now, now, now + 600_000).run();
  const prepared: PurgeIntentEvent = { version: 1, ownerId, intentId: fenceId,
    stage: 'prepared', ownerEpoch: 1, inventoryGeneration: 0,
    retentionEpisode: 1, retentionRevision: 3, dueAt,
    recordedAt: now, manifestSha256: null };
  await db.prepare(`INSERT INTO pa_owner_purge_events(owner_id,intent_id,stage,
    owner_epoch,inventory_generation,retention_episode,retention_revision,due_at,
    recorded_at,manifest_sha256,s3_object_key,s3_version_id,s3_sha256,s3_bytes)
    VALUES(?,?,'prepared',1,0,1,3,?,?,NULL,?,?,?,10)`)
    .bind(ownerId, fenceId, dueAt, now,
      `purge/v1/${ownerId}/${fenceId}/prepared`, 'v-prepared',
      'a'.repeat(64)).run();
  const store = {
    listOwnerVersionsPage: async () => ({ versions: [{ key:
      `purge/v1/${ownerId}/${fenceId}/prepared`, versionId: 'v-prepared',
      deleteMarker: false, bytes: 10 }], nextCursor: null }),
    referenceForListedVersion: async (item: { key: string; versionId: string }) =>
      ({ ...item, sha256: 'a'.repeat(64), bytes: 10 }),
    readExact: async () => prepared,
  } as unknown as S3PurgeIntentStore;
  const fence: PurgeFence = { fenceId, ownerId, ownerEpoch: 1,
    inventoryGeneration: 0, candidate: { ownerId, episode: 1, revision: 3,
      dueAt, deliveredAt, deliveryEventId } };
  return { ownerId, fenceId, billingAccount, fence, store };
}

it('stages only a stable triple inventory while billing and the prepared intent hold', async () => {
  const f = await fixture();
  let lists = 0;
  let billing = 0;
  const bucket = { list: async () => { lists++;
    return { objects: [], truncated: false, delimitedPrefixes: [] }; } } as unknown as R2Bucket;
  const s3 = { listOwnerVersionsPage: async () =>
    ({ versions: [], nextCursor: null }) } as unknown as S3RecoveryCopy;
  const preflight = new OwnerPurgePreflight(db, bucket, s3, f.store,
    new OwnerPurgeManifestLedger(db), () => now, async account => {
      expect(account).toBe(f.billingAccount);
      billing++;
      return 'expired';
    });
  const manifest = await preflight.stage(f.fence);
  expect(manifest).toMatchObject({ r2Count: 0, s3Count: 0,
    chunks: [], sha256: expect.stringMatching(/^[0-9a-f]{64}$/u) });
  expect(lists).toBe(6);
  expect(billing).toBe(3);
  expect(await db.prepare(`SELECT sealed_at FROM pa_purge_manifests
    WHERE owner_id=? AND intent_id=?`).bind(f.ownerId, f.fenceId).first())
    .toMatchObject({ sealed_at: now });
  expect(await db.prepare(`SELECT COUNT(*) AS n FROM pa_owner_purge_events
    WHERE owner_id=? AND stage='erasing'`).bind(f.ownerId).first())
    .toMatchObject({ n: 0 });
});

it('does not authorize erasure if an orphan appears during the final inventory', async () => {
  const f = await fixture();
  let lists = 0;
  const orphan = `personal/${f.ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`;
  const bucket = { list: async () => ({ objects: ++lists < 5 ? []
    : [{ key: orphan, version: 'r2-late', size: 5 }],
    truncated: false, delimitedPrefixes: [] }) } as unknown as R2Bucket;
  const s3 = { listOwnerVersionsPage: async () =>
    ({ versions: [], nextCursor: null }) } as unknown as S3RecoveryCopy;
  const preflight = new OwnerPurgePreflight(db, bucket, s3, f.store,
    new OwnerPurgeManifestLedger(db), () => now, async () => 'expired');
  await expect(preflight.stage(f.fence))
    .rejects.toMatchObject({ code: 'OWNER_PURGE_PREFLIGHT_UNAVAILABLE' });
  expect(await db.prepare(`SELECT COUNT(*) AS n FROM pa_owner_purge_events
    WHERE owner_id=? AND stage='erasing'`).bind(f.ownerId).first())
    .toMatchObject({ n: 0 });
});

it('renews only a live pre-erasure fence after fresh billing checks', async () => {
  const f = await fixture();
  const later = now + 5 * 60_000;
  let checks = 0;
  expect(await renewFencedPurgeLease(db, f.fence, later, async account => {
    expect(account).toBe(f.billingAccount);
    checks++;
    return 'expired';
  })).toBe(later + 10 * 60_000);
  expect(checks).toBe(2);
  expect(await db.prepare(`SELECT disabled FROM pa_owners WHERE owner_id=?`)
    .bind(f.ownerId).first()).toMatchObject({ disabled: 1 });
  await expect(renewFencedPurgeLease(db, f.fence, later + 11 * 60_000,
    async () => 'expired')).rejects.toMatchObject({ code: 'PURGE_LEASE_RENEWAL_UNAVAILABLE' });
  await expect(renewFencedPurgeLease(db, f.fence, later + 60_000,
    async () => 'active')).rejects.toMatchObject({ code: 'PURGE_LEASE_RENEWAL_UNAVAILABLE' });
  expect(await db.prepare(`SELECT disabled FROM pa_owners WHERE owner_id=?`)
    .bind(f.ownerId).first()).toMatchObject({ disabled: 1 });
});

it('does not revive a fence whose lease expires during the billing check', async () => {
  const f = await fixture();
  const later = now + 5 * 60_000;
  await expect(renewFencedPurgeLease(db, f.fence, later, async () => {
    await db.prepare(`UPDATE pa_purge_fences SET lease_expires_at=?
      WHERE fence_id=?`).bind(later, f.fenceId).run();
    return 'expired';
  })).rejects.toMatchObject({ code: 'PURGE_LEASE_RENEWAL_UNAVAILABLE' });
  expect(await db.prepare(`SELECT lease_expires_at FROM pa_purge_fences WHERE fence_id=?`)
    .bind(f.fenceId).first()).toMatchObject({ lease_expires_at: later });
});
