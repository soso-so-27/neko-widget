import { contactEmailValid, ServiceError } from './contracts';
import { parseDeliveredNoticeEvent, type NoticeEventSource } from './notice-events';
import { NOTICE_DELIVERY_EVIDENCE_WINDOW_MS, NOTICE_SUBMISSION_RETRY_DELAY_MS, RetentionLedger,
  type ExpiryReviewCandidate, type NoticeReviewCandidate, type VerifiedMembershipStatus } from './retention-ledger';
import type { OwnerRecoveryCopy } from './owner-recovery-copy';

const day = 24 * 60 * 60 * 1000;
const ownerPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const messagePattern = /^[A-Za-z0-9._:-]{8,256}$/u;
const claimPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const hex32 = /^[0-9a-f]{32}$/u;
const domainPattern = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/u;
const unavailable = () => new ServiceError('NOTICE_EVIDENCE_UNAVAILABLE', 503);

export type VerifiedNoticeContact = { email: string; updatedAt: number };
export type PendingNoticePromotion = { messageId: string; deliveredAt: number };
type SubmissionRow = {
  message_id: string; owner_id: string; episode: number; retention_revision: number; due_at: number;
  evidence_version: number;
  contact_updated_at: number; recipient_tag: string; account_id: string; zone_id: string;
  subscription_id: string; domain: string; sender: string; submitted_at: number;
  claim_started_at: number | null;
  provider_accepted_at: number | null;
  delivered_at: number | null; delivery_event_id: string | null;
};
type PromotionRow = SubmissionRow & { billing_account_id: string };

