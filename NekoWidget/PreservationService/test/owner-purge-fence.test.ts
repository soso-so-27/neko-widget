import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { sha256 } from '../src/contracts';
import type { NoticeSubmissions } from '../src/notice-submissions';
import { verifyFencedPurgeEligibility } from '../src/fenced-purge-eligibility';
import { OwnerPurgeFence } from '../src/owner-purge-fence';
import { OwnerPurgeAbort } from '../src/owner-purge-abort';
import { OwnerPurgeIntentLedger } from '../src/owner-purge-intent-ledger';
import { OwnerPurgeRelease } from '../src/owner-purge-release';
import { RetentionLedger, type ExpiryReviewCandidate, type VerifiedMembershipStatus } from '../src/retention-ledger';
import type { PurgeIntentEvent, PurgeIntentReference } from '../src/s3-purge-intent';

const db = (env as unknown as { DB: D1Database }).DB;
const day = 86_400_000;
const now = 1_800_000_000_000;
const deliveredAt = now - 31 * day;
const dueAt = now - day;
const tag = 'a'.repeat(64);

async function fixture(statuses: VerifiedMembershipStatus[] = ['expired', 'expired'],
  beforeStatusReturn?: (call: number, ownerId: string) => Promise<void>,
  withExternal = false, afterFirstPreparedRead?: (ownerId: string) => Promise<void>) {
  const ownerId = crypto.randomUUID();
  const billingAccount = crypto.randomUUID();
  const deliveryEventId = `delivery-${crypto.randomUUID()}`;
  const candidate: ExpiryReviewCandidate = { ownerId, episode: 1, revision: 3,
    dueAt, deliveredAt, deliveryEventId };
  await db.prepare(`INSERT INTO pa_owners(owner_id,identity_key,created_at)
    VALUES(?,?,?)`).bind(ownerId, crypto.randomUUID(), now - 400 * day).run();
  await db.prepare(`INSERT INTO pa_identity_credentials(owner_id,owner_epoch,
    sealed_credentials,updated_at) VALUES(?,0,?,?)`)
    .bind(ownerId, new Uint8Array([1]).buffer, now - 400 * day).run();
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(ownerId).run();
  await db.prepare('INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at) VALUES(?,?,?)')
    .bind(ownerId, billingAccount, now - 400 * day).run();
  await db.prepare(`INSERT INTO pa_notice_contacts(owner_id,sealed_email,source,verified_at,updated_at,email_tag)
    VALUES(? ,?,'apple',?,?,?)`)
    .bind(ownerId, new Uint8Array([1]).buffer, now - 40 * day, now - 40 * day, 'b'.repeat(64)).run();
  await db.prepare(`INSERT INTO pa_retention(owner_id,revision,episode,verified_status,checked_at,
    expired_at,due_at,notice_not_before_at,final_notice_delivered_at,final_notice_receipt)
    VALUES(?,3,1,'expired',?,?,?,?,?,?)`)
    .bind(ownerId, now - 1_000, now - 366 * day, dueAt, now - 366 * day,
      deliveredAt, deliveryEventId).run();
  await db.prepare(`INSERT INTO pa_notice_submissions(message_id,owner_id,episode,retention_revision,
    due_at,contact_updated_at,recipient_tag,account_id,zone_id,subscription_id,domain,sender,
    submitted_at,delivered_at,delivery_event_id,provider_accepted_at,evidence_version)
    VALUES(?,?,1,2,?,?,?,?,?,?,?,?,?,?,?,?,2)`)
    .bind(`message-${crypto.randomUUID()}`, ownerId, dueAt, now - 40 * day, tag,
      'account', 'zone', 'subscription', 'example.test', 'sender@example.test',
      deliveredAt - 1_000, deliveredAt, deliveryEventId, deliveredAt - 1_000).run();
  const events = new Map<string, PurgeIntentEvent>();
  let failPut = false;
  let preparedRead = false;
  const store = {
    putOnce: async (event: PurgeIntentEvent): Promise<PurgeIntentReference> => {
      if (failPut) throw Error('S3 unavailable');
      const key = `purge/v1/${event.ownerId}/${event.intentId}/${event.stage}`;
      const existing = events.get(key);
      if (existing && JSON.stringify(existing) !== JSON.stringify(event)) throw Error('changed event');
      events.set(key, event);
      return { key, versionId: `v-${event.stage}`, sha256: 'a'.repeat(64), bytes: 10 };
    },
    listOwnerVersionsPage: async () => ({ versions: [...events.entries()].map(([key, event]) => ({
      key, versionId: `v-${event.stage}`, deleteMarker: false, bytes: 10 })), nextCursor: null }),
    referenceForListedVersion: async (item: { key: string; versionId: string }) => ({
      ...item, sha256: 'a'.repeat(64), bytes: 10 }),
    readExact: async (ref: { key: string }) => {
      const event = events.get(ref.key);
      if (!event) throw Error('missing event');
      if (event.stage === 'prepared' && !preparedRead) {
        preparedRead = true;
        await afterFirstPreparedRead?.(ownerId);
      }
      return event;
    },
  };
  const ledger = new OwnerPurgeIntentLedger(db, store);
  let calls = 0;
  const fence = new OwnerPurgeFence({ db, now: () => now,
    ...(withExternal ? { purgeIntentStore: store, purgeIntentLedger: ledger } : {}),
    statusForBillingAccount: async account => {
      expect(account).toBe(billingAccount);
      const call = calls++;
      await beforeStatusReturn?.(call, ownerId);
      return statuses[Math.min(call, statuses.length - 1)]!;
    },
    retention: { observe: (owner: string, status: VerifiedMembershipStatus) =>
      new RetentionLedger(db, () => now).observe(owner, status),
      expiryReviewAfterFreshCheck: async () => candidate } as unknown as RetentionLedger,
    auth: { verifiedNoticeContactForExpiry: async () =>
      ({ email: 'person@example.test', updatedAt: now - 40 * day }) } as unknown as DurableAuth,
    notices: { verifiedFinalNoticeEvidenceForExpiry: async () =>
      ({ recipientTag: tag, contactUpdatedAt: now - 40 * day }) } as unknown as NoticeSubmissions,
  });
  return { fence, candidate, ownerId, billingAccount, events, store, ledger,
    setPutFailure(value: boolean) { failPut = value; }, get calls() { return calls; } };
}

