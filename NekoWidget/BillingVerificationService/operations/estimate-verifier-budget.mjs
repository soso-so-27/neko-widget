// Local arithmetic only. Does not authenticate, create resources or change gates.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const plan = JSON.parse(readFileSync(new URL('./deployment-plan.json', import.meta.url)));
const pilot = JSON.parse(readFileSync(new URL('../../PreservationService/operations/pilot-plan.json', import.meta.url)));
const base = JSON.parse(execFileSync(process.execPath,
  [fileURLToPath(new URL('../../PreservationService/scripts/estimate-pilot-budget.mjs', import.meta.url))],
  { encoding: 'utf8' }));
const multiplier = pilot.currency.yenPerUsdAssumption * pilot.currency.taxAllowanceMultiplier;
const scenarios = [
  ['recommended', plan.host.recommendedMonthlyUsd], ['smallest-unmeasured', plan.host.smallestMonthlyUsd],
].map(([name, monthlyUsd]) => {
  const hostYen = Math.ceil(Number((monthlyUsd * multiplier).toFixed(8)));
  const total = base.monthlyPlanningYen.totalWithoutFreeAllowances + hostYen;
  const withAvailableR2Allowance = base.monthlyPlanningYen.totalOnlyIfR2OperationAllowanceIsAvailable + hostYen;
  return { name, hostYen, totalWithoutFreeAllowances: total,
    totalOnlyIfR2AllowanceIsProvenAvailable: withAvailableR2Allowance,
    exceedsMonthlyTarget: total > pilot.currency.monthlyTargetYen,
    exceedsExistingIntakePauseThreshold: total >= pilot.currency.pauseNewIntakeForecastYen };
});
console.log(JSON.stringify({ status: plan.status, monetaryHardCap: false, canStartNewIntake: false,
  assumedYenPerUsd: pilot.currency.yenPerUsdAssumption,
  taxMultiplier: pilot.currency.taxAllowanceMultiplier, scenarios }, null, 2));
