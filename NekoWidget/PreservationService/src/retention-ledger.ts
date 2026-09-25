import { ServiceError } from './contracts';

export type VerifiedMembershipStatus = 'active' | 'grace' | 'expired' | 'unknown';
const yearInMonths = 12;
const thirtyDays = 30 * 24 * 60 * 60 * 1000;
const finalNoticeWindow = 60 * 24 * 60 * 60 * 1000;
const noticeReviewObservationAge = 24 * 60 * 60 * 1000;
// A repeated read of an unchanged, already backed billing state must not
// create a new owner snapshot on every tap. Status transitions still commit
// immediately; deletion and notice paths make a fresh private billing call.
const unchangedObservationInterval = 60 * 60 * 1000;
export const NOTICE_SUBMISSION_RETRY_DELAY_MS = 7 * 24 * 60 * 60 * 1000;
export const NOTICE_DELIVERY_EVIDENCE_WINDOW_MS = 60 * 24 * 60 * 60 * 1000;
const ownerPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const receiptPattern = /^[A-Za-z0-9._:-]{16,256}$/u;
type Row = { owner_id: string; revision: number; episode: number; verified_status: VerifiedMembershipStatus;
  checked_at: number; expired_at: number | null; due_at: number | null; paused_at: number | null;
  notice_not_before_at: number; final_notice_delivered_at: number | null; final_notice_receipt: string | null };
export type RetentionState = { ownerId: string; revision: number; episode: number;
  status: VerifiedMembershipStatus; checkedAt: number; expiredAt: number | null;
  dueAt: number | null; pausedAt: number | null; finalNoticeDeliveredAt: number | null };
export type NoticeReviewCandidate = { ownerId: string; episode: number; revision: number; dueAt: number };
/** An advisory scan item, never proof of current billing or delivery. */
export type ExpiryScanCandidate = NoticeReviewCandidate;
/** Read-only review token. This is not permission to erase any copy. */
export type ExpiryReviewCandidate = NoticeReviewCandidate & { deliveredAt: number; deliveryEventId: string };
export type NoticeScanCursor = { dueAt: number; ownerId: string };

function clock(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
  return value;
}

/** Twelve calendar months, preserving the UTC time and clamping February 29. */
function nextYear(value: number): number {
  const date = new Date(clock(value));
  const year = date.getUTCFullYear() + yearInMonths / 12;
  const month = date.getUTCMonth();
  const maximumDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  const result = Date.UTC(year, month, Math.min(date.getUTCDate(), maximumDay),
    date.getUTCHours(), date.getUTCMinutes(), date.getUTCSeconds(), date.getUTCMilliseconds());
  if (!Number.isSafeInteger(result) || result <= value) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
  return result;
}

function view(row: Row): RetentionState {
  return { ownerId: row.owner_id, revision: row.revision, episode: row.episode,
    status: row.verified_status, checkedAt: row.checked_at, expiredAt: row.expired_at,
    dueAt: row.due_at, pausedAt: row.paused_at, finalNoticeDeliveredAt: row.final_notice_delivered_at };
}

/** Internal ledger only. It never sends a notice or deletes a record by itself. */
export class RetentionLedger {
  constructor(private readonly db: D1Database, private readonly now: () => number,
    private readonly ownerRecovery?: { copyCurrent(db: D1Database, ownerId: string, now: number): Promise<unknown> }) {}

  private async acknowledge(ownerId: string, row: Row): Promise<RetentionState> {
    await this.ownerRecovery?.copyCurrent(this.db, ownerId, this.now());
    return view(row);
  }