export function validNoticeEventSource(source: NoticeEventSource): boolean {
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

  constructor(private readonly db: D1Database, secret: string, private readonly now: () => number,
    private readonly ownerRecovery?: OwnerRecoveryCopy) {
    if (typeof secret !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(secret)) throw unavailable();
    const raw = Uint8Array.from(atob(secret.replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0));
    if (raw.length !== 32) throw unavailable();
    this.key = crypto.subtle.importKey('raw', raw as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    raw.fill(0);
  }

  private async recipientTag(ownerId: string, email: string): Promise<string> {
    if (!ownerPattern.test(ownerId) || !contactEmailValid(email)) throw unavailable();
    // The tag compares notices within one owner, without linking owners who
    // happen to use the same address in a database snapshot.
    const bytes = new TextEncoder().encode(`neko-preservation-notice-recipient-v1\0${JSON.stringify([ownerId, email])}`);
    const digest = new Uint8Array(await crypto.subtle.sign('HMAC', await this.key, bytes));
    return [...digest].map(byte => byte.toString(16).padStart(2, '0')).join('');
  }

  /** Reserve a single send before calling the mail provider. A crashed or
   * ambiguous send waits a day before another attempt; this is not proof that
   * a message was sent or delivered. The unique owner row serializes callers.
   */
  async claimNotice(candidate: NoticeReviewCandidate, contact: VerifiedNoticeContact): Promise<string | null> {
    const now = this.now();
    if (!candidate || !ownerPattern.test(candidate.ownerId) || !Number.isSafeInteger(candidate.episode)
        || candidate.episode < 1 || !Number.isSafeInteger(candidate.revision) || candidate.revision < 1
        || !Number.isSafeInteger(candidate.dueAt) || candidate.dueAt <= 0
        || !contact || !contactEmailValid(contact.email) || !Number.isSafeInteger(contact.updatedAt)
        || contact.updatedAt < 0 || contact.updatedAt > now || !Number.isSafeInteger(now) || now <= 0
        || !Number.isSafeInteger(now + day)) throw unavailable();
    const claimId = crypto.randomUUID();
    const recipientTag = await this.recipientTag(candidate.ownerId, contact.email);
    const result = await this.db.prepare(`INSERT INTO pa_notice_claims
      (owner_id,claim_id,episode,due_at,contact_updated_at,recipient_tag,claimed_at,expires_at,evidence_version)
      SELECT r.owner_id,?,r.episode,r.due_at,c.updated_at,?,?,?,2
      FROM pa_retention r JOIN pa_notice_contacts c ON c.owner_id=r.owner_id
        JOIN pa_owners o ON o.owner_id=r.owner_id
        JOIN pa_membership_links l ON l.owner_id=r.owner_id
      WHERE r.owner_id=? AND r.episode=? AND r.revision>=? AND r.due_at=?
        AND r.verified_status='expired' AND r.paused_at IS NULL
        AND r.final_notice_delivered_at IS NULL AND r.checked_at>=? AND r.checked_at<=?
        AND r.due_at<=? AND r.notice_not_before_at<=?
        AND c.updated_at=? AND c.source='apple' AND o.disabled=0
        AND NOT EXISTS (SELECT 1 FROM pa_notice_submissions s
          WHERE s.owner_id=r.owner_id AND s.evidence_version=2
            AND s.episode=r.episode AND s.due_at=r.due_at
            AND s.contact_updated_at=c.updated_at AND s.submitted_at>=r.notice_not_before_at
            AND (s.delivered_at>=? OR (s.delivered_at IS NULL AND s.submitted_at>=?)))
      ON CONFLICT(owner_id) DO UPDATE SET claim_id=excluded.claim_id,
        episode=excluded.episode,due_at=excluded.due_at,
        contact_updated_at=excluded.contact_updated_at,recipient_tag=excluded.recipient_tag,
        claimed_at=excluded.claimed_at,expires_at=excluded.expires_at,
        evidence_version=excluded.evidence_version
      WHERE pa_notice_claims.expires_at<=excluded.claimed_at
        OR pa_notice_claims.evidence_version<>2
        OR pa_notice_claims.episode<>excluded.episode
        OR pa_notice_claims.due_at<>excluded.due_at`)
      .bind(claimId, recipientTag, now, now + day, candidate.ownerId, candidate.episode,
        candidate.revision, candidate.dueAt, Math.max(0, now - day), now,
        now + 60 * day, now, contact.updatedAt,
        Math.max(0, now - NOTICE_DELIVERY_EVIDENCE_WINDOW_MS),
        Math.max(0, now - NOTICE_SUBMISSION_RETRY_DELAY_MS)).run();
    return result.meta.changes === 1 ? claimId : null;
  }

  /** Recheck an active reservation after fresh billing/contact verification,
   * immediately before invoking the external mail provider. The provider call
   * cannot be made atomic with D1, so the email must contain no private data.
   */
  async readyForDispatch(candidate: NoticeReviewCandidate, contact: VerifiedNoticeContact,
    claimId: string): Promise<boolean> {
    const now = this.now();
    if (!candidate || !ownerPattern.test(candidate.ownerId) || !Number.isSafeInteger(candidate.episode)
        || candidate.episode < 1 || !Number.isSafeInteger(candidate.revision) || candidate.revision < 1
        || !Number.isSafeInteger(candidate.dueAt) || candidate.dueAt <= 0
        || !contact || !contactEmailValid(contact.email) || !Number.isSafeInteger(contact.updatedAt)
        || contact.updatedAt < 0 || contact.updatedAt > now || !claimPattern.test(claimId)
        || !Number.isSafeInteger(now) || now <= 0) throw unavailable();
    const tag = await this.recipientTag(candidate.ownerId, contact.email);
    const row = await this.db.prepare(`SELECT 1 AS ready FROM pa_notice_claims q
      JOIN pa_retention r ON r.owner_id=q.owner_id
      JOIN pa_notice_contacts c ON c.owner_id=q.owner_id
      JOIN pa_owners o ON o.owner_id=q.owner_id
      JOIN pa_membership_links l ON l.owner_id=q.owner_id
      WHERE q.owner_id=? AND q.claim_id=? AND q.evidence_version=2
        AND q.episode=? AND q.due_at=?
        AND q.contact_updated_at=? AND q.recipient_tag=?
        AND q.claimed_at<=? AND q.expires_at>?
        AND r.episode=q.episode AND r.revision>=? AND r.due_at=q.due_at
        AND r.verified_status='expired' AND r.paused_at IS NULL
        AND r.final_notice_delivered_at IS NULL AND r.checked_at>=? AND r.checked_at<=?
        AND r.due_at<=? AND r.notice_not_before_at<=?
        AND c.updated_at=q.contact_updated_at AND c.source='apple' AND o.disabled=0
        AND NOT EXISTS (SELECT 1 FROM pa_notice_submissions s WHERE s.claim_id=q.claim_id)`)
      .bind(candidate.ownerId, claimId, candidate.episode, candidate.dueAt,
        contact.updatedAt, tag, now, now, candidate.revision, Math.max(0, now - day), now,
        now + 60 * day, now).first<{ ready: number }>();
    return !!row;
  }

  /** Called only after the mail provider returns its messageId. If this write
   * fails, an event cannot be matched; a later retry must send a new notice.
   */
  async recordSubmission(candidate: NoticeReviewCandidate, contact: VerifiedNoticeContact,
    claimId: string, messageId: string, source: NoticeEventSource): Promise<void> {
    const now = this.now();
    if (!candidate || !ownerPattern.test(candidate.ownerId) || !Number.isSafeInteger(candidate.episode)
        || candidate.episode < 1 || !Number.isSafeInteger(candidate.revision) || candidate.revision < 1
        || !Number.isSafeInteger(candidate.dueAt) || candidate.dueAt <= 0
        || !contact || !Number.isSafeInteger(contact.updatedAt) || contact.updatedAt < 0
        || contact.updatedAt > now || !claimPattern.test(claimId)
        || !messagePattern.test(messageId) || !validNoticeEventSource(source)
        || !Number.isSafeInteger(now) || now <= 0) throw unavailable();
    const tag = await this.recipientTag(candidate.ownerId, contact.email);
    const result = await this.db.prepare(`INSERT INTO pa_notice_submissions
      (message_id,owner_id,episode,retention_revision,due_at,contact_updated_at,recipient_tag,
       account_id,zone_id,subscription_id,domain,sender,submitted_at,claim_id,claim_started_at,evidence_version)
      SELECT ?,r.owner_id,r.episode,r.revision,r.due_at,c.updated_at,?,?,?,?,?,?,?,?,q.claimed_at,2
      FROM pa_retention r JOIN pa_notice_contacts c ON c.owner_id=r.owner_id
        JOIN pa_owners o ON o.owner_id=r.owner_id
        JOIN pa_membership_links l ON l.owner_id=r.owner_id
        JOIN pa_notice_claims q ON q.owner_id=r.owner_id
      WHERE r.owner_id=? AND r.episode=? AND r.revision>=? AND r.due_at=?
        AND r.verified_status='expired' AND r.paused_at IS NULL
        AND r.final_notice_delivered_at IS NULL AND r.checked_at>=? AND r.checked_at<=?
        AND r.due_at<=? AND r.notice_not_before_at<=?
        AND c.updated_at=? AND c.source='apple' AND o.disabled=0
        AND q.claim_id=? AND q.evidence_version=2
        AND q.episode=r.episode AND q.due_at=r.due_at
        AND q.contact_updated_at=c.updated_at AND q.recipient_tag=?
        AND q.claimed_at<=? AND q.expires_at>?`)
      .bind(messageId, tag, source.accountId, source.zoneId, source.subscriptionId,
        source.domain, source.sender, now, claimId, candidate.ownerId, candidate.episode,
        candidate.revision, candidate.dueAt, Math.max(0, now - day), now, now + 60 * day,
        now, contact.updatedAt, claimId, tag, now, now).run();
    if (result.meta.changes !== 1) throw unavailable();
    await this.db.prepare('DELETE FROM pa_notice_claims WHERE claim_id=?').bind(claimId).run();
  }

  /** Stores only a matched mail-server acceptance. No retention state changes.
   * An unknown message must be retried by the Queue, not acknowledged as absent.
   */
  async ownerForSubmission(messageId: string, source: NoticeEventSource): Promise<string> {
    if (!messagePattern.test(messageId) || !validNoticeEventSource(source)) throw unavailable();
    const row = await this.db.prepare(`SELECT owner_id FROM pa_notice_submissions
      WHERE message_id=? AND account_id=? AND zone_id=? AND subscription_id=?
        AND domain=? AND sender=?`)
      .bind(messageId, source.accountId, source.zoneId, source.subscriptionId,
        source.domain, source.sender).first<{ owner_id: string }>();
    if (!row || !ownerPattern.test(row.owner_id)) throw unavailable();
    return row.owner_id;
  }

  async recordDelivery(rawEvent: unknown, source: NoticeEventSource,
    currentContact: (candidate: NoticeReviewCandidate) => Promise<VerifiedNoticeContact | null>): Promise<boolean> {
    const now = this.now();
    const event = parseDeliveredNoticeEvent(rawEvent, source, now);
    const row = await this.db.prepare('SELECT * FROM pa_notice_submissions WHERE message_id=?')
      .bind(event.messageId).first<SubmissionRow>();
    if (!row) throw unavailable();
    if (row.evidence_version !== 2 || row.account_id !== source.accountId || row.zone_id !== source.zoneId
        || row.subscription_id !== source.subscriptionId || row.domain !== source.domain
        || row.sender !== source.sender
        || event.acceptedAt < (row.claim_started_at ?? row.submitted_at)) return false;
    // A replay is not new evidence. In particular it must never be reported as
    // current after a contact change or renewed membership.
    if (row.delivered_at !== null) return false;
    const candidate = { ownerId: row.owner_id, episode: row.episode,
      revision: row.retention_revision, dueAt: row.due_at };
    const contact = await currentContact(candidate);
    if (!contact || contact.updatedAt !== row.contact_updated_at
        || await this.recipientTag(row.owner_id, contact.email) !== row.recipient_tag
        || await this.recipientTag(row.owner_id, event.recipient) !== row.recipient_tag) return false;
    // The provider may accept the mail before send() returns and D1 records
    // submitted_at. The pre-existing table constraint requires delivered_at
    // >= submitted_at, so use the later time for the deletion grace period and
    // retain the actual provider timestamp separately for audit.
    const safeDeliveredAt = Math.max(event.acceptedAt, row.submitted_at);
    const result = await this.db.prepare(`UPDATE pa_notice_submissions
      SET delivered_at=?,provider_accepted_at=?,delivery_event_id=?
      WHERE message_id=? AND evidence_version=2 AND delivered_at IS NULL
        AND recipient_tag=? AND contact_updated_at=?
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
      .bind(safeDeliveredAt, event.acceptedAt, event.eventId, event.messageId, row.recipient_tag,
        row.contact_updated_at, event.acceptedAt, Math.max(0, now - day), now).run();
    return result.meta.changes === 1;
  }

  /** Bounded reconciliation for a delivery recorded before a billing outage
   * or a Queue retry. A cursor prevents an ineligible old row from starving
   * later messages. This only lists possible evidence; promotion rechecks all
   * owner, billing, contact, episode and grace-period conditions.
   */
  async listPendingPromotions(after: PendingNoticePromotion | null = null,
    limit = 100): Promise<PendingNoticePromotion[]> {
    const now = this.now();
    if (!Number.isSafeInteger(now) || now <= 0 || !Number.isSafeInteger(limit)
        || limit < 1 || limit > 100 || (after !== null &&
        (!messagePattern.test(after.messageId) || !Number.isSafeInteger(after.deliveredAt)
          || after.deliveredAt <= 0))) throw unavailable();
    const rows = await this.db.prepare(`SELECT s.message_id,s.delivered_at
      FROM pa_notice_submissions s JOIN pa_retention r ON r.owner_id=s.owner_id
      JOIN pa_notice_contacts c ON c.owner_id=s.owner_id
      JOIN pa_owners o ON o.owner_id=s.owner_id
      JOIN pa_membership_links l ON l.owner_id=s.owner_id
      WHERE s.evidence_version=2 AND s.delivered_at IS NOT NULL AND s.delivery_event_id IS NOT NULL
        AND s.delivered_at>=? AND s.delivered_at<=?
        AND (s.delivered_at>? OR (s.delivered_at=? AND s.message_id>?))
        AND r.episode=s.episode AND r.due_at=s.due_at
        AND r.verified_status='expired' AND r.paused_at IS NULL
        AND r.final_notice_delivered_at IS NULL
        AND r.notice_not_before_at<=s.delivered_at
        AND c.updated_at=s.contact_updated_at AND c.source='apple' AND o.disabled=0
      ORDER BY s.delivered_at,s.message_id LIMIT ?`)
      .bind(Math.max(0, now - NOTICE_DELIVERY_EVIDENCE_WINDOW_MS), now,
        after?.deliveredAt ?? 0, after?.deliveredAt ?? 0, after?.messageId ?? '', limit)
      .all<{ message_id: string; delivered_at: number }>();
    return rows.results.map(row => ({ messageId: row.message_id, deliveredAt: row.delivered_at }));
  }

  /** Advance even when a row repeatedly fails a later private check. A
   * subsequent scheduled run wraps to the beginning after the final row.
   */
  async nextPendingPromotions(limit = 100): Promise<PendingNoticePromotion[]> {
    const cursor = await this.db.prepare(`SELECT delivered_at,message_id
      FROM pa_notice_promotion_cursor WHERE id=1`)
      .first<{ delivered_at: number; message_id: string }>();
    if (!cursor) throw unavailable();
    const after = cursor.delivered_at === 0 && cursor.message_id === '' ? null
      : { deliveredAt: cursor.delivered_at, messageId: cursor.message_id };
    let pending = await this.listPendingPromotions(after, limit);
    if (pending.length === 0 && after !== null) pending = await this.listPendingPromotions(null, limit);
    const last = pending.at(-1);
    if (last) await this.db.prepare(`UPDATE pa_notice_promotion_cursor
      SET delivered_at=?,message_id=? WHERE id=1`)
      .bind(last.deliveredAt, last.messageId).run();
    return pending;
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
    if (!row || row.evidence_version !== 2 || row.delivered_at === null || row.delivery_event_id === null) return false;
    const candidate = { ownerId: row.owner_id, episode: row.episode,
      revision: row.retention_revision, dueAt: row.due_at };
    const contact = await currentContact(candidate);
    if (!contact || contact.updatedAt !== row.contact_updated_at
        || await this.recipientTag(row.owner_id, contact.email) !== row.recipient_tag) return false;
    let status: VerifiedMembershipStatus;
    try { status = await statusForBillingAccount(row.billing_account_id); }
    catch { status = 'unknown'; }
    const observed = await new RetentionLedger(this.db, this.now, this.ownerRecovery)
      .observe(row.owner_id, status);
    if (observed.status !== 'expired' || observed.pausedAt !== null
        || observed.episode !== row.episode || observed.dueAt !== row.due_at
        || row.delivered_at > now || row.delivered_at < now - NOTICE_DELIVERY_EVIDENCE_WINDOW_MS) return false;
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
          WHERE s.message_id=? AND s.evidence_version=2 AND s.owner_id=pa_retention.owner_id
            AND s.episode=pa_retention.episode AND s.due_at=pa_retention.due_at
            AND s.retention_revision<=pa_retention.revision
            AND s.delivered_at=? AND s.delivery_event_id IS NOT NULL
            AND s.recipient_tag=? AND s.contact_updated_at=?
            AND c.updated_at=s.contact_updated_at AND c.source='apple'
            AND l.billing_account_id=? AND o.disabled=0)
      RETURNING revision`)
      .bind(noticeDueAt, noticeDueAt, row.delivered_at, row.delivery_event_id,
        row.owner_id, observed.revision, row.episode, row.due_at,
        observed.checkedAt, row.delivered_at, messageId, row.delivered_at,
        row.recipient_tag, row.contact_updated_at, row.billing_account_id).run();
    if (result.results.length !== 1) return false;
    await this.ownerRecovery?.copyCurrent(this.db, row.owner_id, this.now());
    return true;
  }

  /** Read-only expiry proof. A mail-server delivery event, the current sealed
   * recipient, and the exact fresh retention version must all still agree.
   * Physical deletion additionally needs an owner fence and complete primary
   * and independent-backup inventory; this method performs neither.
   */
  async verifiedFinalNoticeEvidenceForExpiry(candidate: ExpiryReviewCandidate,
    contact: VerifiedNoticeContact | null): Promise<{ recipientTag: string; contactUpdatedAt: number } | null> {
    const now = this.now();
    if (!candidate || !ownerPattern.test(candidate.ownerId)
      || !Number.isSafeInteger(candidate.episode) || candidate.episode < 1
      || !Number.isSafeInteger(candidate.revision) || candidate.revision < 1
      || !Number.isSafeInteger(candidate.dueAt) || candidate.dueAt <= 0
      || !Number.isSafeInteger(candidate.deliveredAt) || candidate.deliveredAt <= 0
      || !messagePattern.test(candidate.deliveryEventId)
      || !Number.isSafeInteger(now) || now <= 0) throw unavailable();
    if (!contact || !contactEmailValid(contact.email) || !Number.isSafeInteger(contact.updatedAt)
      || contact.updatedAt < 0 || contact.updatedAt > now) return null;
    const grace = 30 * day;
    if (candidate.dueAt > now || candidate.deliveredAt > now - grace) return null;
    const tag = await this.recipientTag(candidate.ownerId, contact.email);
    const row = await this.db.prepare(`SELECT 1 AS verified FROM pa_retention r
      JOIN pa_owners o ON o.owner_id=r.owner_id
      JOIN pa_membership_links l ON l.owner_id=r.owner_id
      JOIN pa_notice_contacts c ON c.owner_id=r.owner_id
      JOIN pa_notice_submissions s ON s.owner_id=r.owner_id
        AND s.delivery_event_id=r.final_notice_receipt
      WHERE r.owner_id=? AND o.disabled=0 AND r.episode=? AND r.revision=? AND r.due_at=?
        AND r.verified_status='expired' AND r.paused_at IS NULL
        AND r.checked_at>=? AND r.checked_at<=? AND r.due_at<=?
        AND r.final_notice_delivered_at=? AND r.final_notice_receipt=?
        AND r.notice_not_before_at<=s.submitted_at
        AND s.evidence_version=2 AND s.episode=r.episode AND s.retention_revision<=r.revision
        AND s.delivered_at=r.final_notice_delivered_at
        AND s.provider_accepted_at IS NOT NULL
        AND s.due_at<=r.due_at AND r.due_at=MAX(s.due_at,s.delivered_at+?)
        AND c.source='apple' AND c.updated_at=?
        AND s.contact_updated_at=c.updated_at AND s.recipient_tag=?`)
      .bind(candidate.ownerId, candidate.episode, candidate.revision, candidate.dueAt,
        Math.max(0, now - day), now, now, candidate.deliveredAt,
        candidate.deliveryEventId, grace, contact.updatedAt, tag)
      .first<{ verified: number }>();
    return row ? { recipientTag: tag, contactUpdatedAt: contact.updatedAt } : null;
  }

  async verifiedFinalNoticeForExpiry(candidate: ExpiryReviewCandidate,
    contact: VerifiedNoticeContact | null): Promise<boolean> {
    return (await this.verifiedFinalNoticeEvidenceForExpiry(candidate, contact)) !== null;
  }
}
