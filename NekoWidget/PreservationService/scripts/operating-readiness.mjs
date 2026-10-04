// Local advisory only. No credentials, network, notifications or deletion.
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export function reviewOperatingEvidence(evidence, plan, now = Date.now()) {
  const blockers = [];
  const positive = value => Number.isSafeInteger(value) && value > 0;
  const validPlan = [plan?.archive?.reviewLifetimeHours, plan?.maximumParticipants,
    plan?.archive?.globalActiveBytesLimit, plan?.currency?.warningForecastYen,
    plan?.currency?.pauseNewIntakeForecastYen].every(positive)
    && plan.currency.warningForecastYen < plan.currency.pauseNewIntakeForecastYen;
  if (!validPlan || !Number.isSafeInteger(now) || now < 0) return {
    version: 1, advisoryOnly: true, remoteStateChanged: false, newIntakeReviewReady: false,
    blockers: ['invalid-review-plan-or-clock'], noticePermission: false, permanentDeletionPermission: false };
  const fresh = value => Number.isSafeInteger(value) && value <= now
    && value >= now - plan.archive.reviewLifetimeHours * 3_600_000;
  const count = value => Number.isSafeInteger(value) && value >= 0;
  if (evidence?.version !== 1) blockers.push('unsupported-evidence');
  if (!fresh(evidence?.observedAt)) blockers.push('stale-or-missing-observation');
  const usage = evidence?.usage;
  if (!usage || !['activeOwners', 'retainedOwners', 'primaryBytes', 'recoveryBytesIncludingVersions']
    .every(key => count(usage[key]))) blockers.push('incomplete-usage');
  else {
    if (usage.activeOwners + usage.retainedOwners >= plan.maximumParticipants) blockers.push('no-participant-slot');
    if (usage.primaryBytes >= plan.archive.globalActiveBytesLimit) blockers.push('no-storage-slot');
    if (usage.recoveryBytesIncludingVersions < usage.primaryBytes) blockers.push('incomplete-recovery-accounting');
  }
  const cost = evidence?.cost;
  if (!cost || !fresh(cost.confirmedAt) || !count(cost.forecastMonthlyYen)
    || cost.includesRetainedOwnersAndHistoricalVersions !== true
    || cost.includesOperationsComputeKmsAndNotices !== true) blockers.push('incomplete-cost-review');
  else if (cost.forecastMonthlyYen >= plan.currency.pauseNewIntakeForecastYen) blockers.push('intake-budget-threshold');
  const sandbox = evidence?.sandbox;
  if (!sandbox || !fresh(sandbox.confirmedAt) || !['purchase', 'purchaseSheetCancel', 'cancelBeforeExpiry', 'restore', 'expiry',
    'preservationAccess'].every(key => sandbox[key] === true)) blockers.push('sandbox-device-check-incomplete');
  if (evidence?.capacityMatchesDeployedConfiguration !== true) blockers.push('deployed-capacity-unconfirmed');
  return { version: 1, advisoryOnly: true, remoteStateChanged: false,
    newIntakeReviewReady: blockers.length === 0, blockers,
    costWarning: count(cost?.forecastMonthlyYen) && cost.forecastMonthlyYen >= plan.currency.warningForecastYen,
    retention: { calendarMonths: 12, minimumDaysAfterDeliveredFinalNotice: 30,
      freshPrivateBillingRequired: true, unknownPausesDeadline: true },
    noticePermission: false, permanentDeletionPermission: false };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.length !== 3) throw new Error('Usage: node scripts/operating-readiness.mjs <aggregate-evidence.json>');
  const plan = JSON.parse(await readFile(new URL('../operations/pilot-plan.json', import.meta.url), 'utf8'));
  const evidence = JSON.parse(await readFile(process.argv[2], 'utf8'));
  const report = reviewOperatingEvidence(evidence, plan);
  console.log(JSON.stringify(report, null, 2));
  if (!report.newIntakeReviewReady) process.exitCode = 1;
}
