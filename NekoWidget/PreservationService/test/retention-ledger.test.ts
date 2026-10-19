import { env } from 'cloudflare:workers';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { RetentionLedger } from '../src/retention-ledger';

const db = (env as unknown as { DB: D1Database }).DB;
const fixtureOwners: string[] = [];
async function fixture(start = Date.UTC(2026, 8, 23, 12)) {
  let now = start;
  const ownerId = crypto.randomUUID(); const billingId = crypto.randomUUID();
  await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
    .bind(ownerId, `synthetic:${ownerId}`, now).run();
  await db.prepare('INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at) VALUES(?,?,?)')
    .bind(ownerId, billingId, now).run();
  fixtureOwners.push(ownerId);
  const ledger = new RetentionLedger(db, () => now);
  return { ownerId, billingId, ledger, at: (value: number) => { now = value; }, later: (value: number) => { now += value; }, now: () => now };
}
const day = 24 * 60 * 60 * 1000;

describe('scheduled retention observations', () => {
  let fixtureStart = 0;
  beforeEach(() => { fixtureStart = fixtureOwners.length; });
  afterEach(async () => {
    // This pool preserves rows between cases. Retire only this case's synthetic
    // owners so a whole-population scheduler never observes another fixture.
    for (const owner of fixtureOwners.slice(fixtureStart)) {
      await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?').bind(owner).run();
    }
    await db.prepare("UPDATE pa_retention_scan_cursor SET revision=0,last_owner_id='',retry_pending=0 WHERE singleton=1").run();
  });
  const state = (owner: string) => db.prepare('SELECT * FROM pa_retention WHERE owner_id=?').bind(owner).first();
  const generation = (owner: string) => db.prepare('SELECT generation FROM pa_owner_recovery_generations WHERE owner_id=?').bind(owner).first();

  it('distinguishes a newly inserted ledger row from its recovery generation trigger writes', async () => {
    const f = await fixture();
    const inserted = await db.prepare('INSERT OR IGNORE INTO pa_retention(owner_id) VALUES(?) RETURNING owner_id')
      .bind(f.ownerId).run();
    expect(inserted.meta.changes).toBeGreaterThan(1);
    expect(inserted.results).toEqual([{ owner_id: f.ownerId }]);
    const replay = await db.prepare('INSERT OR IGNORE INTO pa_retention(owner_id) VALUES(?) RETURNING owner_id')
      .bind(f.ownerId).run();
    expect(replay.results).toEqual([]);
  });

  it.each(['active', 'grace'] as const)('keeps stable %s history unchanged while checking authority and ACK every time', async status => {
    const f = await fixture();
    await f.ledger.observe(f.ownerId, status);
    const initial = await state(f.ownerId), before = await generation(f.ownerId);
    let checks = 0, acks = 0;
    const ledger = new RetentionLedger(db, f.now, { async copyCurrent() { acks++; } });
    for (const advance of [1, 60 * 60 * 1000, day]) {
      f.later(advance);
      expect(await ledger.refreshBatch(async billing => { expect(billing).toBe(f.billingId); checks++; return status; })).toBe(1);
      expect(await state(f.ownerId)).toEqual(initial);
      expect(await generation(f.ownerId)).toEqual(before);
    }
    expect([checks, acks]).toEqual([3, 3]);
    // Explicit observations retain the established hourly checkpoint contract.
    await ledger.observe(f.ownerId, status);
    expect(await state(f.ownerId)).toMatchObject({ revision: (initial!.revision as number) + 1, checked_at: f.now() });
  });

  it('commits status changes, later contract ends, expiry and unknown hourly observations', async () => {
    const f = await fixture();
    await f.ledger.refreshBatch(async () => 'active');
    const active = await state(f.ownerId);
    f.later(day);
    await f.ledger.refreshBatch(async () => 'grace');
    expect(await state(f.ownerId)).toMatchObject({ verified_status: 'grace', revision: (active!.revision as number) + 1, checked_at: f.now() });
    f.later(1);
    await f.ledger.refreshBatch(async () => ({ status: 'expired', endedAt: f.now() - 1 }));
    const expired = await state(f.ownerId);
    f.later(60 * 60 * 1000);
    await f.ledger.refreshBatch(async () => 'expired');
    expect(await state(f.ownerId)).toMatchObject({ revision: (expired!.revision as number) + 1, checked_at: f.now() });
    f.later(1);
    await f.ledger.refreshBatch(async () => ({ status: 'expired', endedAt: f.now() }));
    expect(await state(f.ownerId)).toMatchObject({ episode: (expired!.episode as number) + 1, expired_at: f.now() });
    f.later(1);
    await f.ledger.refreshBatch(async () => { throw Error('provider unavailable'); });
    const unknown = await state(f.ownerId);
    expect(unknown).toMatchObject({ verified_status: 'unknown', paused_at: f.now() });
    f.later(60 * 60 * 1000);
    await f.ledger.refreshBatch(async () => 'unknown');
    expect(await state(f.ownerId)).toMatchObject({ revision: (unknown!.revision as number) + 1, checked_at: f.now() });
    expect(await f.ledger.listNoticeReviewCandidates()).toEqual([]);
    expect(await f.ledger.eligibleAfterFreshCheck(f.ownerId, 'unknown')).toBe(false);
  });

  it('visits more than twenty stable owners, wraps and excludes disabled owners', async () => {
    const owners: Awaited<ReturnType<typeof fixture>>[] = [];
    for (let i = 0; i < 25; i++) {
      const f = await fixture(); await f.ledger.observe(f.ownerId, 'active'); owners.push(f);
    }
    owners.sort((a, b) => a.ownerId.localeCompare(b.ownerId));
    const disabled = await fixture();
    await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?').bind(disabled.ownerId).run();
    const visits: string[] = [];
    const provider = async (id: string) => { visits.push(id); return 'active' as const; };
    const ledger = new RetentionLedger(db, () => owners[0]!.now() + day);
    expect(await ledger.refreshBatch(provider)).toBe(20);
    expect(await ledger.refreshBatch(provider)).toBe(5);
    expect(visits).toEqual(owners.map(f => f.billingId));
    expect(await ledger.refreshBatch(provider)).toBe(20);
    expect(visits.slice(25)).toEqual(owners.slice(0, 20).map(f => f.billingId));
  });

  it('rebuilds a missing advisory cursor and rejects corrupt positions and invalid caps before billing', async () => {
    const f = await fixture();
    let calls = 0; const provider = async () => { calls++; return 'active' as const; };
    await db.prepare('DELETE FROM pa_retention_scan_cursor').run();
    expect(await f.ledger.refreshBatch(provider, 1)).toBe(1);
    for (const limit of [0, 101, 1.5, NaN]) await expect(f.ledger.refreshBatch(provider, limit)).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    await db.prepare("UPDATE pa_retention_scan_cursor SET last_owner_id='bad'").run();
    await expect(f.ledger.refreshBatch(provider)).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    await db.prepare("UPDATE pa_retention_scan_cursor SET last_owner_id='',revision=0,retry_pending=1").run();
    await expect(f.ledger.refreshBatch(provider)).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    await db.prepare("UPDATE pa_retention_scan_cursor SET last_owner_id='',revision=?").bind(Number.MAX_SAFE_INTEGER).run();
    await expect(f.ledger.refreshBatch(provider)).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    expect(calls).toBe(1);
  });

  it('fences a stale completion when another invocation consumes its pending retry', async () => {
    const f = await fixture(); const g = await fixture();
    await f.ledger.observe(f.ownerId, 'active'); await g.ledger.observe(g.ownerId, 'active');
    let release!: () => void, entered!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const ready = new Promise<void>(resolve => { entered = resolve; });
    const visits: string[] = [];
    const first = f.ledger.refreshBatch(async id => { visits.push(id); entered(); await gate; return 'active'; }, 1);
    await ready;
    expect(await g.ledger.refreshBatch(async id => { visits.push(id); return 'active'; }, 1)).toBe(1);
    release(); await expect(first).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    expect(visits).toHaveLength(2);
    expect(visits[0]).toBe(visits[1]);
    expect(await db.prepare('SELECT retry_pending FROM pa_retention_scan_cursor').first()).toEqual({ retry_pending: 0 });
    expect(await g.ledger.refreshBatch(async id => { visits.push(id); return 'active'; }, 1)).toBe(1);
    expect(new Set(visits)).toEqual(new Set([f.billingId, g.billingId]));
  });

  it('stops on ACK failure, retries once with a fresh invocation, then advances past a permanent failure', async () => {
    const owners = [await fixture(), await fixture(), await fixture()].sort((a, b) => a.ownerId.localeCompare(b.ownerId));
    for (const f of owners) await f.ledger.observe(f.ownerId, 'active');
    const acks: string[] = [];
    const ledger = new RetentionLedger(db, owners[0]!.now, { async copyCurrent(_db, owner) {
      acks.push(owner); if (owner === owners[0]!.ownerId) throw Error('uncertain recovery');
    } });
    await expect(ledger.refreshBatch(async () => 'active', 2)).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    expect(acks).toEqual([owners[0]!.ownerId]);
    expect(await db.prepare('SELECT retry_pending FROM pa_retention_scan_cursor').first()).toEqual({ retry_pending: 1 });
    await expect(ledger.refreshBatch(async () => 'active', 2)).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    expect(await db.prepare('SELECT retry_pending FROM pa_retention_scan_cursor').first()).toEqual({ retry_pending: 0 });
    expect(await ledger.refreshBatch(async () => 'active', 2)).toBe(2);
    expect(acks.slice(2)).toEqual(owners.slice(1).map(f => f.ownerId));
    expect(acks.filter(id => id === owners[0]!.ownerId)).toHaveLength(2);
  });

  it.each([18, 25])('visits all %i owners despite an eight-owner provider budget per invocation', async population => {
    const owners = [];
    for (let i = 0; i < population; i++) {
      const f = await fixture(); await f.ledger.observe(f.ownerId, 'active'); owners.push(f);
    }
    owners.sort((a, b) => a.ownerId.localeCompare(b.ownerId));
    let now = owners[0]!.now() + day, used = 0;
    const acked = new Set<string>(); const calls: string[][] = [];
    const consume = () => { if (++used > 32) throw Error('synthetic per-invocation service-binding budget'); };
    const ledger = new RetentionLedger(db, () => now, { async copyCurrent(_db, owner) {
      consume(); consume(); consume(); acked.add(owner);
    } });
    for (let invocation = 0; invocation < 6 && acked.size < population; invocation++) {
      used = 0; now++; const visits: string[] = []; calls.push(visits);
      try {
        await ledger.refreshBatch(async billing => { visits.push(billing); consume(); return 'active'; });
      } catch (error) { expect(error).toMatchObject({ code: 'RETENTION_UNAVAILABLE' }); }
      expect(new Set(visits).size).toBe(visits.length);
      if (invocation === 0) {
        expect(acked.size).toBe(8);
        expect(await db.prepare('SELECT last_owner_id,retry_pending FROM pa_retention_scan_cursor').first())
          .toEqual({ last_owner_id: owners[8]!.ownerId, retry_pending: 1 });
        // This owner has no expiry clock to pause. A failed check must not
        // invent either an expiry or a deletion deadline.
        expect(await state(owners[8]!.ownerId)).toMatchObject({ verified_status: 'unknown', paused_at: null, due_at: null });
      }
    }
    expect(calls[1]![0]).toBe(owners[8]!.billingId);
    expect(acked).toEqual(new Set(owners.map(f => f.ownerId)));
    expect(await db.prepare('SELECT retry_pending FROM pa_retention_scan_cursor').first()).toEqual({ retry_pending: 0 });
  });

  it('resumes a crashed pending owner first and skips it safely if it was disabled', async () => {
    const owners = [await fixture(), await fixture()].sort((a, b) => a.ownerId.localeCompare(b.ownerId));
    for (const f of owners) await f.ledger.observe(f.ownerId, 'active');
    await db.prepare('UPDATE pa_retention_scan_cursor SET last_owner_id=?,revision=7,retry_pending=1')
      .bind(owners[0]!.ownerId).run();
    const visits: string[] = [];
    const provider = async (id: string) => { visits.push(id); return 'active' as const; };
    expect(await owners[0]!.ledger.refreshBatch(provider, 1)).toBe(1);
    expect(visits).toEqual([owners[0]!.billingId]);
    await db.prepare('UPDATE pa_retention_scan_cursor SET last_owner_id=?,retry_pending=1')
      .bind(owners[0]!.ownerId).run();
    await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?').bind(owners[0]!.ownerId).run();
    expect(await owners[1]!.ledger.refreshBatch(provider)).toBe(1);
    expect(visits).toEqual(owners.map(f => f.billingId));
    expect(await db.prepare('SELECT retry_pending FROM pa_retention_scan_cursor').first()).toEqual({ retry_pending: 0 });
  });

  it.each(['disabled', 'epoch', 'retention'] as const)('rejects a %s change while billing is in flight', async kind => {
    const f = await fixture(); await f.ledger.observe(f.ownerId, 'active'); f.later(day);
    let acks = 0;
    const ledger = new RetentionLedger(db, f.now, { async copyCurrent() { acks++; } });
    await expect(ledger.refreshBatch(async () => {
      if (kind === 'disabled') await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?').bind(f.ownerId).run();
      if (kind === 'epoch') await db.prepare('UPDATE pa_owners SET epoch=epoch+1 WHERE owner_id=?').bind(f.ownerId).run();
      if (kind === 'retention') await f.ledger.observe(f.ownerId, 'expired');
      return 'active';
    })).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    expect(acks).toBe(0);
    expect(await state(f.ownerId)).toMatchObject({ verified_status: kind === 'retention' ? 'expired' : 'active' });
  });

  it('rejects a stale billing identity returned by an advisory scan', async () => {
    const f = await fixture(); await f.ledger.observe(f.ownerId, 'active'); f.later(day);
    const staleBilling = crypto.randomUUID(); let acks = 0;
    // Membership links are immutable in the real schema. Inject a stale scan
    // result to exercise the identity fence without bypassing those triggers.
    const staleScan = new Proxy(db, { get(target, property) {
      if (property !== 'prepare') return Reflect.get(target, property, target);
      return (sql: string) => {
        const statement = target.prepare(sql);
        if (!sql.includes('r.revision AS retention_revision')) return statement;
        return { bind: (...values: unknown[]) => {
          const bound = statement.bind(...values);
          return { all: async () => {
            const result = await bound.all();
            return { ...result, results: result.results.map(row => ({ ...row, billing_account_id: staleBilling })) };
          } };
        } };
      };
    } });
    const ledger = new RetentionLedger(staleScan, f.now, { async copyCurrent() { acks++; } });
    await expect(ledger.refreshBatch(async id => {
      expect(id).toBe(staleBilling); return 'active';
    })).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    expect(acks).toBe(0);
    expect(await state(f.ownerId)).toMatchObject({ verified_status: 'active' });
  });

  it('rejects an owner revocation during recovery at the final fence', async () => {
    const f = await fixture(); await f.ledger.observe(f.ownerId, 'active'); f.later(day);
    let calls = 0;
    const ledger = new RetentionLedger(db, f.now, { async copyCurrent() {
      calls++; await db.prepare('UPDATE pa_owners SET epoch=epoch+1 WHERE owner_id=?').bind(f.ownerId).run();
    } });
    await expect(ledger.refreshBatch(async () => 'active')).rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    expect(calls).toBe(1);
  });
});

