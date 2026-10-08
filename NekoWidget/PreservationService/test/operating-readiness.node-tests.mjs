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
    sourceQuotaBytes: offer.ownerQuotaBytes, startedAt: now - 60_000, completedAt: now - 1,
    originalSessionExpiresAt: now + 1, authorizationRenewed: false, expiredSessionStopsAndCleans: true,
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
  evidence.bulkExport.sourceQuotaBytes = offer.ownerQuotaBytes;
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

test('a count-complete small export cannot attest the sold byte volume', () => {
  for (const bytes of [undefined, 1000, 4_999_999_999, 5_000_000_001, NaN, true, Number.MAX_SAFE_INTEGER + 1]) {
    const { evidence, offer, publicPlan } = largePublicFixture();
    evidence.bulkExport.sourceQuotaBytes = bytes;
    assert.ok(reviewPublicPreservationOffer(evidence, offer, publicPlan, now).blockers.includes('full-export-byte-volume-unconfirmed'));
  }
  const { evidence, offer, publicPlan } = largePublicFixture();
  assert.equal(reviewPublicPreservationOffer(evidence, offer, publicPlan, now).blockers.includes('full-export-byte-volume-unconfirmed'), false);
});

test('bulk export evidence must finish before the original deadline and prove expired-session cleanup', () => {
  for (const mutate of [e => delete e.startedAt, e => e.startedAt = now + 1,
    e => e.startedAt = now - 86400000, e => e.completedAt = e.startedAt,
    e => e.completedAt = now + 1, e => e.completedAt = e.originalSessionExpiresAt,
    e => e.originalSessionExpiresAt = e.completedAt - 1,
    e => e.originalSessionExpiresAt = e.startedAt + 900001,
    e => e.originalSessionExpiresAt = Number.MAX_SAFE_INTEGER + 1,
    e => e.confirmedAt = e.completedAt - 1, e => delete e.authorizationRenewed,
    e => e.authorizationRenewed = true, e => e.expiredSessionStopsAndCleans = false]) {
    const { evidence, offer } = publicFixture(); mutate(evidence.bulkExport);
    assert.ok(reviewPublicPreservationOffer(evidence, offer, plan, now).blockers.includes('full-export-original-session-unconfirmed'));
  }
  const { evidence, offer } = publicFixture();
  evidence.bulkExport.originalSessionExpiresAt = evidence.bulkExport.startedAt + 900000;
  assert.equal(reviewPublicPreservationOffer(evidence, offer, plan, now).publicOfferReviewReady, true);
});

// Schema evidence only, not a completed device or sold-capacity rehearsal.
const resumedFixture = () => {
  const f = publicFixture(), bulk = f.evidence.bulkExport, start = now - 1_800_000;
  Object.assign(bulk, { authorizationMode: 'explicit-reauthentication', authorizationRenewed: true,
    silentAuthorizationRenewed: false, cancellationStopsAndCleans: true, reauthenticationFailureStopsAndCleans: true,
    startedAt: start, originalSessionExpiresAt: start + 899_000, inventoryGeneration: 7, totalPages: 20,
    sessionSegments: [
      { sessionEvidenceId: 'synthetic-session-a', issuedAt: start - 1000, expiresAt: start + 899_000,
        startedAt: start, completedAt: start + 600_000, completedPagesBefore: 0, completedPagesAfter: 10,
        inventoryGeneration: 7, reauthentication: null },
      { sessionEvidenceId: 'synthetic-session-b', issuedAt: start + 911_000, expiresAt: start + 1_811_000,
        startedAt: start + 914_000, completedAt: start + 1_700_000, completedPagesBefore: 10, completedPagesAfter: 20,
        inventoryGeneration: 7, reauthentication: { previousSessionEvidenceId: 'synthetic-session-a',
          requestedAt: start + 910_000, confirmedAt: start + 912_000, verifiedAt: start + 913_000,
          userInitiated: true, appleIdentityConfirmed: true, sameOwner: true, newToken: true, newEpoch: true,
          inventoryUnchanged: true, pageBoundary: true } },
    ], finalAuthorizationCheck: { sessionEvidenceId: 'synthetic-session-b', verifiedAt: start + 1_750_000,
      sameOwner: true, sessionCurrent: true, inventoryUnchanged: true, beforeSharing: true } });
  return f;
};
const resumedReview = f => reviewPublicPreservationOffer(f.evidence, f.offer, plan, now);
const rejectsResume = f => {
  const result = resumedReview(f);
  assert.equal(result.publicOfferReviewReady, false);
  assert.ok(result.blockers.includes('full-export-reauthentication-unconfirmed'));
};

