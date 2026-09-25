import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import type { DurableAuth } from '../src/auth';
import type { NoticeSubmissions } from '../src/notice-submissions';
import { OwnerPurgeFence, recoverAbandonedPurgeFences } from '../src/owner-purge-fence';
import { RetentionLedger, type ExpiryReviewCandidate, type VerifiedMembershipStatus } from '../src/retention-ledger';

const db = (env as unknown as { DB: D1Database }).DB;
const day = 86_400_000;
const now = 1_800_000_000_000;
const deliveredAt = now - 31 * day;
const dueAt = now - day;
const tag = 'a'.repeat(64);

async function fixture(statuses: VerifiedMembershipStatus[] = ['expired', 'expired'],
  beforeStatusReturn?: (call: number, ownerId: string) => Promise<void>) {
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
  let calls = 0;
  const fence = new OwnerPurgeFence({ db, now: () => now,
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
  return { fence, candidate, ownerId, billingAccount, get calls() { return calls; } };
}

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

it('recovers a crashed pre-deletion fence after its lease and invalidates notice', async () => {
  const f = await fixture();
  const fenced = await f.fence.begin(f.ownerId);
  expect(fenced).not.toBeNull();
  expect(await recoverAbandonedPurgeFences(db, now + 9 * 60_000)).toBe(0);
  expect(await recoverAbandonedPurgeFences(db, now + 11 * 60_000)).toBeGreaterThanOrEqual(1);
  expect(await db.prepare('SELECT disabled,epoch,purge_fence_id FROM pa_owners WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ disabled: 0, epoch: 2, purge_fence_id: null });
  expect(await db.prepare('SELECT owner_epoch FROM pa_identity_credentials WHERE owner_id=?')
    .bind(f.ownerId).first()).toMatchObject({ owner_epoch: 2 });
  expect(await db.prepare(`SELECT verified_status,paused_at,final_notice_receipt
    FROM pa_retention WHERE owner_id=?`).bind(f.ownerId).first()).toMatchObject({
    verified_status: 'unknown', paused_at: now + 11 * 60_000, final_notice_receipt: null,
  });
  expect(await recoverAbandonedPurgeFences(db, now + 12 * 60_000)).toBe(0);
});

it('requires snapshot policy OFF before selecting any lease for automatic thaw', async () => {
  let selection = '';
  const isolated = { prepare(sql: string) {
    selection = sql;
    return { bind: () => ({ all: async () => ({ results: [] }) }) };
  } } as unknown as D1Database;
  expect(await recoverAbandonedPurgeFences(isolated, now + 11 * 60_000)).toBe(0);
  expect(selection).toContain('owner_snapshot_required FROM pa_recovery_write_policy');
  expect(selection).toContain('WHERE singleton=1)=0');
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
