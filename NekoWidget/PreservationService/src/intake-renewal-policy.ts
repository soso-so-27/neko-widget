/** Approved 1102c monetary boundaries. Attempt/byte values are the initial
 * proposal; provisioning does not apply them to the live admission row. */
export const renewalPolicy = Object.freeze({
  warningYen: 5000, stopYen: 10000, preservationReserveYen: 3000,
  modelFloorYen: 5610, yenPerUsd: 160, taxMultiplier: 1.1,
  intervalMs: 6 * 60 * 60 * 1000, lifetimeMs: 8 * 60 * 60 * 1000,
  leaseMs: 60000, maxCostPages: 2,
  limits: Object.freeze({
    maximum_owners: 100, daily_registration_limit: 10,
    daily_attempt_limit: 200, monthly_attempt_limit: 6200, monthly_bytes_limit: 3100000000,
    daily_mutation_limit: 600, monthly_mutation_limit: 18600, monthly_mutation_bytes_limit: 6200000000,
    pause_forecast_yen: 10000,
  }),
});
export interface CostObservation {
  collectedAt: number;
  awsMonthlyUsd: number;
  cloudflareMonthlyUsd: number;
  awsPages: number;
  oldestCoveredAt: number;
  includesEntireAccounts: true;
}
export function forecastYen(o: CostObservation, now: number): number {
  if (!Number.isSafeInteger(o.collectedAt) || o.collectedAt > now || o.collectedAt <= now - 60000
      || !Number.isSafeInteger(o.oldestCoveredAt) || o.oldestCoveredAt > now
      || o.oldestCoveredAt < now - 48 * 60 * 60 * 1000 || o.includesEntireAccounts !== true
      || !Number.isInteger(o.awsPages) || o.awsPages < 1 || o.awsPages > renewalPolicy.maxCostPages
      || ![o.awsMonthlyUsd, o.cloudflareMonthlyUsd].every(n => Number.isFinite(n) && n >= 0)) {
    throw Error('Cost evidence unavailable');
  }
  // Credits never erase costs. Include full shared account usage conservatively,
  // Cloudflare's fixed plan, Apple/domain allocation and bounded CE polling.
  const measured = (o.awsMonthlyUsd + o.cloudflareMonthlyUsd + 5 + 9.5 + 2.48)
    * renewalPolicy.yenPerUsd * renewalPolicy.taxMultiplier;
  return Math.ceil(Math.max(renewalPolicy.modelFloorYen, measured) + renewalPolicy.preservationReserveYen);
}