test('explicit user reauthentication qualifies a contiguous synthetic chain without approving deployment', () => {
  const f = resumedFixture(), bulk = f.evidence.bulkExport;
  assert.ok(bulk.completedAt > bulk.originalSessionExpiresAt);
  const result = resumedReview(f);
  assert.equal(result.publicOfferReviewReady, true); assert.equal(result.advisoryOnly, true);
  for (const key of ['deployPermission', 'salesApprovalPermission', 'remoteStateChanged',
    'noticePermission', 'permanentDeletionPermission']) assert.equal(result[key], false);
  assert.equal(JSON.stringify(result).includes('synthetic-session-'), false);
  // Pilot review is independent of this additional public authorization gate.
  delete bulk.sessionSegments;
  assert.equal(reviewOperatingEvidence(f.evidence, plan, now).newIntakeReviewReady, true);
  rejectsResume(f);
});

test('authorization modes cannot fall back to the legacy path with unknown modes or an ignored chain', () => {
  for (const mode of [null, '', 'automatic-renewal', 1, true]) {
    const f = publicFixture(); f.evidence.bulkExport.authorizationMode = mode;
    assert.ok(resumedReview(f).blockers.includes('full-export-authorization-mode-unconfirmed'));
  }
  const f = publicFixture(); f.evidence.bulkExport.authorizationMode = 'single-session';
  assert.equal(resumedReview(f).publicOfferReviewReady, true);
  f.evidence.bulkExport.sessionSegments = [];
  assert.ok(resumedReview(f).blockers.includes('full-export-original-session-unconfirmed'));
});

test('every session issuance, expiry and read segment has ordered bounded timestamps', () => {
  for (const mutate of [
    b => b.startedAt++, b => b.completedAt = b.startedAt, b => b.completedAt = now + 1,
    b => b.confirmedAt = b.completedAt - 1, b => b.startedAt = now - 86_400_000,
    b => b.originalSessionExpiresAt++, b => b.sessionSegments[0].issuedAt = -1,
    b => b.sessionSegments[0].expiresAt = b.sessionSegments[0].issuedAt,
    b => b.sessionSegments[0].issuedAt--, b => b.sessionSegments[1].expiresAt++,
    b => b.sessionSegments[1].issuedAt = NaN, b => b.sessionSegments[1].expiresAt = Number.MAX_SAFE_INTEGER + 1,
    b => b.sessionSegments[1].startedAt = b.sessionSegments[1].issuedAt - 1,
    b => b.sessionSegments[1].completedAt = b.sessionSegments[1].startedAt,
    b => b.sessionSegments[0].completedAt = b.sessionSegments[0].expiresAt,
    b => b.sessionSegments[1].completedAt = b.sessionSegments[1].expiresAt,
    b => b.completedAt = b.sessionSegments[1].expiresAt,
  ]) { const f = resumedFixture(); mutate(f.evidence.bulkExport); rejectsResume(f); }
});

test('each transition proves user Apple confirmation, replacement checkpoint and unchanged inventory before reading', () => {
  const flags = ['userInitiated', 'appleIdentityConfirmed', 'sameOwner', 'newToken', 'newEpoch', 'inventoryUnchanged', 'pageBoundary'];
  for (const key of flags) for (const value of [false, undefined, 'true']) {
    const f = resumedFixture(); f.evidence.bulkExport.sessionSegments[1].reauthentication[key] = value; rejectsResume(f);
  }
  for (const mutate of [r => r.previousSessionEvidenceId = 'synthetic-other-owner',
    r => r.requestedAt = now - 1_200_001, r => r.requestedAt = r.confirmedAt,
    r => r.confirmedAt = now - 889_001, r => r.verifiedAt = r.confirmedAt - 1,
    r => r.verifiedAt = now - 885_999, r => delete r.confirmedAt,
    r => r.token = 'must-not-be-supplied', r => r.ownerId = 'must-not-be-supplied']) {
    const f = resumedFixture(); mutate(f.evidence.bulkExport.sessionSegments[1].reauthentication); rejectsResume(f);
  }
});