  /** Advisory queue for a future notification outbox; never sends or proves delivery. */
  async listNoticeReviewCandidates(limit = 20,
    after: NoticeScanCursor | null = null): Promise<NoticeReviewCandidate[]> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    if (after !== null && (!Number.isSafeInteger(after.dueAt) || after.dueAt < 0
        || (after.ownerId !== '' && !ownerPattern.test(after.ownerId)))) {
      throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    }
    const now = clock(this.now());
    const result = await this.db.prepare(`SELECT r.owner_id,r.episode,r.revision,r.due_at
      FROM pa_retention r JOIN pa_owners o ON o.owner_id=r.owner_id
      JOIN pa_membership_links l ON l.owner_id=r.owner_id
      WHERE o.disabled=0 AND r.verified_status='expired' AND r.paused_at IS NULL
        AND r.expired_at IS NOT NULL AND r.due_at IS NOT NULL AND r.final_notice_delivered_at IS NULL
        AND r.due_at<=? AND r.checked_at>=? AND r.checked_at<=?
        AND (r.due_at>? OR (r.due_at=? AND r.owner_id>?))
        AND NOT EXISTS (SELECT 1 FROM pa_notice_submissions s
          JOIN pa_notice_contacts c ON c.owner_id=s.owner_id
          WHERE s.owner_id=r.owner_id AND s.evidence_version=2
            AND s.episode=r.episode AND s.due_at=r.due_at
            AND s.contact_updated_at=c.updated_at AND s.submitted_at>=r.notice_not_before_at
            AND (s.delivered_at>=? OR (s.delivered_at IS NULL AND s.submitted_at>=?)))
      ORDER BY r.due_at,r.owner_id LIMIT ?`)
      .bind(clock(now + finalNoticeWindow), Math.max(0, now - noticeReviewObservationAge), now,
        after?.dueAt ?? 0, after?.dueAt ?? 0, after?.ownerId ?? '',
        Math.max(0, now - NOTICE_DELIVERY_EVIDENCE_WINDOW_MS),
        Math.max(0, now - NOTICE_SUBMISSION_RETRY_DELAY_MS), limit)
      .all<{ owner_id: string; episode: number; revision: number; due_at: number }>();
    return result.results.map(row => ({ ownerId: row.owner_id, episode: row.episode,
      revision: row.revision, dueAt: row.due_at }));
  }

  /** Persistent round-robin cursor: unreadable or absent contacts cannot
   * monopolize every scheduled batch. Claim fencing handles overlapping runs.
   */
  async nextNoticeReviewCandidates(limit = 20): Promise<NoticeReviewCandidate[]> {
    const cursor = await this.db.prepare('SELECT due_at,owner_id FROM pa_notice_scan_cursor WHERE id=1')
      .first<{ due_at: number; owner_id: string }>();
    if (!cursor) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    let candidates = await this.listNoticeReviewCandidates(limit,
      { dueAt: cursor.due_at, ownerId: cursor.owner_id });
    if (candidates.length === 0 && (cursor.due_at !== 0 || cursor.owner_id !== '')) {
      candidates = await this.listNoticeReviewCandidates(limit);
    }
    const last = candidates.at(-1);
    if (last) await this.db.prepare(`UPDATE pa_notice_scan_cursor
      SET due_at=?,owner_id=? WHERE id=1`).bind(last.dueAt, last.ownerId).run();
    return candidates;
  }

  /** Bounded round-robin scan. An old, repeatedly ineligible owner cannot
   * monopolize the scheduler. Every item still needs a fresh private-billing
   * check and independent notice, contact, inventory and fence verification.
   */
  async nextExpiryReviewCandidates(limit = 20): Promise<ExpiryScanCandidate[]> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
      throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    }
    const cursor = await this.db.prepare('SELECT due_at,owner_id FROM pa_expiry_review_cursor WHERE id=1')
      .first<{ due_at: number; owner_id: string }>();
    if (!cursor || !Number.isSafeInteger(cursor.due_at) || cursor.due_at < 0
      || (cursor.owner_id !== '' && !ownerPattern.test(cursor.owner_id))) {
      throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    }
    const now = clock(this.now());
    const scan = async (dueAt: number, ownerId: string) => this.db.prepare(`SELECT r.owner_id,r.episode,r.revision,r.due_at
      FROM pa_retention r JOIN pa_owners o ON o.owner_id=r.owner_id
      JOIN pa_membership_links l ON l.owner_id=r.owner_id
      WHERE o.disabled=0 AND r.verified_status='expired' AND r.paused_at IS NULL
        AND r.due_at IS NOT NULL AND r.due_at<=?
        AND r.final_notice_delivered_at IS NOT NULL AND r.final_notice_receipt IS NOT NULL
        AND r.final_notice_delivered_at<=?
        AND (r.due_at>? OR (r.due_at=? AND r.owner_id>?))
      ORDER BY r.due_at,r.owner_id LIMIT ?`)
      .bind(now, Math.max(0, now - thirtyDays), dueAt, dueAt, ownerId, limit)
      .all<{ owner_id: string; episode: number; revision: number; due_at: number }>();
    let rows = (await scan(cursor.due_at, cursor.owner_id)).results;
    if (rows.length === 0 && (cursor.due_at !== 0 || cursor.owner_id !== '')) {
      rows = (await scan(0, '')).results;
    }
    const last = rows.at(-1);
    if (last) await this.db.prepare('UPDATE pa_expiry_review_cursor SET due_at=?,owner_id=? WHERE id=1')
      .bind(last.due_at, last.owner_id).run();
    return rows.map(row => ({ ownerId: row.owner_id, episode: row.episode,
      revision: row.revision, dueAt: row.due_at }));
  }

  /** Fair, bounded scan. A provider failure becomes an explicit pause, never an expiry. */
  async refreshBatch(statusForBillingAccount: (billingAccountId: string) => Promise<VerifiedMembershipStatus>,
    limit = 20): Promise<number> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    const rows = await this.db.prepare(`SELECT l.owner_id,l.billing_account_id
      FROM pa_membership_links l JOIN pa_owners o ON o.owner_id=l.owner_id
      LEFT JOIN pa_retention r ON r.owner_id=l.owner_id
      WHERE o.disabled=0 ORDER BY COALESCE(r.checked_at,0),l.owner_id LIMIT ?`)
      .bind(limit).all<{ owner_id: string; billing_account_id: string }>();
    for (const row of rows.results) {
      let status: VerifiedMembershipStatus;
      try { status = await statusForBillingAccount(row.billing_account_id); }
      catch { status = 'unknown'; }
      await this.observe(row.owner_id, status);
    }
    return rows.results.length;
  }

  private async read(ownerId: string): Promise<Row> {
    if (!ownerPattern.test(ownerId)) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    const row = await this.db.prepare(`SELECT r.* FROM pa_retention r JOIN pa_owners o ON o.owner_id=r.owner_id
      WHERE r.owner_id=? AND o.disabled=0`).bind(ownerId).first<Row>();
    if (!row) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    return row;
  }

  /** Call with a fresh private-billing result, or unknown on explicit check failure. */
  async observe(ownerId: string, status: VerifiedMembershipStatus): Promise<RetentionState> {
    if (!ownerPattern.test(ownerId) || !['active', 'grace', 'expired', 'unknown'].includes(status)) {
      throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    }
    const observedAt = clock(this.now());
    // A ledger row is allowed only for a fixed owner↔billing link, never an
    // unlinked or disabled owner supplied by a caller.
    await this.db.prepare(`INSERT OR IGNORE INTO pa_retention(owner_id)
      SELECT l.owner_id FROM pa_membership_links l JOIN pa_owners o ON o.owner_id=l.owner_id
      WHERE l.owner_id=? AND o.disabled=0`).bind(ownerId).run();
    for (let attempt = 0; attempt < 4; attempt++) {
      const current = await this.read(ownerId);
      if (observedAt < current.checked_at || (observedAt === current.checked_at
          && status !== current.verified_status)) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
      if (observedAt === current.checked_at) return this.acknowledge(ownerId, current);
      const stable = status === current.verified_status
        && (status === 'expired'
          ? current.expired_at !== null && current.due_at !== null && current.paused_at === null
          : status === 'unknown'
            ? current.final_notice_delivered_at === null && current.final_notice_receipt === null
              && (current.expired_at === null
                ? current.due_at === null && current.paused_at === null
                : current.due_at !== null && current.paused_at !== null)
            : current.expired_at === null && current.due_at === null && current.paused_at === null
              && current.final_notice_delivered_at === null && current.final_notice_receipt === null)
        && ((current.final_notice_delivered_at === null) === (current.final_notice_receipt === null));
      if (stable && observedAt - current.checked_at < unchangedObservationInterval) {
        return this.acknowledge(ownerId, current);
      }
      let episode = current.episode;
      let expiredAt = current.expired_at;
      let dueAt = current.due_at;
      let pausedAt = current.paused_at;
      let noticeNotBeforeAt = current.notice_not_before_at;
      let noticeAt = current.final_notice_delivered_at;
      let receipt = current.final_notice_receipt;
      if (status === 'active' || status === 'grace') {
        expiredAt = null; dueAt = null; pausedAt = null; noticeNotBeforeAt = 0; noticeAt = null; receipt = null;
      } else if (status === 'expired') {
        if (expiredAt === null) {
          episode += 1; expiredAt = observedAt; dueAt = nextYear(observedAt);
          pausedAt = null; noticeNotBeforeAt = observedAt; noticeAt = null; receipt = null;
        } else if (pausedAt !== null) {
          if (dueAt === null || observedAt < pausedAt) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
          dueAt = clock(dueAt + observedAt - pausedAt); pausedAt = null;
          noticeNotBeforeAt = observedAt;
        }
      } else if (expiredAt !== null) {
        // An outage may last longer than the original notice window. Require
        // a fresh delivery after billing can be verified again.
        noticeAt = null; receipt = null;
        if (pausedAt === null) pausedAt = observedAt;
        noticeNotBeforeAt = observedAt;
      }
      const result = await this.db.prepare(`UPDATE pa_retention SET revision=revision+1, episode=?,
        verified_status=?,checked_at=?,expired_at=?,due_at=?,paused_at=?,
        notice_not_before_at=?,final_notice_delivered_at=?,final_notice_receipt=?
        WHERE owner_id=? AND revision=? AND EXISTS
        (SELECT 1 FROM pa_owners WHERE owner_id=? AND disabled=0)
        RETURNING revision`)
        .bind(episode, status, observedAt, expiredAt, dueAt, pausedAt,
          noticeNotBeforeAt, noticeAt, receipt, ownerId, current.revision, ownerId).run();
      if (result.results.length === 1) return this.acknowledge(ownerId, await this.read(ownerId));
    }
    throw new ServiceError('RETENTION_UNAVAILABLE', 503);
  }

  /** A future notification provider must supply its actual delivery receipt. */
  async markFinalNoticeDelivered(ownerId: string, episode: number, deliveredAt: number,
    providerReceipt: string): Promise<RetentionState> {
    const now = clock(this.now());
    if (!Number.isSafeInteger(episode) || episode < 1 || !receiptPattern.test(providerReceipt)
        || clock(deliveredAt) > now) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    for (let attempt = 0; attempt < 4; attempt++) {
      const current = await this.read(ownerId);
      if (current.episode !== episode || current.expired_at === null || current.due_at === null
          || current.verified_status !== 'expired' || current.paused_at !== null
          || deliveredAt < current.notice_not_before_at
          || deliveredAt < current.due_at - finalNoticeWindow) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
      if (current.final_notice_delivered_at !== null) {
        if (current.final_notice_delivered_at === deliveredAt && current.final_notice_receipt === providerReceipt) {
          return this.acknowledge(ownerId, current);
        }
        throw new ServiceError('RETENTION_UNAVAILABLE', 503);
      }
      const dueAt = clock(Math.max(current.due_at, deliveredAt + thirtyDays));
      const result = await this.db.prepare(`UPDATE pa_retention
        SET revision=revision+1,due_at=?,final_notice_delivered_at=?,final_notice_receipt=?
        WHERE owner_id=? AND revision=? AND verified_status='expired' AND paused_at IS NULL
        RETURNING revision`)
        .bind(dueAt, deliveredAt, providerReceipt, ownerId, current.revision).run();
      if (result.results.length === 1) return this.acknowledge(ownerId, await this.read(ownerId));
    }
    throw new ServiceError('RETENTION_UNAVAILABLE', 503);
  }

  /** Advisory only: a deletion worker must independently verify membership and every physical copy. */
  async eligibleAfterFreshCheck(ownerId: string, status: VerifiedMembershipStatus): Promise<boolean> {
    const state = await this.observe(ownerId, status);
    const now = clock(this.now());
    return state.status === 'expired' && state.pausedAt === null && state.dueAt !== null
      && state.finalNoticeDeliveredAt !== null && now >= state.dueAt
      && now - state.finalNoticeDeliveredAt >= thirtyDays;
  }

  /** Capture the exact ledger version after a fresh private-billing check.
   * Every later contact, provider and storage check must fence this version.
   */
  async expiryReviewAfterFreshCheck(ownerId: string,
    status: VerifiedMembershipStatus): Promise<ExpiryReviewCandidate | null> {
    const state = await this.observe(ownerId, status);
    const now = clock(this.now());
    if (state.status !== 'expired' || state.pausedAt !== null || state.dueAt === null
      || state.finalNoticeDeliveredAt === null || now < state.dueAt
      || now - state.finalNoticeDeliveredAt < thirtyDays) return null;
    const row = await this.read(ownerId);
    if (row.revision !== state.revision || row.episode !== state.episode || row.due_at !== state.dueAt
      || row.final_notice_delivered_at !== state.finalNoticeDeliveredAt
      || row.final_notice_receipt === null || row.checked_at !== state.checkedAt) return null;
    return { ownerId, episode: row.episode, revision: row.revision, dueAt: row.due_at!,
      deliveredAt: row.final_notice_delivered_at!, deliveryEventId: row.final_notice_receipt };
  }
}
