import { env } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';
import { NoticeSubmissions } from '../src/notice-submissions';
import { RetentionLedger } from '../src/retention-ledger';
import type { NoticeEventSource } from '../src/notice-events';

const db = (env as unknown as { DB: D1Database }).DB;
const day = 24 * 60 * 60 * 1000;
const source: NoticeEventSource = {
  accountId: 'f9f79265f388666de8122cfb508d7776', zoneId: '023e105f4ecef8ad9ca31a8372d0c353',
  subscriptionId: '1830c4bb612e43c3af7f4cada31fbf3f', domain: 'example.com', sender: 'notice@example.com',
};
const email = 'owner@example.net';
const messageId = () => `mail-${crypto.randomUUID()}`;
const eventId = () => crypto.randomUUID();
const secret = () => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
  .replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');

async function fixture() {
  let now = Date.UTC(2026, 8, 23, 12);
  const ownerId = crypto.randomUUID();
  await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
    .bind(ownerId, `notice:${ownerId}`, now).run();
  await db.prepare('INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at) VALUES(?,?,?)')
    .bind(ownerId, crypto.randomUUID(), now).run();
  await db.prepare(`INSERT INTO pa_notice_contacts(owner_id,sealed_email,source,verified_at,updated_at)
    VALUES(?,?,'apple',?,?)`).bind(ownerId, new Uint8Array([1, 2, 3]).buffer, now, now).run();
  const ledger = new RetentionLedger(db, () => now);
  const expired = await ledger.observe(ownerId, 'expired');
  now = expired.dueAt! - 45 * day;
  const current = await ledger.observe(ownerId, 'expired');
  const candidate = { ownerId, episode: current.episode, revision: current.revision, dueAt: current.dueAt! };
  const contact = { email, updatedAt: Date.UTC(2026, 8, 23, 12) };
  const submissions = new NoticeSubmissions(db, secret(), () => now);
  const makeEvent = (id: string, recipient = email) => ({
    type: 'cf.email.sending.message.delivered',
    source: { type: 'email.sending', zoneId: source.zoneId, domain: source.domain },
    payload: { eventId: eventId(), messageId: id, sender: source.sender, recipient,
      terminal: true, delivery: { status: 'delivered' } },
    metadata: { accountId: source.accountId, eventSubscriptionId: source.subscriptionId,
      eventSchemaVersion: 1, eventTimestamp: new Date(now).toISOString() },
  });
  return { ownerId, ledger, candidate, contact, submissions, makeEvent, at: (value: number) => { now = value; } };
}

