import { ServiceError } from './contracts';

export type VerifiedMembershipStatus = 'active' | 'grace' | 'expired' | 'unknown';
const yearInMonths = 12;
const thirtyDays = 30 * 24 * 60 * 60 * 1000;
const ownerPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const receiptPattern = /^[A-Za-z0-9._:-]{16,256}$/u;
type Row = { owner_id: string; revision: number; episode: number; verified_status: VerifiedMembershipStatus;
  checked_at: number; expired_at: number | null; due_at: number | null; paused_at: number | null;
  final_notice_delivered_at: number | null; final_notice_receipt: string | null };
export type RetentionState = { ownerId: string; revision: number; episode: number;
  status: VerifiedMembershipStatus; checkedAt: number; expiredAt: number | null;
  dueAt: number | null; pausedAt: number | null; finalNoticeDeliveredAt: number | null };

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
  constructor(private readonly db: D1Database, private readonly now: () => number) {}

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
      if (observedAt === current.checked_at) return view(current);
      let episode = current.episode;
      let expiredAt = current.expired_at;
      let dueAt = current.due_at;
      let pausedAt = current.paused_at;
      let noticeAt = current.final_notice_delivered_at;
      let receipt = current.final_notice_receipt;
      if (status === 'active' || status === 'grace') {
        expiredAt = null; dueAt = null; pausedAt = null; noticeAt = null; receipt = null;
      } else if (status === 'expired') {
        if (expiredAt === null) {
          episode += 1; expiredAt = observedAt; dueAt = nextYear(observedAt);
          pausedAt = null; noticeAt = null; receipt = null;
        } else if (pausedAt !== null) {
          if (dueAt === null || observedAt < pausedAt) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
          dueAt = clock(dueAt + observedAt - pausedAt); pausedAt = null;
        }
      } else if (expiredAt !== null) {
        // An outage may last longer than the original notice window. Require
        // a fresh delivery after billing can be verified again.
        noticeAt = null; receipt = null;
        if (pausedAt === null) pausedAt = observedAt;
      }
      const result = await this.db.prepare(`UPDATE pa_retention SET revision=revision+1, episode=?,
        verified_status=?,checked_at=?,expired_at=?,due_at=?,paused_at=?,
        final_notice_delivered_at=?,final_notice_receipt=?
        WHERE owner_id=? AND revision=? AND EXISTS
        (SELECT 1 FROM pa_owners WHERE owner_id=? AND disabled=0)`)
        .bind(episode, status, observedAt, expiredAt, dueAt, pausedAt,
          noticeAt, receipt, ownerId, current.revision, ownerId).run();
      if (result.meta.changes === 1) return view(await this.read(ownerId));
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
          || deliveredAt < current.expired_at) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
      if (current.final_notice_delivered_at !== null) {
        if (current.final_notice_delivered_at === deliveredAt && current.final_notice_receipt === providerReceipt) {
          return view(current);
        }
        throw new ServiceError('RETENTION_UNAVAILABLE', 503);
      }
      const dueAt = clock(Math.max(current.due_at, deliveredAt + thirtyDays));
      const result = await this.db.prepare(`UPDATE pa_retention
        SET revision=revision+1,due_at=?,final_notice_delivered_at=?,final_notice_receipt=?
        WHERE owner_id=? AND revision=? AND verified_status='expired' AND paused_at IS NULL`)
        .bind(dueAt, deliveredAt, providerReceipt, ownerId, current.revision).run();
      if (result.meta.changes === 1) return view(await this.read(ownerId));
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
}
