import test from 'node:test';
import assert from 'node:assert/strict';
import { BASELINE, estimateR2, illustrativeScenarios } from './cost-model.mjs';

test('reproduces the prior 1 MB x 10,000 photos x 1,000 accounts estimate', () => {
  const result = estimateR2(BASELINE);
  assert.equal(result.primaryPhotoGB, 10000);
  assert.equal(result.storageUSD, 150);
  assert.equal(result.operationsUSD, 4.86);
  assert.equal(result.modeledR2USD, 154.86);
});

test('retained non-paying records still cost money and do not inflate payer count', () => {
  const result = estimateR2({ ...BASELINE, retainedNonPayingAccounts: 1000 });
  assert.equal(result.storedAccounts, 2000);
  assert.equal(result.storageUSD, 300);
  assert.equal(result.modeledR2USDPerPayingAccount, 0.30486);
});

test('copies and derivatives are explicit storage multipliers, not hidden costs', () => {
  const result = estimateR2({ ...BASELINE, copyMultiplier: 2, overheadRatio: 0.15 });
  assert.equal(result.modeledGBMonth, 23000);
  assert.equal(result.storageUSD, 345);
  assert.equal(result.operationsUSD, 4.86); // Caller supplies complete request totals separately.
});

test('zero payers is not zero storage cost or an infinite per-payer result', () => {
  const result = estimateR2({ ...BASELINE, payingAccounts: 0, retainedNonPayingAccounts: 1000 });
  assert.equal(result.storageUSD, 150);
  assert.equal(result.modeledR2USDPerPayingAccount, null);
});

test('rounds billing units at the whole-account level and only beyond each boundary', () => {
  const exact = estimateR2({ ...BASELINE, payingAccounts: 1, photosPerAccount: 1, averagePhotoMB: 1000,
    monthlyClassA: 1000000, monthlyClassB: 1000000 });
  assert.deepEqual([exact.billableGBMonth, exact.billableClassAMillions, exact.billableClassBMillions], [1, 1, 1]);
  const beyond = estimateR2({ ...exact.assumptions, averagePhotoMB: 1100, monthlyClassA: 1000001, monthlyClassB: 1000001 });
  assert.deepEqual([beyond.billableGBMonth, beyond.billableClassAMillions, beyond.billableClassBMillions], [2, 2, 2]);
});

test('free tier is optional and applies once, not once per user', () => {
  const result = estimateR2({ ...BASELINE, applyAccountFreeTier: true });
  assert.equal(result.billableGBMonth, 9990);
  assert.equal(result.operationsUSD, 0);
  const empty = estimateR2({ ...BASELINE, payingAccounts: 0, monthlyClassA: 0, monthlyClassB: 0, applyAccountFreeTier: true });
  assert.equal(empty.modeledR2USD, 0);
});

test('rejects missing, misspelled, negative, nonfinite and unsafe inputs', () => {
  for (const bad of [null, {}, { ...BASELINE, averagePhotosMB: 1 },
    { ...BASELINE, averagePhotoMB: -1 }, { ...BASELINE, averagePhotoMB: 0 },
    { ...BASELINE, averagePhotoMB: Infinity }, { ...BASELINE, payingAccounts: 1.5 },
    { ...BASELINE, copyMultiplier: 0 }, { ...BASELINE, applyAccountFreeTier: 'false' },
    { ...BASELINE, payingAccounts: Number.MAX_SAFE_INTEGER, retainedNonPayingAccounts: 1 }]) {
    assert.throws(() => estimateR2(bad));
  }
});

test('scenario examples preserve inputs and label estimates as estimates', () => {
  const before = JSON.stringify(BASELINE);
  const rows = illustrativeScenarios();
  assert.deepEqual(rows.map(row => row.storageUSD), [150, 345, 690, 2070]);
  assert.equal(JSON.stringify(BASELINE), before);
  assert.ok(rows.every(row => row.warning.includes('not measured')));
  assert.ok(rows.every(row => row.exclusions.length > 0));
});
