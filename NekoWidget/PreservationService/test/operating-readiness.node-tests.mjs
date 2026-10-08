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
    approval: { status: 'approved', evidenceReference: 'fixture-only-not-real-approval' } };
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
    e => e.configuration.requestLimiterScope = 'ip', e => e.configuration.perParticipantRequestsPerMinute = 120]) {
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