describe('twelve-month preservation export period', () => {
  it('starts from a verified contract end and only extends an existing clock', async () => {
    const f = await fixture(); const end = f.now() - 10 * day;
    const first = await f.ledger.observeMembership(f.ownerId, { status: 'expired', endedAt: end });
    expect(first.expiredAt).toBe(end);
    expect(first.dueAt).toBe(Date.UTC(2027, 8, 13, 12));
    f.at(first.dueAt! - 40 * day);
    await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode, f.now(), 'synthetic-old-end-receipt');
    const laterEnd = end + day;
    const later = await f.ledger.observeMembership(f.ownerId, { status: 'expired', endedAt: laterEnd });
    expect(later.episode).toBe(first.episode + 1);
    expect(later.dueAt).toBeGreaterThan(first.dueAt!);
    expect(later.finalNoticeDeliveredAt).toBeNull();
    expect((await f.ledger.observeMembership(f.ownerId, { status: 'expired', endedAt: end })).dueAt).toBe(later.dueAt);
    await expect(f.ledger.observeMembership(f.ownerId, { status: 'expired', endedAt: f.now() + 1 }))
      .rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    f.later(1);
    expect((await f.ledger.observeMembership(f.ownerId, { status: 'unknown', endedAt: null })).pausedAt).toBe(f.now());
    f.later(1);
    expect((await f.ledger.observeMembership(f.ownerId, { status: 'active', endedAt: null })).dueAt).toBeNull();
  });
  it('coalesces repeated unchanged observations without delaying a changed billing state', async () => {
    const f = await fixture();
    const first = await f.ledger.observe(f.ownerId, 'expired');
    const generation = await db.prepare(`SELECT generation FROM pa_owner_recovery_generations
      WHERE owner_id=?`).bind(f.ownerId).first<{ generation: number }>();
    f.later(1);
    const repeated = await f.ledger.observe(f.ownerId, 'expired');
    expect(repeated.revision).toBe(first.revision);
    expect(repeated.checkedAt).toBe(first.checkedAt);
    expect(await db.prepare('SELECT generation FROM pa_owner_recovery_generations WHERE owner_id=?')
      .bind(f.ownerId).first()).toEqual(generation);
    f.later(60 * 60 * 1000);
    const refreshed = await f.ledger.observe(f.ownerId, 'expired');
    expect(refreshed.revision).toBe(first.revision + 1);
    expect(refreshed.checkedAt).toBe(f.now());
    f.later(1);
    const paused = await f.ledger.observe(f.ownerId, 'unknown');
    expect(paused.status).toBe('unknown');
    expect(paused.pausedAt).toBe(f.now());
    expect(paused.revision).toBe(refreshed.revision + 1);
    f.later(1);
    const stillPaused = await f.ledger.observe(f.ownerId, 'unknown');
    expect(stillPaused.revision).toBe(paused.revision);
    expect(stillPaused.pausedAt).toBe(paused.pausedAt);
    f.later(1);
    const renewed = await f.ledger.observe(f.ownerId, 'active');
    expect(renewed.revision).toBe(paused.revision + 1);
    expect(renewed.dueAt).toBeNull();
  });
  it('rotates advisory expiry review past ineligible owners without granting deletion', async () => {
    const f = await fixture();
    const g = await fixture();
    const h = await fixture();
    const first = await f.ledger.observe(f.ownerId, 'expired');
    await f.ledger.observe(g.ownerId, 'expired');
    await f.ledger.observe(h.ownerId, 'expired');
    f.at(first.dueAt! - 45 * day);
    await f.ledger.markFinalNoticeDelivered(f.ownerId, first.episode, f.now(), 'synthetic-delivery-receipt-f');
    await f.ledger.markFinalNoticeDelivered(h.ownerId, first.episode, f.now(), 'synthetic-delivery-receipt-h');
    // The oldest owner without a receipt cannot hold the one-item cursor.
    f.at(first.dueAt!);
    const expected = [f.ownerId, h.ownerId].sort();
    expect((await f.ledger.nextExpiryReviewCandidates(1)).map(item => item.ownerId)).toEqual([expected[0]]);
    expect((await f.ledger.nextExpiryReviewCandidates(1)).map(item => item.ownerId)).toEqual([expected[1]]);
    expect((await f.ledger.nextExpiryReviewCandidates(1)).map(item => item.ownerId)).toEqual([expected[0]]);
    f.later(1);
    await f.ledger.observe(expected[0]!, 'active');
    expect((await f.ledger.nextExpiryReviewCandidates(1)).map(item => item.ownerId)).toEqual([expected[1]]);
    await expect(f.ledger.nextExpiryReviewCandidates(101))
      .rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
    await db.prepare("UPDATE pa_expiry_review_cursor SET owner_id='invalid' WHERE id=1").run();
    await expect(f.ledger.nextExpiryReviewCandidates(1))
      .rejects.toMatchObject({ code: 'RETENTION_UNAVAILABLE' });
  });
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
