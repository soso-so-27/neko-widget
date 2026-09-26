// Read-only local cost arithmetic. Never authenticates, deploys or enables intake.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const plan = JSON.parse(await readFile(new URL('../operations/pilot-plan.json', import.meta.url), 'utf8'));
const c = plan.costScenario;
const money = plan.currency;
const yen = dollars => dollars * money.yenPerUsdAssumption * money.taxAllowanceMultiplier;
for (const [name, value] of Object.entries(c)) {
  if (name === 'description') continue;
  assert(Number.isFinite(value) && value >= 0, `Invalid cost input: ${name}`);
}
assert(plan.status === 'local-plan-not-applied');
assert(money.warningForecastYen < money.pauseNewIntakeForecastYen);
assert(money.pauseNewIntakeForecastYen < money.monthlyTargetYen);
assert.equal(plan.archive.ownerQuotaBytes * plan.maximumParticipants, plan.archive.globalActiveBytesLimit);
assert(c.s3StoredBytes >= c.r2StoredBytes, 'Recovery photo copy must not be omitted');
const fixed = yen(c.workersMonthlyUsd + c.kmsKeyCount * c.kmsMonthlyUsdPerKey);
const stored = yen(Math.ceil(c.r2StoredBytes / 1e9) * c.r2UsdPerDecimalGbMonth
  + c.s3StoredBytes / 2 ** 30 * c.s3UsdPerGibMonth);
// R2 rounds each billable operation class UP to a million, not pro-rata.
// With no shared allowance or room in an existing paid unit, even a small
// test may add one full unit of each class. Do not hide this in a ¥500 reserve.
const r2Operations = yen(Math.ceil(c.r2ClassARequests / 1_000_000) * c.r2UsdPerMillionClassA
  + Math.ceil(c.r2ClassBRequests / 1_000_000) * c.r2UsdPerMillionClassB);
const hourly = yen(3600 * c.containerInstances * (
  c.containerVcpu * c.containerUsdPerVcpuSecond
  + c.containerMemoryGib * c.containerUsdPerGibSecond
  + c.containerDiskGb * c.containerUsdPerGbDiskSecond));
const other = c.otherOperationsTransferAndNoticeReserveYen;
const rounded = value => Math.ceil(value);
console.log(JSON.stringify({
  status: plan.status,
  assumptions: { yenPerUsd: money.yenPerUsdAssumption,
    taxAllowanceMultiplier: money.taxAllowanceMultiplier,
    fixedFeesAndStoragePeriod: 'full month, even for a seven-day trial',
    baseScenarioFreeCreditsOrAllowancesDeducted: false,
    comparisonScenarioDeductsOnlyAvailableR2OperationAllowance: true,
    otherYenIsReserveNotMeasuredCharge: true },
  monthlyPlanningYen: {
    fixed: rounded(fixed), photoAndRecoveryStorage: rounded(stored),
    containerAt10HoursFullProvisionedCpu: rounded(hourly * c.containerHours),
    r2OperationUnitsWithoutSharedAllowance: rounded(r2Operations),
    otherOperationsTransferAndNoticeReserve: other,
    totalWithoutFreeAllowances: rounded(fixed + stored + r2Operations + hourly * c.containerHours + other),
    totalOnlyIfR2OperationAllowanceIsAvailable: rounded(fixed + stored + hourly * c.containerHours + other),
  },
  failureScenarioNotPredictedUsage: {
    description: 'One basic container continuously active at full provisioned CPU for 30 days',
    monthlyPlanningYenWithoutFreeAllowances: rounded(fixed + stored + r2Operations + hourly * 24 * 30 + other),
    runtimeLimitActuallyApplied: false,
  },
  stopRules: { warningForecastYen: money.warningForecastYen,
    pauseNewIntakeForecastYen: money.pauseNewIntakeForecastYen,
    reviewLifetimeHours: plan.archive.reviewLifetimeHours,
    monetaryHardCap: false, remoteControlsApplied: false },
  exclusions: plan.excludedFromEnforcedCap,
}, null, 2));
