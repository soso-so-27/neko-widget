import { contactEmailValid, ServiceError } from './contracts';
import { parseDeliveredNoticeEvent, type NoticeEventSource } from './notice-events';
import { RetentionLedger, type NoticeReviewCandidate, type VerifiedMembershipStatus } from './retention-ledger';

const day = 24 * 60 * 60 * 1000;
const ownerPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const messagePattern = /^[A-Za-z0-9._:-]{8,256}$/u;
const hex32 = /^[0-9a-f]{32}$/u;
const domainPattern = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/u;
const unavailable = () => new ServiceError('NOTICE_EVIDENCE_UNAVAILABLE', 503);

export type VerifiedNoticeContact = { email: string; updatedAt: number };
type SubmissionRow = {
  message_id: string; owner_id: string; episode: number; retention_revision: number; due_at: number;
  contact_updated_at: number; recipient_tag: string; account_id: string; zone_id: string;
  subscription_id: string; domain: string; sender: string; submitted_at: number;
  delivered_at: number | null; delivery_event_id: string | null;
};
type PromotionRow = SubmissionRow & { billing_account_id: string };

function validSource(source: NoticeEventSource): boolean {
  return !!source && typeof source.accountId === 'string' && hex32.test(source.accountId)
    && typeof source.zoneId === 'string' && hex32.test(source.zoneId)
    && typeof source.subscriptionId === 'string' && hex32.test(source.subscriptionId)
    && typeof source.domain === 'string' && source.domain.length <= 253
    && domainPattern.test(source.domain) && contactEmailValid(source.sender)
    && source.sender.endsWith(`@${source.domain}`);
}

/** Evidence-only ledger. Recording a delivery here does not mark retention,
 * send mail, or authorize deletion. The caller must use a private Queue and a
 * fresh owner/episode/contact check, never an HTTP request parameter.
 */
export class NoticeSubmissions {
  private readonly key: Promise<CryptoKey>;

