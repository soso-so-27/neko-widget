import { ServiceError } from './contracts';
import type { NoticeEventSource } from './notice-events';
import { NoticeSubmissions, validNoticeEventSource, type VerifiedNoticeContact } from './notice-submissions';
import { RetentionLedger, type NoticeReviewCandidate, type VerifiedMembershipStatus } from './retention-ledger';

const unavailable = () => new ServiceError('NOTICE_SEND_UNAVAILABLE', 503);

export interface NoticeMailProvider {
  send(message: { to: string; from: string; subject: string; text: string }): Promise<{ messageId: string }>;
}

/** A notice is deliberately generic: a contact may change in the small,
 * unavoidable gap between the last D1 check and an external provider call.
 * It contains no cat names, photos, billing details, or bearer links.
 */
export const NOTICE_SUBJECT = 'ねこのまど：保管期限のお知らせ';
export const NOTICE_TEXT = 'ねこのまどに保存した記録の持ち出し期限が近づいています。'
  + 'アプリを開き、現在の期限を確認して、必要な記録を書き出してください。'
  + '配達後も少なくとも30日間は持ち出せます。';

export class NoticeDispatch {
  constructor(private readonly d: {
    ledger: RetentionLedger;
    submissions: NoticeSubmissions;
    source: NoticeEventSource;
    mail: NoticeMailProvider;
    statusForOwner: (ownerId: string) => Promise<VerifiedMembershipStatus>;
    currentContact: (candidate: NoticeReviewCandidate) => Promise<VerifiedNoticeContact | null>;
  }) {
    if (!validNoticeEventSource(d.source)) throw unavailable();
  }

  private async verifyExpired(ownerId: string) {
    let status: VerifiedMembershipStatus;
    try { status = await this.d.statusForOwner(ownerId); }
    catch { status = 'unknown'; }
    // A changed or unavailable status is enough to stop dispatch. The regular
    // retention refresh records the pause; this path never promotes expiry.
    if (status !== 'expired') return null;
    return this.d.ledger.observe(ownerId, status);
  }

  /** Runs only behind the separate notification gate. Selection is advisory;
   * each owner is independently rechecked before and after the send claim.
   * The D1 claim prevents concurrent schedulers from dispatching the same
   * notice. A send without a recorded messageId is never delivery evidence.
   */
  async run(limit = 20): Promise<{ reviewed: number; submitted: number; skipped: number; failed: number }> {
    const candidates = await this.d.ledger.nextNoticeReviewCandidates(limit);
    let submitted = 0;
    let skipped = 0;
    let failed = 0;
    for (const advisory of candidates) {
      try {
        const observed = await this.verifyExpired(advisory.ownerId);
        if (!observed || observed.pausedAt !== null
            || observed.episode !== advisory.episode || observed.dueAt !== advisory.dueAt) {
          skipped++; continue;
        }
        const candidate = { ...advisory, revision: observed.revision };
        const contact = await this.d.currentContact(candidate);
        if (!contact) { skipped++; continue; }
        const claimId = await this.d.submissions.claimNotice(candidate, contact);
        if (!claimId) { skipped++; continue; }

        // These awaits are intentional. A renewal, outage, revocation or
        // replacement contact after the claim must win before provider dispatch.
        const latest = await this.verifyExpired(candidate.ownerId);
        if (!latest || latest.pausedAt !== null
            || latest.episode !== candidate.episode || latest.dueAt !== candidate.dueAt) {
          skipped++; continue;
        }
        const current = { ...candidate, revision: latest.revision };
        const latestContact = await this.d.currentContact(current);
        if (!latestContact || latestContact.updatedAt !== contact.updatedAt
            || latestContact.email !== contact.email
            || !await this.d.submissions.readyForDispatch(current, latestContact, claimId)) {
          skipped++; continue;
        }
        const sent = await this.d.mail.send({ to: latestContact.email, from: this.d.source.sender,
          subject: NOTICE_SUBJECT, text: NOTICE_TEXT });
        // Provider acceptance is not delivery. The Queue event must later match.
        await this.d.submissions.recordSubmission(current, latestContact, claimId, sent.messageId, this.d.source);
        submitted++;
      } catch {
        // One rejected address must not starve every later owner. The claim
        // remains reserved for its backoff period; no delivery is inferred.
        failed++;
      }
    }
    return { reviewed: candidates.length, submitted, skipped, failed };
  }
}