describe('final-notice submission evidence, with all external effects disabled', () => {
  it('promotes only matched delivery after a fresh expiry check, without deleting anything', async () => {
    const f = await fixture(); const id = messageId();
    expect(await f.submissions.promoteDelivered(id, async () => f.contact, async () => 'expired')).toBe(false);
    await f.submissions.recordSubmission(f.candidate, f.contact, id, source);
    expect(await f.submissions.promoteDelivered(id, async () => f.contact, async () => 'expired')).toBe(false);
    expect(await f.submissions.recordDelivery(f.makeEvent(id), source, async () => f.contact)).toBe(true);
    const delivered = await db.prepare('SELECT delivery_event_id FROM pa_notice_submissions WHERE message_id=?')
      .bind(id).first<{ delivery_event_id: string }>();
    const originalDue = f.candidate.dueAt;
    f.at(originalDue - 45 * day + 1);
    expect(await f.submissions.promoteDelivered(id, async () => f.contact, async () => 'expired')).toBe(true);
    const state = await db.prepare(`SELECT due_at,final_notice_delivered_at,final_notice_receipt
      FROM pa_retention WHERE owner_id=?`).bind(f.ownerId).first<{
        due_at: number; final_notice_delivered_at: number; final_notice_receipt: string;
      }>();
    expect(state).toMatchObject({ due_at: originalDue, final_notice_delivered_at: originalDue - 45 * day,
      final_notice_receipt: delivered?.delivery_event_id });
    expect(await f.submissions.promoteDelivered(id, async () => f.contact, async () => 'expired')).toBe(false);
    expect((await db.prepare('SELECT COUNT(*) AS n FROM pa_records WHERE owner_id=?')
      .bind(f.ownerId).first<{ n: number }>())?.n).toBe(0);
  });

  it('extends the carry-out deadline to at least 30 days after a late delivered notice', async () => {
    const f = await fixture(); const id = messageId();
    const deliveredAt = f.candidate.dueAt - 20 * day;
    f.at(deliveredAt);
    await f.ledger.observe(f.ownerId, 'expired');
    await f.submissions.recordSubmission(f.candidate, f.contact, id, source);
    expect(await f.submissions.recordDelivery(f.makeEvent(id), source, async () => f.contact)).toBe(true);
    f.at(deliveredAt + 1);
    expect(await f.submissions.promoteDelivered(id, async () => f.contact, async () => 'expired')).toBe(true);
    const state = await db.prepare('SELECT due_at FROM pa_retention WHERE owner_id=?')
      .bind(f.ownerId).first<{ due_at: number }>();
    expect(state?.due_at).toBe(deliveredAt + 30 * day);
  });

  it('refuses promotion for changed contact, renewal, unknown billing, or disabled owner', async () => {
    for (const change of ['contact', 'renewed', 'unknown', 'disabled'] as const) {
      const f = await fixture(); const id = messageId();
      await f.submissions.recordSubmission(f.candidate, f.contact, id, source);
      expect(await f.submissions.recordDelivery(f.makeEvent(id), source, async () => f.contact)).toBe(true);
      f.at(f.candidate.dueAt - 45 * day + 1);
      if (change === 'contact') await db.prepare('UPDATE pa_notice_contacts SET updated_at=updated_at+1 WHERE owner_id=?')
        .bind(f.ownerId).run();
      if (change === 'disabled') await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?')
        .bind(f.ownerId).run();
      const status = change === 'renewed' ? 'active' : change === 'unknown' ? 'unknown' : 'expired';
      const billingCheck = async () => {
        if (change === 'unknown') throw new Error('billing unavailable');
        return status;
      };
      expect(await f.submissions.promoteDelivered(id, async () => f.contact, billingCheck), change).toBe(false);
      const row = await db.prepare('SELECT final_notice_delivered_at FROM pa_retention WHERE owner_id=?')
        .bind(f.ownerId).first<{ final_notice_delivered_at: number | null }>();
      expect(row?.final_notice_delivered_at).toBeNull();
    }
  });

  it('does not promote stale-episode evidence after renewal and expiry again', async () => {
    const f = await fixture(); const id = messageId();
    await f.submissions.recordSubmission(f.candidate, f.contact, id, source);
    expect(await f.submissions.recordDelivery(f.makeEvent(id), source, async () => f.contact)).toBe(true);
    f.at(f.candidate.dueAt - 45 * day + 1);
    await f.ledger.observe(f.ownerId, 'active');
    f.at(f.candidate.dueAt - 45 * day + 2);
    await f.ledger.observe(f.ownerId, 'expired');
    f.at(f.candidate.dueAt - 45 * day + 3);
    expect(await f.submissions.promoteDelivered(id, async () => f.contact, async () => 'expired')).toBe(false);
  });

  it('stores only keyed recipient evidence and leaves retention unnotified', async () => {
    const f = await fixture(); const id = messageId();
    await f.submissions.recordSubmission(f.candidate, f.contact, id, source);
    const stored = await db.prepare('SELECT * FROM pa_notice_submissions WHERE message_id=?').bind(id).first();
    expect(stored).toMatchObject({ owner_id: f.ownerId, episode: f.candidate.episode,
      account_id: source.accountId, zone_id: source.zoneId, subscription_id: source.subscriptionId });
    expect(JSON.stringify(stored)).not.toContain(email);
    const event = f.makeEvent(id);
    expect(await f.submissions.recordDelivery(event, source, async () => f.contact)).toBe(true);
    expect(await f.submissions.recordDelivery(event, source, async () => f.contact)).toBe(false);
    expect((await f.ledger.listNoticeReviewCandidates()).length).toBe(1);
    const row = await db.prepare('SELECT final_notice_delivered_at FROM pa_retention WHERE owner_id=?')
      .bind(f.ownerId).first<{ final_notice_delivered_at: number | null }>();
    expect(row?.final_notice_delivered_at).toBeNull();
  });

  it('rejects wrong recipient, changed contact, source, revoked owner, and unknown billing', async () => {
    for (const change of ['recipient', 'contact', 'source', 'disabled', 'unknown'] as const) {
      const f = await fixture(); const id = messageId();
      await f.submissions.recordSubmission(f.candidate, f.contact, id, source);
      if (change === 'contact') await db.prepare('UPDATE pa_notice_contacts SET updated_at=updated_at+1 WHERE owner_id=?')
        .bind(f.ownerId).run();
      if (change === 'disabled') await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?')
        .bind(f.ownerId).run();
      if (change === 'unknown') {
        f.at(f.candidate.dueAt - 44 * day);
        await f.ledger.observe(f.ownerId, 'unknown');
      }
      const event = f.makeEvent(id, change === 'recipient' ? 'other@example.net' : email);
      if (change === 'unknown') event.metadata.eventTimestamp = new Date(f.candidate.dueAt - 45 * day).toISOString();
      const eventSource = change === 'source' ? { ...source, subscriptionId: '00000000000000000000000000000000' } : source;
      if (change === 'source') {
        await expect(f.submissions.recordDelivery(event, eventSource, async () => f.contact))
          .rejects.toMatchObject({ code: 'NOTICE_EVENT_INVALID' });
        continue;
      }
      const result = await f.submissions.recordDelivery(event, eventSource, async () => f.contact);
      expect(result, change).toBe(false);
    }
  });

  it('does not accept an unrecorded message or a stale expiry episode', async () => {
    const f = await fixture();
    await expect(f.submissions.recordDelivery(f.makeEvent(messageId()), source, async () => f.contact))
      .rejects.toMatchObject({ code: 'NOTICE_EVIDENCE_UNAVAILABLE' });
    const id = messageId();
    await f.submissions.recordSubmission(f.candidate, f.contact, id, source);
    f.at(f.candidate.dueAt - 44 * day);
    await f.ledger.observe(f.ownerId, 'active');
    expect(await f.submissions.recordDelivery(f.makeEvent(id), source, async () => null)).toBe(false);
  });
});