async function recordSnapshot(ownerId: string): Promise<void> {
  const current = await db.prepare(`SELECT generation FROM pa_owner_recovery_generations
    WHERE owner_id=?`).bind(ownerId).first<{ generation: number }>();
  expect(current?.generation).toBeGreaterThan(0);
  await db.prepare(`INSERT INTO pa_owner_recovery_versions(owner_id,generation,
    object_key,version_id,sha256,bytes,confirmed_at) VALUES(?,?,?,?,?,?,?)`)
    .bind(ownerId, current!.generation, `recovery/v1/${ownerId}/owner/${current!.generation}`,
      'synthetic-version', 'a'.repeat(64), 10, now).run();
}

it('policy ON requires external preparation and never thaws without S3-aware release', async () => {
  const missing = await fixture();
  await recordSnapshot(missing.ownerId);
  await db.prepare(`UPDATE pa_recovery_write_policy SET owner_snapshot_required=1
    WHERE singleton=1`).run();
  try {
    await expect(missing.fence.begin(missing.ownerId)).rejects.toThrow();
    expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?')
      .bind(missing.ownerId).first()).toMatchObject({ disabled: 0 });
    await expect(db.prepare(`UPDATE pa_owners SET disabled=1,purge_fence_id=?
      WHERE owner_id=?`).bind(crypto.randomUUID(), missing.ownerId).run()).rejects.toThrow();

    const failed = await fixture(['expired', 'expired'], undefined, true);
    await recordSnapshot(failed.ownerId);
    failed.setPutFailure(true);
    await expect(failed.fence.begin(failed.ownerId)).rejects.toThrow();
    expect(failed.events.size).toBe(0);
    expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?')
      .bind(failed.ownerId).first()).toMatchObject({ disabled: 0 });

    const staleSnapshot = await fixture(['expired', 'expired'], undefined, true,
      async ownerId => { await db.prepare(`UPDATE pa_identity_credentials
        SET updated_at=updated_at+1 WHERE owner_id=?`).bind(ownerId).run(); });
    await recordSnapshot(staleSnapshot.ownerId);
    await expect(staleSnapshot.fence.begin(staleSnapshot.ownerId)).rejects.toThrow();
    expect([...staleSnapshot.events.values()].map(event => event.stage).sort())
      .toEqual(['aborted', 'prepared']);
    expect(await db.prepare('SELECT disabled,purge_fence_id FROM pa_owners WHERE owner_id=?')
      .bind(staleSnapshot.ownerId).first()).toMatchObject({ disabled: 0,
        purge_fence_id: null });

    const racing = await fixture(['expired', 'expired'], async (call, ownerId) => {
      if (call !== 0) return;
      await db.prepare('INSERT INTO pa_pending_deletes(object_key,created_at) VALUES(?,?)')
        .bind(`personal/${ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`, now).run();
    }, true);
    await recordSnapshot(racing.ownerId);
    expect(await racing.fence.begin(racing.ownerId)).toBeNull();
    expect([...racing.events.values()].map(event => event.stage).sort())
      .toEqual(['aborted', 'prepared']);
    expect(await db.prepare('SELECT disabled,purge_fence_id FROM pa_owners WHERE owner_id=?')
      .bind(racing.ownerId).first()).toMatchObject({ disabled: 0, purge_fence_id: null });
    expect(await db.prepare('SELECT state FROM pa_purge_fences WHERE owner_id=?')
      .bind(racing.ownerId).first()).toMatchObject({ state: 'aborted' });

    const prepared = await fixture(['expired', 'expired'], undefined, true);
    await recordSnapshot(prepared.ownerId);
    const result = await prepared.fence.begin(prepared.ownerId);
    expect(result).not.toBeNull();
    expect([...prepared.events.values()]).toMatchObject([{ stage: 'prepared',
      intentId: result!.fenceId, ownerEpoch: 1 }]);
    expect(await db.prepare(`SELECT stage,s3_version_id FROM pa_owner_purge_events
      WHERE owner_id=? AND intent_id=?`).bind(prepared.ownerId, result!.fenceId).first())
      .toMatchObject({ stage: 'prepared', s3_version_id: 'v-prepared' });
    expect(await db.prepare('SELECT disabled,purge_fence_id FROM pa_owners WHERE owner_id=?')
      .bind(prepared.ownerId).first()).toMatchObject({ disabled: 1,
        purge_fence_id: result!.fenceId });

    const renewed = await fixture(['expired', 'active'], undefined, true);
    await recordSnapshot(renewed.ownerId);
    await expect(renewed.fence.begin(renewed.ownerId)).rejects.toThrow();
    expect([...renewed.events.values()].map(event => event.stage).sort())
      .toEqual(['aborted', 'prepared']);
    expect(await db.prepare('SELECT disabled,purge_fence_id FROM pa_owners WHERE owner_id=?')
      .bind(renewed.ownerId).first()).toMatchObject({ disabled: 1,
        purge_fence_id: expect.any(String) });
    expect(await db.prepare('SELECT state FROM pa_purge_execution_claims WHERE owner_id=?')
      .bind(renewed.ownerId).first()).toMatchObject({ state: 'aborted' });
    await expect(db.prepare(`UPDATE pa_owners SET disabled=0,epoch=epoch+1,
      purge_fence_id=NULL WHERE owner_id=?`).bind(renewed.ownerId).run()).rejects.toThrow();
    const held = await db.prepare('SELECT purge_fence_id FROM pa_owners WHERE owner_id=?')
      .bind(renewed.ownerId).first<{ purge_fence_id: string }>();
    const release = new OwnerPurgeRelease(db, { list: async () => ({
      objects: [], truncated: false, delimitedPrefixes: [],
    }) } as unknown as R2Bucket, renewed.store,
    new OwnerPurgeAbort(db, renewed.store, renewed.ledger, () => now + 1),
    { copyCurrent: async (_db, ownerId, at) => {
      expect(ownerId).toBe(renewed.ownerId);
      expect(at).toBe(now + 2);
      await recordSnapshot(ownerId);
      return { key: '', versionId: '', sha256: '', bytes: 0 };
    } },
    () => now + 2, async account => account === renewed.billingAccount ? 'active' : 'unknown');
    await release.release({ fenceId: held!.purge_fence_id, ownerId: renewed.ownerId,
      ownerEpoch: 1, inventoryGeneration: 0, candidate: renewed.candidate });
    expect(await db.prepare('SELECT disabled,epoch,purge_fence_id FROM pa_owners WHERE owner_id=?')
      .bind(renewed.ownerId).first()).toMatchObject({ disabled: 0, epoch: 2,
        purge_fence_id: null });
    expect(await db.prepare('SELECT state FROM pa_purge_fences WHERE owner_id=?')
      .bind(renewed.ownerId).first()).toMatchObject({ state: 'aborted' });
    const token = 's'.repeat(43);
    await db.prepare(`INSERT INTO pa_sessions(session_hash,owner_id,owner_epoch,created_at,expires_at)
      VALUES(?,?,?,?,?)`).bind(await sha256(token), renewed.ownerId, 2, now, now + day).run();
    const auth = new DurableAuth({ db, now: () => now + 2,
      identityIndexSecret: btoa(String.fromCharCode(...new Uint8Array(32).fill(7)))
        .replace(/=+$/, ''),
      keys: { seal: async () => { throw Error('unused'); },
        open: async () => { throw Error('unused'); } } });
    expect((await auth.requireSession(token)).ownerId).toBe(renewed.ownerId);
    // A subsequent owner-state mutation creates a new generation. Until its
    // S3 copy is acknowledged, even a valid session cannot read the archive.
    await db.prepare('UPDATE pa_identity_credentials SET updated_at=updated_at+1 WHERE owner_id=?')
      .bind(renewed.ownerId).run();
    await expect(auth.requireSession(token)).rejects.toMatchObject({ code: 'unauthorized' });
    await recordSnapshot(renewed.ownerId);
    expect((await auth.requireSession(token)).ownerId).toBe(renewed.ownerId);
  } finally {
    await db.prepare(`UPDATE pa_recovery_write_policy SET owner_snapshot_required=0
      WHERE singleton=1`).run();
  }
});

