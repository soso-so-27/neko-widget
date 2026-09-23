import { parseDeliveredNoticeEvent, type NoticeEventSource } from './notice-events';
import { NoticeSubmissions, type VerifiedNoticeContact } from './notice-submissions';
import { RetentionLedger, type NoticeReviewCandidate, type VerifiedMembershipStatus } from './retention-ledger';

/** Called only by the private Queue consumer. Refreshing the owner's private
 * billing observation first distinguishes a stale daily scan from a renewed
 * or unverified membership. Delivery evidence never comes from HTTP input.
 */
export async function processDeliveredNoticeEvent(rawEvent: unknown, d: {
  source: NoticeEventSource;
  submissions: NoticeSubmissions;
  ledger: RetentionLedger;
  now: () => number;
  statusForOwner: (ownerId: string) => Promise<VerifiedMembershipStatus>;
  statusForBillingAccount: (billingAccountId: string) => Promise<VerifiedMembershipStatus>;
  currentContact: (candidate: NoticeReviewCandidate) => Promise<VerifiedNoticeContact | null>;
}): Promise<boolean> {
  const event = parseDeliveredNoticeEvent(rawEvent, d.source, d.now());
  const ownerId = await d.submissions.ownerForSubmission(event.messageId, d.source);
  let status: VerifiedMembershipStatus;
  try { status = await d.statusForOwner(ownerId); }
  catch { status = 'unknown'; }
  await d.ledger.observe(ownerId, status);
  await d.submissions.recordDelivery(rawEvent, d.source, d.currentContact);
  return d.submissions.promoteDelivered(event.messageId, d.currentContact,
    d.statusForBillingAccount);
}