test('page and session chains reject duplicate sessions, gaps, hidden switches, and mismatched final totals', () => {
  for (const mutate of [b => delete b.sessionSegments, b => b.sessionSegments = {}, b => b.sessionSegments.pop(),
    b => b.totalPages = 0, b => b.totalPages = b.recordCount + 1, b => b.totalPages = 19, b => b.totalPages = 21,
    b => b.inventoryGeneration = -1, b => b.sessionSegments[0].inventoryGeneration++,
    b => b.sessionSegments[1].sessionEvidenceId = b.sessionSegments[0].sessionEvidenceId,
    b => b.sessionSegments[1].sessionEvidenceId += '\n', b => b.sessionSegments[1].sessionEvidenceId += '\r\n',
    b => b.sessionSegments[1].sessionEvidenceId = '', b => b.sessionSegments[0].reauthentication = {},
    b => b.sessionSegments[0].completedPagesBefore = 1, b => b.sessionSegments[0].completedPagesAfter = 0,
    b => b.sessionSegments[1].completedPagesBefore--, b => b.sessionSegments[1].completedPagesBefore++,
    b => b.sessionSegments[1].completedPagesAfter--, b => b.sessionSegments[1].completedPagesAfter++,
    b => b.sessionSegments[1].unexpectedRenewal = true,
    b => b.authorizationRenewed = false, b => b.silentAuthorizationRenewed = true,
    b => delete b.silentAuthorizationRenewed, b => b.expiredSessionStopsAndCleans = false,
    b => b.cancellationStopsAndCleans = false, b => b.reauthenticationFailureStopsAndCleans = false,
  ]) { const f = resumedFixture(); mutate(f.evidence.bulkExport); rejectsResume(f); }
});

test('final shared output requires the last live session and a same-inventory check after all reads', () => {
  for (const mutate of [b => delete b.finalAuthorizationCheck,
    b => b.finalAuthorizationCheck.sessionEvidenceId = b.sessionSegments[0].sessionEvidenceId,
    b => b.finalAuthorizationCheck.verifiedAt = b.sessionSegments[1].completedAt - 1,
    b => b.finalAuthorizationCheck.verifiedAt = b.completedAt + 1,
    b => b.finalAuthorizationCheck.sameOwner = false, b => b.finalAuthorizationCheck.sessionCurrent = false,
    b => b.finalAuthorizationCheck.inventoryUnchanged = false, b => b.finalAuthorizationCheck.beforeSharing = false,
  ]) { const f = resumedFixture(); mutate(f.evidence.bulkExport); rejectsResume(f); }
  // Reauthentication after the last page may authorize only the final check.
  const f = resumedFixture(), segments = f.evidence.bulkExport.sessionSegments;
  segments[0].completedPagesAfter = 20; segments[1].completedPagesBefore = 20;
  assert.equal(resumedReview(f).publicOfferReviewReady, true);
});

test('every transition in a longer chain is checked and only its final segment may read zero pages', () => {
  const f = resumedFixture(), bulk = f.evidence.bulkExport, start = bulk.startedAt;
  bulk.sessionSegments.push({ sessionEvidenceId: 'synthetic-session-c', issuedAt: start + 1_721_000,
    expiresAt: start + 2_621_000, startedAt: start + 1_724_000, completedAt: start + 1_730_000,
    completedPagesBefore: 20, completedPagesAfter: 20, inventoryGeneration: 7,
    reauthentication: { ...bulk.sessionSegments[1].reauthentication, previousSessionEvidenceId: 'synthetic-session-b',
      requestedAt: start + 1_720_000, confirmedAt: start + 1_722_000, verifiedAt: start + 1_723_000 } });
  bulk.finalAuthorizationCheck.sessionEvidenceId = 'synthetic-session-c';
  assert.equal(resumedReview(f).publicOfferReviewReady, true);
  for (const mutate of [b => b.sessionSegments[2].sessionEvidenceId = b.sessionSegments[0].sessionEvidenceId,
    b => b.sessionSegments[1].reauthentication.newToken = false,
    b => b.sessionSegments[2].reauthentication.newToken = false,
    b => { b.sessionSegments[0].completedPagesAfter = 20; b.sessionSegments[1].completedPagesBefore = 20; }]) {
    const changed = structuredClone(f); mutate(changed.evidence.bulkExport); rejectsResume(changed);
  }
});

test('explicit reauthentication does not waive sold volume, record count, request limit or any existing public approval', () => {
  for (const mutate of [e => e.bulkExport.sourceQuotaBytes--, e => e.bulkExport.recordCount--,
    e => e.bulkExport.requestsPerMinute = 120, e => e.bulkExport.window = 'rolling-minute',
    e => e.bulkExport.archiveConsistent = false, e => e.bulkExport.sessionChangeStopsRequests = false,
    e => e.bulkExport.cancellationStopsRequests = false, e => e.bulkExport.completed = false,
    e => e.capacityMatchesDeployedConfiguration = false, e => e.configuration.mode = 'pilot']) {
    const f = resumedFixture(); mutate(f.evidence); assert.equal(resumedReview(f).publicOfferReviewReady, false);
  }
  const f = resumedFixture(); f.offer.approval.status = 'proposed';
  assert.equal(resumedReview(f).publicOfferReviewReady, false);
});
