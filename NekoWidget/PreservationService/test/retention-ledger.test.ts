import { env } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';
import { RetentionLedger } from '../src/retention-ledger';

const db = (env as unknown as { DB: D1Database }).DB;
async function fixture(start = Date.UTC(2026, 8, 23, 12)) {
  let now = start;
  const ownerId = crypto.randomUUID(); const billingId = crypto.randomUUID();
  await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
    .bind(ownerId, `synthetic:${ownerId}`, now).run();
  await db.prepare('INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at) VALUES(?,?,?)')
    .bind(ownerId, billingId, now).run();
  const ledger = new RetentionLedger(db, () => now);
  return { ownerId, ledger, at: (value: number) => { now = value; }, later: (value: number) => { now += value; }, now: () => now };
}
const day = 24 * 60 * 60 * 1000;

describe('twelve-month preservation export period', () => {
  it('lists only fresh, verified, unnotified expiry episodes for notice review', async () => {
    const f = await fixture();
    const other = await fixture();
    const upcoming = await f.ledger.observe(f.ownerId, 'expired');
    await other.ledger.observe(other.ownerId, 'expired');
    f.at(upcoming.dueAt! - 61 * day);
    await f.ledger.observe(f.ownerId, 'expired');
    expect(await f.ledger.listNoticeReviewCandidates()).toEqual([]);
    f.at(upcoming.dueAt! - 60 * day);
    const review = await f.ledger.observe(f.ownerId, 'expired');
    expect(await f.ledger.listNoticeReviewCandidates(1)).toEqual([{
      ownerId: f.ownerId, episode: review.episode, revision: review.revision, dueAt: upcoming.dueAt,
    }]);
    f.later(day + 1);
    expect(await f.ledger.listNoticeReviewCandidates()).toEqual([]); // stale billing observation
    await f.ledger.observe(f.ownerId, 'unknown');
    expect(await f.ledger.listNoticeReviewCandidates()).toEqual([]);
    f.later(1);
    await f.ledger.observe(f.ownerId, 'expired');
    expect(await f.ledger.listNoticeReviewCandidates()).toHaveLength(1);
    f.later(1);
    await f.ledger.observe(f.ownerId, 'active');
    expect(await f.ledger.listNoticeReviewCandidates()).toEqual([]);
    await expect(f.ledger.listNoticeReviewCandidates(101))
      .rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
  });
  it('excludes delivered and disabled owners from notice review', async () => {
    const f = await fixture();
    const first = await f.ledger.observe(f.ownerId, 'expired');
    f.at(first.dueAt! - 45 * day);
    await f.ledger.observe(f.ownerId, 'expired');
    expect(await f.ledger.listNoticeReviewCandidates()).toHaveLength(1);
    await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode, f.now(), 'synthetic-delivery-receipt-1');
    expect(await f.ledger.listNoticeReviewCandidates()).toEqual([]);
    const g = await fixture();
    const second = await g.ledger.observe(g.ownerId, 'expired');
    g.at(second.dueAt! - 30 * day);
    await g.ledger.observe(g.ownerId, 'expired');
    expect(await g.ledger.listNoticeReviewCandidates()).toHaveLength(1);
    await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?').bind(g.ownerId).run();
    expect(await g.ledger.listNoticeReviewCandidates()).toEqual([]);
  });
  it('does not repeatedly select a submitted notice, but permits retry or a changed contact', async () => {
    const f = await fixture();
    const first = await f.ledger.observe(f.ownerId, 'expired');
    f.at(first.dueAt! - 45 * day);
    const candidate = await f.ledger.observe(f.ownerId, 'expired');
    const submittedAt = f.now();
    await db.prepare(`INSERT INTO pa_notice_contacts
      (owner_id,sealed_email,source,verified_at,updated_at) VALUES(?,?,'apple',?,?)`)
      .bind(f.ownerId, new Uint8Array([1]).buffer, submittedAt, submittedAt).run();
    await db.prepare(`INSERT INTO pa_notice_submissions
      (message_id,owner_id,episode,retention_revision,due_at,contact_updated_at,recipient_tag,
       account_id,zone_id,subscription_id,domain,sender,submitted_at,evidence_version)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,2)`)
      .bind('message-retry-1', f.ownerId, candidate.episode, candidate.revision, candidate.dueAt,
        submittedAt, 'a'.repeat(64), 'b'.repeat(32), 'c'.repeat(32), 'd'.repeat(32),
        'example.com', 'notice@example.com', submittedAt).run();
    expect(await f.ledger.listNoticeReviewCandidates()).toEqual([]);
    f.later(7 * day);
    await f.ledger.observe(f.ownerId, 'expired');
    expect(await f.ledger.listNoticeReviewCandidates()).toEqual([]);
    f.later(1);
    await f.ledger.observe(f.ownerId, 'expired');
    expect(await f.ledger.listNoticeReviewCandidates()).toHaveLength(1);
    await db.prepare(`UPDATE pa_notice_submissions SET delivered_at=?,delivery_event_id=? WHERE message_id=?`)
      .bind(f.now(), crypto.randomUUID(), 'message-retry-1').run();
    expect(await f.ledger.listNoticeReviewCandidates()).toEqual([]);
    await db.prepare('UPDATE pa_notice_contacts SET updated_at=? WHERE owner_id=?')
      .bind(f.now(), f.ownerId).run();
    expect(await f.ledger.listNoticeReviewCandidates()).toHaveLength(1);
  });
  it('starts only on verified expiry, pauses on unknown, and never purges without a delivered notice', async () => {
    const f = await fixture();
    const start = f.now();
    expect((await f.ledger.observe(f.ownerId, 'unknown')).expiredAt).toBeNull();
    f.later(day);
    const expired = await f.ledger.observe(f.ownerId, 'expired');
    expect(expired.episode).toBe(1);
    expect(expired.expiredAt).toBe(f.now());
    expect(expired.dueAt).toBe(Date.UTC(2027, 8, 24, 12));
    f.at(expired.dueAt! + day);
    expect(await f.ledger.eligibleAfterFreshCheck(f.ownerId, 'expired')).toBe(false);

    // Unknown billing state can never authorize deletion, even after the old due date.
    f.at(start + 30 * day);
    await expect(f.ledger.observe(f.ownerId, 'unknown')).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    // Use a fresh account to exercise the normal unknown→expired pause sequence.
    const g = await fixture();
    const first = await g.ledger.observe(g.ownerId, 'expired');
    g.later(20 * day);
    const paused = await g.ledger.observe(g.ownerId, 'unknown');
    expect(paused.pausedAt).toBe(g.now());
    expect(paused.finalNoticeDeliveredAt).toBeNull();
    g.at(first.dueAt! + 10 * day);
    expect(await g.ledger.eligibleAfterFreshCheck(g.ownerId, 'unknown')).toBe(false);
    g.later(1);
    const resumed = await g.ledger.observe(g.ownerId, 'expired');
    expect(resumed.dueAt).toBe(first.dueAt! + (g.now() - paused.pausedAt!));
    expect(await g.ledger.eligibleAfterFreshCheck(g.ownerId, 'expired')).toBe(false);
  });

  it('requires a final delivery receipt at least 30 days before deletion', async () => {
    const f = await fixture();
    const first = await f.ledger.observe(f.ownerId, 'expired');
    f.at(first.dueAt! - 61 * day);
    await expect(f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode,
      f.now(), 'mail-provider-receipt-early')).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    f.at(first.dueAt! - 10 * day);
    const notified = await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode, f.now(), 'mail-provider-receipt-123');
    expect(notified.dueAt).toBe(f.now() + 30 * day);
    expect(await f.ledger.eligibleAfterFreshCheck(f.ownerId, 'expired')).toBe(false);
    f.at(notified.dueAt!);
    expect(await f.ledger.eligibleAfterFreshCheck(f.ownerId, 'expired')).toBe(true);
    const review = await f.ledger.expiryReviewAfterFreshCheck(f.ownerId, 'expired');
    expect(review).toMatchObject({ ownerId: f.ownerId, episode: first.episode,
      dueAt: notified.dueAt, deliveredAt: notified.finalNoticeDeliveredAt,
      deliveryEventId: 'mail-provider-receipt-123' });
    expect(review!.revision).toBeGreaterThan(0);
    expect((await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode,
      notified.finalNoticeDeliveredAt!, 'mail-provider-receipt-123')).dueAt).toBe(notified.dueAt);
    await expect(f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode,
      notified.finalNoticeDeliveredAt!, 'different-mail-receipt')).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    f.later(1);
    expect(await f.ledger.expiryReviewAfterFreshCheck(f.ownerId, 'active')).toBeNull();
  });

  it('invalidates an earlier notice after billing becomes unknown', async () => {
    const f = await fixture();
    const first = await f.ledger.observe(f.ownerId, 'expired');
    f.at(first.dueAt! - 45 * day);
    const oldNoticeAt = f.now();
    await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode, oldNoticeAt, 'mail-provider-receipt-123');
    f.later(day);
    expect((await f.ledger.observe(f.ownerId, 'unknown')).finalNoticeDeliveredAt).toBeNull();
    f.at(first.dueAt! + 2 * day);
    expect((await f.ledger.observe(f.ownerId, 'expired')).finalNoticeDeliveredAt).toBeNull();
    await expect(f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode,
      oldNoticeAt, 'mail-provider-receipt-123')).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    expect((await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode,
      f.now(), 'mail-provider-receipt-456')).finalNoticeDeliveredAt).toBe(f.now());
    expect(await f.ledger.eligibleAfterFreshCheck(f.ownerId, 'expired')).toBe(false);
  });

  it('cancels deletion on renewed membership and rejects notices from an old episode', async () => {
    const f = await fixture();
    const first = await f.ledger.observe(f.ownerId, 'expired');
    f.at(first.dueAt! - 45 * day);
    await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode, f.now(), 'mail-provider-receipt-123');
    f.later(day);
    const renewed = await f.ledger.observe(f.ownerId, 'grace');
    expect(renewed.dueAt).toBeNull();
    expect(renewed.finalNoticeDeliveredAt).toBeNull();
    f.later(day);
    const second = await f.ledger.observe(f.ownerId, 'expired');
    expect(second.episode).toBe(first.episode + 1);
    await expect(f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode,
      f.now(), 'mail-provider-receipt-456')).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    f.at(second.dueAt! + day);
    expect(await f.ledger.eligibleAfterFreshCheck(f.ownerId, 'active')).toBe(false);
  });

  it('clamps leap day to February 28 and refuses an unlinked owner', async () => {
    const f = await fixture(Date.UTC(2028, 1, 29, 9));
    const state = await f.ledger.observe(f.ownerId, 'expired');
    expect(state.dueAt).toBe(Date.UTC(2029, 1, 28, 9));
    await expect(f.ledger.observe(crypto.randomUUID(), 'expired'))
      .rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
  });

  it('records a billing outage as unknown instead of assuming expiry', async () => {
    const f = await fixture(Date.UTC(2030, 0, 1));
    const first = await f.ledger.observe(f.ownerId, 'expired');
    f.later(day);
    await f.ledger.refreshBatch(async () => { throw new Error('synthetic billing outage'); }, 100);
    const paused = await db.prepare('SELECT verified_status,paused_at FROM pa_retention WHERE owner_id=?')
      .bind(f.ownerId).first<{ verified_status: string; paused_at: number | null }>();
    expect(paused).toEqual({ verified_status: 'unknown', paused_at: f.now() });
    f.at(first.dueAt! + day);
    expect(await f.ledger.eligibleAfterFreshCheck(f.ownerId, 'unknown')).toBe(false);
  });
});
