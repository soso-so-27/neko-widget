import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { reviewOperatingEvidence, reviewPublicPreservationOffer } from '../scripts/operating-readiness.mjs';
const plan = JSON.parse(await readFile(new URL('../operations/pilot-plan.json', import.meta.url), 'utf8'));
const now = Date.UTC(2026, 9, 4);
const fixture = () => ({ version: 1, observedAt: now, capacityMatchesDeployedConfiguration: true,
  usage: { activeOwners: 1, retainedOwners: 1, primaryBytes: 100, recoveryBytesIncludingVersions: 200 },
  cost: { confirmedAt: now, forecastMonthlyYen: 1700, includesRetainedOwnersAndHistoricalVersions: true,
    includesOperationsComputeKmsAndNotices: true },
  sandbox: { confirmedAt: now, purchase: true, purchaseSheetCancel: true, cancelBeforeExpiry: true,
    restore: true, expiry: true, preservationAccess: true } });
test('purchase sheet cancellation is separate evidence from disabling renewal', () => {
  const e = fixture();
  delete e.sandbox.purchaseSheetCancel;
  assert.equal(reviewOperatingEvidence(e, plan, now).newIntakeReviewReady, false);
  e.sandbox.purchaseSheetCancel = false;
  assert.equal(reviewOperatingEvidence(e, plan, now).newIntakeReviewReady, false);
  e.sandbox.purchaseSheetCancel = true;
  assert.equal(reviewOperatingEvidence(e, plan, now).newIntakeReviewReady, true);
  e.sandbox.cancelBeforeExpiry = false;
  assert.equal(reviewOperatingEvidence(e, plan, now).newIntakeReviewReady, false);
});
test('invalid review plans and clocks cannot appear ready', () => {
  for (const mutate of [p => p.maximumParticipants = undefined, p => p.archive.reviewLifetimeHours = NaN,
    p => p.archive.globalActiveBytesLimit = 0, p => p.currency.warningForecastYen = -1,
    p => p.currency.pauseNewIntakeForecastYen = p.currency.warningForecastYen]) {
    const p = structuredClone(plan); mutate(p);
    assert.equal(reviewOperatingEvidence(fixture(), p, now).newIntakeReviewReady, false);
  }
  assert.equal(reviewOperatingEvidence(fixture(), null, now).newIntakeReviewReady, false);
  assert.equal(reviewOperatingEvidence(fixture(), plan, NaN).newIntakeReviewReady, false);
});
test('complete evidence is advisory and never authorizes notice or deletion', () => {
  const result = reviewOperatingEvidence(fixture(), plan, now);
  assert.equal(result.newIntakeReviewReady, true);
  assert.equal(result.noticePermission, false); assert.equal(result.permanentDeletionPermission, false);
  assert.equal(result.remoteStateChanged, false);
});
test('retained owners and historical copies consume capacity and missing evidence stops intake review', () => {
  for (const mutate of [e => e.usage.retainedOwners = 2, e => e.usage.recoveryBytesIncludingVersions = 0,
    e => e.usage.primaryBytes = plan.archive.globalActiveBytesLimit,
    e => e.cost.includesRetainedOwnersAndHistoricalVersions = false, e => e.sandbox.restore = false,
    e => e.capacityMatchesDeployedConfiguration = false, e => e.cost.forecastMonthlyYen = 2200]) {
    const e = fixture(); mutate(e); assert.equal(reviewOperatingEvidence(e, plan, now).newIntakeReviewReady, false);
  }
  assert.equal(reviewOperatingEvidence(null, plan, now).newIntakeReviewReady, false);
});
test('future, stale and malformed timestamps and counts fail closed', () => {
  for (const mutate of [e => e.observedAt = now + 1, e => e.cost.confirmedAt = now - 86400001,
    e => e.sandbox.confirmedAt = null, e => e.usage.activeOwners = -1,
    e => e.usage.primaryBytes = Number.MAX_SAFE_INTEGER + 1]) {
    const e = fixture(); mutate(e); assert.equal(reviewOperatingEvidence(e, plan, now).newIntakeReviewReady, false);
  }
});
test('cost warning precedes the existing intake stop threshold', () => {
  const e = fixture(); e.cost.forecastMonthlyYen = 1800;
  const report = reviewOperatingEvidence(e, plan, now);
  assert.equal(report.costWarning, true); assert.equal(report.newIntakeReviewReady, true);
});