it('fences an exact expired owner and keeps every record untouched', async () => {
  const f = await fixture();
  const actual = await f.fence.begin(f.ownerId);
  expect(actual).toMatchObject({ ownerId: f.ownerId, ownerEpoch: 1,
    inventoryGeneration: 0, candidate: f.candidate });
  expect(f.calls).toBe(2);
  expect(await db.prepare('SELECT disabled,epoch,purge_fence_id FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ disabled: 1, epoch: 1, purge_fence_id: actual!.fenceId });
  expect(await db.prepare('SELECT state,owner_epoch,inventory_generation FROM pa_purge_fences WHERE fence_id=?')
    .bind(actual!.fenceId).first()).toMatchObject({ state: 'fenced', owner_epoch: 1,
      inventory_generation: 0 });
});

it('unfences before deletion when a second billing check is no longer expired', async () => {
  const f = await fixture(['expired', 'active']);
  expect(await f.fence.begin(f.ownerId)).toBeNull();
  expect(await db.prepare('SELECT disabled,epoch,purge_fence_id FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ disabled: 0, epoch: 2, purge_fence_id: null });
  expect(await db.prepare('SELECT state FROM pa_purge_fences WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ state: 'aborted' });
  expect(await db.prepare('SELECT owner_epoch FROM pa_identity_credentials WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ owner_epoch: 2 });
  expect(await db.prepare(`SELECT verified_status,expired_at,due_at,final_notice_receipt
    FROM pa_retention WHERE owner_id=?`).bind(f.ownerId).first()).toMatchObject({
    verified_status: 'active', expired_at: null, due_at: null, final_notice_receipt: null,
  });
});

it('invalidates an old notice when billing renewed before a later expiry', async () => {
  const f = await fixture(['active', 'expired', 'expired']);
  expect(await f.fence.begin(f.ownerId)).toBeNull();
  expect(await db.prepare(`SELECT verified_status,expired_at,final_notice_receipt
    FROM pa_retention WHERE owner_id=?`).bind(f.ownerId).first()).toMatchObject({
    verified_status: 'active', expired_at: null, final_notice_receipt: null,
  });
  expect(await f.fence.begin(f.ownerId)).toBeNull();
  expect(await db.prepare('SELECT disabled,purge_fence_id FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ disabled: 0, purge_fence_id: null });
});

it('rejects an expired fence instead of reusing its old notice', async () => {
  const f = await fixture();
  const fenced = await f.fence.begin(f.ownerId);
  expect(fenced).not.toBeNull();
  expect(await verifyFencedPurgeEligibility(db, fenced!, now + 11 * 60_000,
    async () => 'expired')).toBe(false);
  expect(await db.prepare('SELECT disabled,purge_fence_id FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ disabled: 1, purge_fence_id: fenced!.fenceId });
});

it('rechecks a disabled fence against fresh billing and exact notice evidence', async () => {
  const f = await fixture();
  const fenced = await f.fence.begin(f.ownerId);
  expect(fenced).not.toBeNull();
  const candidate = fenced!;
  expect(await verifyFencedPurgeEligibility(db, candidate, now,
    async account => account === f.billingAccount ? 'expired' : 'unknown')).toBe(true);
  expect(await verifyFencedPurgeEligibility(db, candidate, now,
    async () => 'active')).toBe(false);
  expect(await verifyFencedPurgeEligibility(db, candidate, now,
    async () => { throw new Error('billing unavailable'); })).toBe(false);
  expect(await verifyFencedPurgeEligibility(db, candidate, now,
    async () => {
      await db.prepare('UPDATE pa_notice_contacts SET updated_at=updated_at+1 WHERE owner_id=?')
        .bind(f.ownerId).run();
      return 'expired';
    })).toBe(false);
});

it('does not trust the fence after an inventory generation change', async () => {
  const f = await fixture();
  const fenced = await f.fence.begin(f.ownerId);
  expect(fenced).not.toBeNull();
  await db.prepare('UPDATE pa_inventory SET generation=generation+1 WHERE owner_id=?')
    .bind(f.ownerId).run();
  expect(await verifyFencedPurgeEligibility(db, fenced!, now, async () => 'expired')).toBe(false);
});

it('detects changed notification evidence across the private billing check', async () => {
  const f = await fixture();
  const fenced = await f.fence.begin(f.ownerId);
  expect(fenced).not.toBeNull();
  expect(await verifyFencedPurgeEligibility(db, fenced!, now, async () => {
    await db.prepare('UPDATE pa_notice_submissions SET recipient_tag=? WHERE owner_id=?')
      .bind('c'.repeat(64), f.ownerId).run();
    return 'expired';
  })).toBe(false);
});

it('does not fence after a contact change or while storage cleanup is pending', async () => {
  const changed = await fixture();
  await db.prepare('UPDATE pa_notice_contacts SET updated_at=updated_at+1 WHERE owner_id=?')
    .bind(changed.ownerId).run();
  expect(await changed.fence.begin(changed.ownerId)).toBeNull();
  expect(await db.prepare('SELECT disabled,purge_fence_id FROM pa_owners WHERE owner_id=?')
    .bind(changed.ownerId).first()).toMatchObject({ disabled: 0, purge_fence_id: null });

  const pending = await fixture();
  await db.prepare(`INSERT INTO pa_uploads(operation_id,owner_id,record_id,object_key,reserved_bytes,expires_at)
    VALUES(?,?,?,?,1,?)`).bind(crypto.randomUUID(), pending.ownerId, crypto.randomUUID(),
      `personal/${pending.ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`, now + day).run();
  expect(await pending.fence.begin(pending.ownerId)).toBeNull();
  expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?')
    .bind(pending.ownerId).first()).toMatchObject({ disabled: 0 });

  const deleting = await fixture();
  await db.prepare(`INSERT INTO pa_pending_deletes(object_key,created_at) VALUES(?,?)`)
    .bind(`personal/${deleting.ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`, now - day).run();
  expect(await deleting.fence.begin(deleting.ownerId)).toBeNull();
  expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?')
    .bind(deleting.ownerId).first()).toMatchObject({ disabled: 0 });

  const racing = await fixture(['expired', 'expired'], async (call, ownerId) => {
    if (call !== 0) return;
    await db.prepare('INSERT INTO pa_pending_deletes(object_key,created_at) VALUES(?,?)')
      .bind(`personal/${ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`, now).run();
  });
  expect(await racing.fence.begin(racing.ownerId)).toBeNull();
  expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?')
    .bind(racing.ownerId).first()).toMatchObject({ disabled: 0 });
});