  constructor(private readonly db: D1Database, secret: string, private readonly now: () => number) {
    if (typeof secret !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(secret)) throw unavailable();
    const raw = Uint8Array.from(atob(secret.replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0));
    if (raw.length !== 32) throw unavailable();
    this.key = crypto.subtle.importKey('raw', raw as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    raw.fill(0);
  }

  private async recipientTag(email: string): Promise<string> {
    if (!contactEmailValid(email)) throw unavailable();
    const bytes = new TextEncoder().encode(`neko-preservation-notice-recipient-v1\0${email}`);
    const digest = new Uint8Array(await crypto.subtle.sign('HMAC', await this.key, bytes));
    return [...digest].map(byte => byte.toString(16).padStart(2, '0')).join('');
  }

  /** Called only after the mail provider returns its messageId. If this write
   * fails, an event cannot be matched; a later retry must send a new notice.
   */
  async recordSubmission(candidate: NoticeReviewCandidate, contact: VerifiedNoticeContact,
    messageId: string, source: NoticeEventSource): Promise<void> {
    const now = this.now();
    if (!candidate || !ownerPattern.test(candidate.ownerId) || !Number.isSafeInteger(candidate.episode)
        || candidate.episode < 1 || !Number.isSafeInteger(candidate.revision) || candidate.revision < 1
        || !Number.isSafeInteger(candidate.dueAt) || candidate.dueAt <= 0
        || !contact || !Number.isSafeInteger(contact.updatedAt) || contact.updatedAt < 0
        || contact.updatedAt > now || !messagePattern.test(messageId) || !validSource(source)
        || !Number.isSafeInteger(now) || now <= 0) throw unavailable();
    const tag = await this.recipientTag(contact.email);
    const result = await this.db.prepare(`INSERT INTO pa_notice_submissions
      (message_id,owner_id,episode,retention_revision,due_at,contact_updated_at,recipient_tag,
       account_id,zone_id,subscription_id,domain,sender,submitted_at)
      SELECT ?,r.owner_id,r.episode,r.revision,r.due_at,c.updated_at,?,?,?,?,?,?,?
      FROM pa_retention r JOIN pa_notice_contacts c ON c.owner_id=r.owner_id
        JOIN pa_owners o ON o.owner_id=r.owner_id
        JOIN pa_membership_links l ON l.owner_id=r.owner_id
      WHERE r.owner_id=? AND r.episode=? AND r.revision>=? AND r.due_at=?
        AND r.verified_status='expired' AND r.paused_at IS NULL
        AND r.final_notice_delivered_at IS NULL AND r.checked_at>=? AND r.checked_at<=?
        AND r.due_at<=? AND r.notice_not_before_at<=?
        AND c.updated_at=? AND c.source='apple' AND o.disabled=0`)
      .bind(messageId, tag, source.accountId, source.zoneId, source.subscriptionId,
        source.domain, source.sender, now, candidate.ownerId, candidate.episode,
        candidate.revision, candidate.dueAt, Math.max(0, now - day), now, now + 60 * day,
        now, contact.updatedAt).run();
    if (result.meta.changes !== 1) throw unavailable();
  }

  /** Stores only a matched mail-server acceptance. No retention state changes.
   * An unknown message must be retried by the Queue, not acknowledged as absent.
   */
  async recordDelivery(rawEvent: unknown, source: NoticeEventSource,
    currentContact: (candidate: NoticeReviewCandidate) => Promise<VerifiedNoticeContact | null>): Promise<boolean> {
    const now = this.now();
    const event = parseDeliveredNoticeEvent(rawEvent, source, now);
    const row = await this.db.prepare('SELECT * FROM pa_notice_submissions WHERE message_id=?')
      .bind(event.messageId).first<SubmissionRow>();
    if (!row) throw unavailable();
    if (row.account_id !== source.accountId || row.zone_id !== source.zoneId
        || row.subscription_id !== source.subscriptionId || row.domain !== source.domain
        || row.sender !== source.sender || event.acceptedAt < row.submitted_at) return false;
    // A replay is not new evidence. In particular it must never be reported as
    // current after a contact change or renewed membership.
    if (row.delivered_at !== null) return false;
    const candidate = { ownerId: row.owner_id, episode: row.episode,
      revision: row.retention_revision, dueAt: row.due_at };
    const contact = await currentContact(candidate);
    if (!contact || contact.updatedAt !== row.contact_updated_at
        || await this.recipientTag(contact.email) !== row.recipient_tag
        || await this.recipientTag(event.recipient) !== row.recipient_tag) return false;
    const result = await this.db.prepare(`UPDATE pa_notice_submissions SET delivered_at=?,delivery_event_id=?
      WHERE message_id=? AND delivered_at IS NULL AND recipient_tag=? AND contact_updated_at=?
        AND EXISTS (SELECT 1 FROM pa_retention r JOIN pa_owners o ON o.owner_id=r.owner_id
          JOIN pa_notice_contacts c ON c.owner_id=r.owner_id
          JOIN pa_membership_links l ON l.owner_id=r.owner_id
          WHERE r.owner_id=pa_notice_submissions.owner_id AND o.disabled=0 AND c.source='apple'
            AND c.updated_at=pa_notice_submissions.contact_updated_at
            AND r.episode=pa_notice_submissions.episode AND r.revision>=pa_notice_submissions.retention_revision
            AND r.due_at=pa_notice_submissions.due_at AND r.verified_status='expired'
            AND r.paused_at IS NULL AND r.final_notice_delivered_at IS NULL
            AND r.notice_not_before_at<=? AND r.notice_not_before_at<=r.checked_at
            AND r.checked_at>=? AND r.checked_at<=?)`)
      .bind(event.acceptedAt, event.eventId, event.messageId, row.recipient_tag,
        row.contact_updated_at, event.acceptedAt, Math.max(0, now - day), now).run();
    return result.meta.changes === 1;
  }

  /** Promotes a matched delivery to the retention ledger only after a fresh
   * private billing observation. This does not send mail or delete records.
   * The SQL fence rechecks contact, episode and billing revision atomically.
   */
  async promoteDelivered(messageId: string,
    currentContact: (candidate: NoticeReviewCandidate) => Promise<VerifiedNoticeContact | null>,
    statusForBillingAccount: (billingAccountId: string) => Promise<VerifiedMembershipStatus>): Promise<boolean> {
    const now = this.now();
    if (!messagePattern.test(messageId) || !Number.isSafeInteger(now) || now <= 0) throw unavailable();
    const row = await this.db.prepare(`SELECT s.*,l.billing_account_id FROM pa_notice_submissions s
      JOIN pa_membership_links l ON l.owner_id=s.owner_id
      JOIN pa_owners o ON o.owner_id=s.owner_id
      WHERE s.message_id=? AND o.disabled=0`).bind(messageId).first<PromotionRow>();
    if (!row || row.delivered_at === null || row.delivery_event_id === null) return false;
    const candidate = { ownerId: row.owner_id, episode: row.episode,
      revision: row.retention_revision, dueAt: row.due_at };
    const contact = await currentContact(candidate);
    if (!contact || contact.updatedAt !== row.contact_updated_at
        || await this.recipientTag(contact.email) !== row.recipient_tag) return false;
    let status: VerifiedMembershipStatus;
    try { status = await statusForBillingAccount(row.billing_account_id); }
    catch { status = 'unknown'; }
    const observed = await new RetentionLedger(this.db, this.now).observe(row.owner_id, status);
    if (observed.status !== 'expired' || observed.pausedAt !== null
        || observed.episode !== row.episode || observed.dueAt !== row.due_at
        || row.delivered_at > now || row.delivered_at < now - 60 * day) return false;
    const noticeDueAt = row.delivered_at + 30 * day;
    if (!Number.isSafeInteger(noticeDueAt)) throw unavailable();
    const result = await this.db.prepare(`UPDATE pa_retention SET revision=revision+1,
      due_at=CASE WHEN due_at>? THEN due_at ELSE ? END,
      final_notice_delivered_at=?,final_notice_receipt=?
      WHERE owner_id=? AND revision=? AND episode=? AND due_at=?
        AND verified_status='expired' AND paused_at IS NULL
        AND final_notice_delivered_at IS NULL AND checked_at=?
        AND notice_not_before_at<=? AND notice_not_before_at<=checked_at
        AND EXISTS (SELECT 1 FROM pa_notice_submissions s
          JOIN pa_notice_contacts c ON c.owner_id=s.owner_id
          JOIN pa_owners o ON o.owner_id=s.owner_id
          JOIN pa_membership_links l ON l.owner_id=s.owner_id
          WHERE s.message_id=? AND s.owner_id=pa_retention.owner_id
            AND s.episode=pa_retention.episode AND s.due_at=pa_retention.due_at
            AND s.retention_revision<=pa_retention.revision
            AND s.delivered_at=? AND s.delivery_event_id IS NOT NULL
            AND s.recipient_tag=? AND s.contact_updated_at=?
            AND c.updated_at=s.contact_updated_at AND c.source='apple'
            AND l.billing_account_id=? AND o.disabled=0)`)
      .bind(noticeDueAt, noticeDueAt, row.delivered_at, row.delivery_event_id,
        row.owner_id, observed.revision, row.episode, row.due_at,
        observed.checkedAt, row.delivered_at, messageId, row.delivered_at,
        row.recipient_tag, row.contact_updated_at, row.billing_account_id).run();
    return result.meta.changes === 1;
  }
}