const publicFixture = () => {
  const evidence = fixture();
  evidence.usage.allocatedQuotaBytes = 100;
  evidence.usage.reservedQuotaBytes = 200;
  evidence.configuration = { confirmedAt: now, mode: 'general', requestLimiterScope: 'owner',
    requestLimiterConsistency: 'global-atomic', requestLimiterWindow: 'fixed-utc-minute',
    recoveryAwsAccountId: '111122223333',
    perParticipantRequestsPerMinute: 30, ownerQuotaBytes: plan.archive.ownerQuotaBytes,
    maximumRecordsPerOwner: plan.archive.maximumRecordsPerOwner, maximumOwners: plan.maximumParticipants,
    globalActiveBytesLimit: plan.archive.globalActiveBytesLimit };
  evidence.intake = { enabled: true, reviewedAt: now, validUntil: now + 86400000,
    maximumOwners: plan.maximumParticipants, dailyNewIntakeAttempts: plan.archive.dailyNewIntakeAttempts,
    monthlyNewIntakeAttempts: plan.archive.monthlyNewIntakeAttempts, monthlyNewIntakeBytes: plan.archive.monthlyNewIntakeBytes,
    dailyMutationAttempts: plan.additionalControlsRequired.dailyMutationAttemptsIncludingEditsAndRetries,
    monthlyMutationAttempts: plan.additionalControlsRequired.monthlyMutationAttemptsIncludingEditsAndRetries,
    forecastMonthlyYen: 1700, pauseForecastYen: 2200 };
  const offer = { version: 1, ownerQuotaBytes: plan.archive.ownerQuotaBytes,
    maximumRecordsPerOwner: plan.archive.maximumRecordsPerOwner, maximumOwners: plan.maximumParticipants,
    initialFill: { basis: 'calendar-quota-allocations', monthlyAllocations: 3, dailyAllocations: 15,
      newAttemptReserve: 30, editAttemptReserve: 30 },
    approval: { status: 'approved', evidenceReference: 'fixture-only-not-real-approval' } };
  evidence.awsAccount = { confirmedAt: now, accountId: '111122223333', planType: 'PAID', planStatus: 'ACTIVE',
    planExpirationAt: null, approvalEvidenceReference: 'synthetic-only' };
  evidence.retentionFunding = { reviewedAt: now, calendarMonths: 12, minimumDaysAfterDeliveredFinalNotice: 30,
    includesRetainedOwnersAndHistoricalVersions: true, coversUnknownStatusAndUndeliveredNoticeExtension: true,
    evidenceReference: 'synthetic-only' };
  evidence.bulkExport = { confirmedAt: now, recordCount: offer.maximumRecordsPerOwner,
    requestsPerMinute: 30, window: 'fixed-utc-minute', completed: true, archiveConsistent: true,
    cancellationStopsRequests: true, sessionChangeStopsRequests: true,
    appBuild: 'synthetic-only', evidenceReference: 'synthetic-only' };
  return { evidence, offer };
};
test('public offer review is distinct from pilot capacity attestation and cannot approve or deploy', () => {
  const { evidence, offer } = publicFixture();
  const result = reviewPublicPreservationOffer(evidence, offer, plan, now);
  assert.equal(result.publicOfferReviewReady, true);
  assert.equal(result.deployPermission, false); assert.equal(result.salesApprovalPermission, false);
  assert.equal(result.remoteStateChanged, false); assert.equal(result.permanentDeletionPermission, false);
  delete evidence.configuration;
  assert.equal(reviewOperatingEvidence(evidence, plan, now).newIntakeReviewReady, true);
  assert.ok(reviewPublicPreservationOffer(evidence, offer, plan, now).blockers.includes('public-deployed-limits-unconfirmed'));
});
test('selling five decimal GB and 1000 records cannot borrow the one GiB pilot plan or an approval boolean', () => {
  const { evidence, offer } = publicFixture();
  offer.ownerQuotaBytes = 5000000000; offer.maximumRecordsPerOwner = 1000;
  offer.approval.status = 'proposed';
  const result = reviewPublicPreservationOffer(evidence, offer, plan, now);
  assert.equal(result.publicOfferReviewReady, false);
  for (const blocker of ['public-offer-not-approved', 'offer-exceeds-reviewed-plan',
    'public-deployed-limits-unconfirmed', 'sales-capacity-not-reserved']) assert.ok(result.blockers.includes(blocker));
});
test('public review rejects missing reservation accounting, changed costs, expired review and inconsistent intake controls', () => {
  for (const mutate of [e => delete e.usage.reservedQuotaBytes,
    e => e.usage.reservedQuotaBytes = Number.MAX_SAFE_INTEGER,
    e => e.intake.enabled = false, e => e.intake.validUntil = now,
    e => e.intake.validUntil = now + 86400001, e => e.intake.reviewedAt = now - 86400000,
    e => e.intake.maximumOwners = 4, e => e.intake.monthlyMutationAttempts = 501,
    e => e.intake.forecastMonthlyYen = 1600, e => e.intake.pauseForecastYen = 3000,
    e => e.configuration.maximumRecordsPerOwner = 1000, e => e.configuration.mode = 'pilot',
    e => e.configuration.requestLimiterScope = 'ip', e => e.configuration.perParticipantRequestsPerMinute = 120,
    e => e.configuration.requestLimiterConsistency = 'colo-eventual', e => delete e.configuration.requestLimiterWindow]) {
    const { evidence, offer } = publicFixture(); mutate(evidence);
    assert.equal(reviewPublicPreservationOffer(evidence, offer, plan, now).publicOfferReviewReady, false);
  }
  const { evidence, offer } = publicFixture();
  const changedPlan = structuredClone(plan); changedPlan.currency.pauseNewIntakeForecastYen = 3000;
  assert.ok(reviewPublicPreservationOffer(evidence, offer, changedPlan, now).blockers.includes('cost-boundaries-changed'));
});

