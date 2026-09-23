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
    f.at(first.dueAt! - 10 * day);
    const notified = await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode, f.now(), 'mail-provider-receipt-123');
    expect(notified.dueAt).toBe(f.now() + 30 * day);
    expect(await f.ledger.eligibleAfterFreshCheck(f.ownerId, 'expired')).toBe(false);
    f.at(notified.dueAt!);
    expect(await f.ledger.eligibleAfterFreshCheck(f.ownerId, 'expired')).toBe(true);
    expect((await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode,
      notified.finalNoticeDeliveredAt!, 'mail-provider-receipt-123')).dueAt).toBe(notified.dueAt);
    await expect(f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode,
      notified.finalNoticeDeliveredAt!, 'different-mail-receipt')).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
  });

  it('invalidates an earlier notice after billing becomes unknown', async () => {
    const f = await fixture();
    const first = await f.ledger.observe(f.ownerId, 'expired');
    f.later(2 * day);
    await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode, f.now(), 'mail-provider-receipt-123');
    f.later(day);
    expect((await f.ledger.observe(f.ownerId, 'unknown')).finalNoticeDeliveredAt).toBeNull();
    f.at(first.dueAt! + 2 * day);
    expect((await f.ledger.observe(f.ownerId, 'expired')).finalNoticeDeliveredAt).toBeNull();
    expect(await f.ledger.eligibleAfterFreshCheck(f.ownerId, 'expired')).toBe(false);
  });

  it('cancels deletion on renewed membership and rejects notices from an old episode', async () => {
    const f = await fixture();
    const first = await f.ledger.observe(f.ownerId, 'expired');
    f.later(10 * day);
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
