import { env } from 'cloudflare:workers';
import { afterEach, describe, expect, it } from 'vitest';
import { NoticeDispatch, NOTICE_SUBJECT, NOTICE_TEXT } from '../src/notice-dispatch';
import { NoticeSubmissions } from '../src/notice-submissions';
import { RetentionLedger, type VerifiedMembershipStatus } from '../src/retention-ledger';
import type { NoticeEventSource } from '../src/notice-events';

const db = (env as unknown as { DB: D1Database }).DB;
const day = 24 * 60 * 60 * 1000;
const source: NoticeEventSource = {
  accountId: 'f9f79265f388666de8122cfb508d7776', zoneId: '023e105f4ecef8ad9ca31a8372d0c353',
  subscriptionId: '1830c4bb612e43c3af7f4cada31fbf3f', domain: 'example.com', sender: 'notice@example.com',
};
const createdOwners: string[] = [];
afterEach(async () => {
  for (const ownerId of createdOwners.splice(0)) {
    await db.prepare('UPDATE pa_owners SET disabled=1 WHERE owner_id=?').bind(ownerId).run();
  }
  await db.prepare("UPDATE pa_notice_scan_cursor SET due_at=0,owner_id='' WHERE id=1").run();
});
const secret = () => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
  .replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');

async function fixture() {
  let now = Date.UTC(2026, 8, 23, 12);
  const ownerId = crypto.randomUUID();
  createdOwners.push(ownerId);
  await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,?)')
    .bind(ownerId, `dispatch:${ownerId}`, now).run();
  await db.prepare('INSERT INTO pa_membership_links(owner_id,billing_account_id,created_at) VALUES(?,?,?)')
    .bind(ownerId, crypto.randomUUID(), now).run();
  await db.prepare(`INSERT INTO pa_notice_contacts(owner_id,sealed_email,source,verified_at,updated_at)
    VALUES(?,?,'apple',?,?)`).bind(ownerId, new Uint8Array([1]).buffer, now, now).run();
  const updatedAt = now;
  const ledger = new RetentionLedger(db, () => now);
  const expired = await ledger.observe(ownerId, 'expired');
  now = expired.dueAt! - 45 * day;
  await ledger.observe(ownerId, 'expired');
  const submissions = new NoticeSubmissions(db, secret(), () => now);
  const sent: Array<{ to: string; from: string; subject: string; text: string }> = [];
  let statusCalls = 0;
  let contactCalls = 0;
  let failNextSend = false;
  let status: (call: number) => VerifiedMembershipStatus = () => 'expired';
  let contact: (call: number) => { email: string; updatedAt: number } | null = () =>
    ({ email: 'owner@example.net', updatedAt });
  const dispatch = new NoticeDispatch({ ledger, submissions, source,
    mail: { send: async message => {
      if (failNextSend) { failNextSend = false; throw new Error('synthetic provider rejection'); }
      sent.push(message);
      return { messageId: `mail-${crypto.randomUUID()}` };
    } },
    statusForOwner: async () => status(++statusCalls),
    currentContact: async () => contact(++contactCalls),
  });
  return { ownerId, ledger, sent, dispatch, at: (value: number) => { now = value; },
    failNextSend: () => { failNextSend = true; },
    status: (next: typeof status) => { status = next; },
    contact: (next: typeof contact) => { contact = next; },
    updatedAt };
}

describe('gated final-notice dispatch, without external email', () => {
  it('sends a generic single notice, records submission but not delivery, and suppresses an immediate repeat', async () => {
    const f = await fixture();
    expect(await f.dispatch.run()).toEqual({ reviewed: 1, submitted: 1, skipped: 0, failed: 0 });
    expect(f.sent).toEqual([{ to: 'owner@example.net', from: source.sender,
      subject: NOTICE_SUBJECT, text: NOTICE_TEXT }]);
    expect(NOTICE_TEXT).not.toContain(f.ownerId);
    expect(await f.dispatch.run()).toEqual({ reviewed: 0, submitted: 0, skipped: 0, failed: 0 });
    const state = await db.prepare('SELECT final_notice_delivered_at FROM pa_retention WHERE owner_id=?')
      .bind(f.ownerId).first<{ final_notice_delivered_at: number | null }>();
    expect(state?.final_notice_delivered_at).toBeNull();
  });

  it('does not send after a fresh billing check becomes unknown', async () => {
    const f = await fixture();
    f.status(call => call === 1 ? 'expired' : 'unknown');
    expect(await f.dispatch.run()).toEqual({ reviewed: 1, submitted: 0, skipped: 1, failed: 0 });
    expect(f.sent).toEqual([]);
  });

  it('does not send to a contact replaced between the reservation and dispatch', async () => {
    const f = await fixture();
    f.contact(call => call === 1 ? { email: 'owner@example.net', updatedAt: f.updatedAt }
      : { email: 'new@example.net', updatedAt: f.updatedAt + 1 });
    expect(await f.dispatch.run()).toEqual({ reviewed: 1, submitted: 0, skipped: 1, failed: 0 });
    expect(f.sent).toEqual([]);
  });

  it('serializes concurrent scheduled dispatches before calling the provider', async () => {
    const f = await fixture();
    const results = await Promise.all([f.dispatch.run(), f.dispatch.run()]);
    expect(results.reduce((sum, result) => sum + result.submitted, 0)).toBe(1);
    expect(f.sent).toHaveLength(1);
  });

  it('continues to later owners after one provider rejection without claiming delivery', async () => {
    const f = await fixture();
    await fixture();
    f.failNextSend();
    expect(await f.dispatch.run()).toEqual({ reviewed: 2, submitted: 1, skipped: 0, failed: 1 });
    expect(f.sent).toHaveLength(1);
    const delivered = await db.prepare(`SELECT COUNT(*) AS n FROM pa_retention
      WHERE final_notice_delivered_at IS NOT NULL`).first<{ n: number }>();
    expect(delivered?.n).toBe(0);
  });

  it('advances past an owner with no contact instead of starving later owners', async () => {
    const first = await fixture();
    const second = await fixture();
    await db.prepare('DELETE FROM pa_notice_contacts WHERE owner_id=?').bind(first.ownerId).run();
    await db.prepare('UPDATE pa_retention SET due_at=due_at-? WHERE owner_id=?')
      .bind(day, first.ownerId).run();
    expect(await first.dispatch.run(1)).toMatchObject({ reviewed: 1, submitted: 0, skipped: 1 });
    expect(await first.dispatch.run(1)).toMatchObject({ reviewed: 1, submitted: 1 });
    expect(first.sent).toHaveLength(1);
    expect(second.sent).toHaveLength(0);
  });
});
