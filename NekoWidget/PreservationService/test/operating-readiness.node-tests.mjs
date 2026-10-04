import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { reviewOperatingEvidence } from '../scripts/operating-readiness.mjs';
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