test('public admission needs a complete next owner reservation, including the exact capacity boundary', () => {
  const { evidence, offer } = publicFixture();
  evidence.usage.allocatedQuotaBytes = plan.archive.globalActiveBytesLimit - offer.ownerQuotaBytes;
  evidence.usage.reservedQuotaBytes = 1;
  assert.ok(reviewPublicPreservationOffer(evidence, offer, plan, now).blockers.includes('no-quota-slot'));
  evidence.usage.reservedQuotaBytes = 0;
  assert.equal(reviewPublicPreservationOffer(evidence, offer, plan, now).publicOfferReviewReady, true);
});

test('invalid public offer and missing approval evidence cannot fall back to valid pilot review', () => {
  const { evidence, offer } = publicFixture();
  assert.equal(reviewOperatingEvidence(evidence, plan, now).newIntakeReviewReady, true);
  for (const candidate of [null, {}, { ...offer, ownerQuotaBytes: NaN },
    { ...offer, maximumOwners: Number.MAX_SAFE_INTEGER },
    { ...offer, approval: { status: 'approved', evidenceReference: '' } }]) {
    assert.equal(reviewPublicPreservationOffer(evidence, candidate, plan, now).publicOfferReviewReady, false);
  }
});

const largePublicFixture = () => {
  const { evidence, offer } = publicFixture();
  const publicPlan = structuredClone(plan);
  Object.assign(publicPlan.archive, { ownerQuotaBytes: 5_000_000_000, maximumRecordsPerOwner: 1000,
    globalActiveBytesLimit: 15_000_000_000 });
  Object.assign(offer, { ownerQuotaBytes: 5_000_000_000, maximumRecordsPerOwner: 1000 });
  Object.assign(offer.initialFill, { monthlyAllocations: 1, dailyAllocations: 28,
    newAttemptReserve: 300, editAttemptReserve: 300 });
  Object.assign(evidence.configuration, { ownerQuotaBytes: offer.ownerQuotaBytes,
    maximumRecordsPerOwner: 1000, globalActiveBytesLimit: 15_000_000_000 });
  evidence.bulkExport.recordCount = offer.maximumRecordsPerOwner;
  return { evidence, offer, publicPlan };
};
test('capacity approval cannot reuse an internally matching but insufficient monthly intake plan', () => {
  const { evidence, offer, publicPlan } = largePublicFixture();
  const result = reviewPublicPreservationOffer(evidence, offer, publicPlan, now);
  assert.ok(result.blockers.includes('initial-fill-exceeds-intake-budget'));
  assert.equal(result.blockers.includes('general-intake-controls-unconfirmed'), false);
  assert.equal(result.initialFill.newAttempts, 3300);
  assert.equal(result.initialFill.mutationAttempts, 3600);
  assert.equal(result.initialFill.conservativeAdmissionBytes, 23_048_646_000);
});
test('explicit initial-fill allowance accounts for per-attempt metadata, retries and edits at exact boundaries', () => {
  const { evidence, offer, publicPlan } = largePublicFixture();
  Object.assign(publicPlan.archive, { monthlyNewIntakeAttempts: 3300, monthlyNewIntakeBytes: 23_048_646_000,
    dailyNewIntakeAttempts: 118 });
  Object.assign(publicPlan.additionalControlsRequired, { monthlyMutationAttemptsIncludingEditsAndRetries: 3600,
    dailyMutationAttemptsIncludingEditsAndRetries: 129 });
  Object.assign(evidence.intake, { monthlyNewIntakeAttempts: 3300, monthlyNewIntakeBytes: 23_048_646_000,
    monthlyMutationAttempts: 3600, dailyNewIntakeAttempts: 118, dailyMutationAttempts: 129 });
  assert.equal(reviewPublicPreservationOffer(evidence, offer, publicPlan, now).publicOfferReviewReady, true);
  for (const field of ['monthlyNewIntakeAttempts', 'monthlyNewIntakeBytes', 'monthlyMutationAttempts',
    'dailyNewIntakeAttempts', 'dailyMutationAttempts']) {
    const e = structuredClone(evidence); e.intake[field]--;
    assert.ok(reviewPublicPreservationOffer(e, offer, publicPlan, now).blockers.includes('initial-fill-exceeds-intake-budget'), field);
  }
});
test('invalid or absent allocation definitions and unsafe products cannot be treated as an elapsed time guarantee', () => {
  for (const mutate of [o => delete o.initialFill, o => o.initialFill.monthlyAllocations = 0,
    o => o.initialFill.dailyAllocations = NaN, o => o.initialFill.newAttemptReserve = -1,
    o => o.initialFill.editAttemptReserve = Number.MAX_SAFE_INTEGER,
    o => o.initialFill.monthlyAllocations = Number.MAX_SAFE_INTEGER,
    o => o.initialFill.basis = 'elapsed-days']) {
    const { evidence, offer } = publicFixture(); mutate(offer);
    assert.equal(reviewPublicPreservationOffer(evidence, offer, plan, now).publicOfferReviewReady, false);
  }
  const { evidence, offer } = publicFixture();
  assert.equal(reviewPublicPreservationOffer(evidence, offer, plan, now).initialFill.elapsedCompletionDeadlineGuaranteed, false);
});
test('a free, expired, stale, mismatched or unapproved AWS account cannot support the public retention promise', () => {
  for (const mutate of [e => delete e.awsAccount, e => e.awsAccount.planType = 'FREE',
    e => e.awsAccount.planStatus = 'EXPIRED', e => e.awsAccount.planExpirationAt = now + 20 * 86400000,
    e => delete e.awsAccount.planExpirationAt, e => e.awsAccount.accountId = '999999999999',
    e => e.configuration.recoveryAwsAccountId = 'unknown', e => e.awsAccount.confirmedAt = now - 86400000,
    e => e.awsAccount.confirmedAt = now + 1, e => e.awsAccount.approvalEvidenceReference = ' ']) {
    const { evidence, offer } = publicFixture(); mutate(evidence);
    assert.ok(reviewPublicPreservationOffer(evidence, offer, plan, now).blockers.includes('aws-account-continuity-unconfirmed'));
  }
});
test('paid AWS alone does not prove funding for retained owners, historical versions or delayed notices', () => {
  for (const mutate of [e => delete e.retentionFunding, e => e.retentionFunding.calendarMonths = 6,
    e => e.retentionFunding.minimumDaysAfterDeliveredFinalNotice = 29,
    e => e.retentionFunding.includesRetainedOwnersAndHistoricalVersions = false,
    e => e.retentionFunding.coversUnknownStatusAndUndeliveredNoticeExtension = false,
    e => e.retentionFunding.reviewedAt = now - 86400000, e => e.retentionFunding.evidenceReference = '']) {
    const { evidence, offer } = publicFixture(); mutate(evidence);
    assert.ok(reviewPublicPreservationOffer(evidence, offer, plan, now).blockers.includes('retention-funding-unconfirmed'));
  }
});

test('full-capacity export must survive the matching request limit without losing cancellation or owner boundaries', () => {
  for (const mutate of [e => delete e.bulkExport, e => e.bulkExport.recordCount--,
    e => e.bulkExport.requestsPerMinute = 120, e => e.bulkExport.window = 'rolling-minute',
    e => e.bulkExport.completed = false, e => e.bulkExport.archiveConsistent = false,
    e => e.bulkExport.cancellationStopsRequests = false, e => e.bulkExport.sessionChangeStopsRequests = false,
    e => e.bulkExport.confirmedAt = now - 86400000, e => e.bulkExport.appBuild = '',
    e => e.bulkExport.evidenceReference = ' ']) {
    const { evidence, offer } = publicFixture(); mutate(evidence);
    assert.ok(reviewPublicPreservationOffer(evidence, offer, plan, now).blockers.includes('full-export-with-request-limit-unconfirmed'));
  }
});
