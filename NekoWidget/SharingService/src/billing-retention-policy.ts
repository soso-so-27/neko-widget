/** UTC calendar months, clamped to the last day of the destination month.
 * 2024-02-29 therefore expires on 2025-02-28, not March 1 or 365 fixed days.
 */
export function twelveCalendarMonthsAfter(value: number): number {
  if (!Number.isSafeInteger(value) || value < 1) throw new Error('invalid retention date');
  const date = new Date(value);
  const year = date.getUTCFullYear() + 1;
  const month = date.getUTCMonth();
  const day = Math.min(date.getUTCDate(), new Date(Date.UTC(year, month + 1, 0)).getUTCDate());
  const result = Date.UTC(year, month, day, date.getUTCHours(), date.getUTCMinutes(),
    date.getUTCSeconds(), date.getUTCMilliseconds());
  if (!Number.isSafeInteger(result)) throw new Error('invalid retention deadline');
  return result;
}

export interface RetentionLineageFact {
  environment: 'Production' | 'Sandbox';
  originalTransactionId: string;
  // From the verified, signed EXPIRED/REVOKE notification + matching transaction.
  terminationAtMs: number | null;
  terminationSignedAtMs: number | null;
  latestSignedAtMs: number;
  currentStatus: 'active' | 'gracePeriod' | 'billingRetry' | 'expired' | 'revoked' | 'upgraded' | 'unconfirmed';
  authorityFreshUntilMs: number;
}

/** The account, not one convenient Sandbox lineage, is the retention unit.
 * Null means unknown/ineligible, never permission to erase.
 */
export function accountRetentionDeadline(facts: readonly RetentionLineageFact[], nowMs: number): number | null {
  if (!Number.isSafeInteger(nowMs) || nowMs < 1 || facts.length === 0) return null;
  const keys = new Set<string>();
  let endedAt = 0;
  for (const fact of facts) {
    const key = `${fact.environment}:${fact.originalTransactionId}`;
    if (keys.has(key) || !['Production', 'Sandbox'].includes(fact.environment)
      || !/^\d{1,32}$/u.test(fact.originalTransactionId)) return null;
    keys.add(key);
    if (!Number.isSafeInteger(fact.latestSignedAtMs) || fact.latestSignedAtMs < 1
      || !Number.isSafeInteger(fact.authorityFreshUntilMs)
      || !['expired', 'revoked'].includes(fact.currentStatus)
      || !Number.isSafeInteger(fact.terminationAtMs) || fact.terminationAtMs! < 1
      || fact.terminationAtMs! > nowMs
      || !Number.isSafeInteger(fact.terminationSignedAtMs)
      || fact.terminationSignedAtMs! < fact.terminationAtMs!
      || fact.latestSignedAtMs > fact.terminationSignedAtMs!
      || fact.authorityFreshUntilMs <= nowMs) return null;
    endedAt = Math.max(endedAt, fact.terminationAtMs!);
  }
  return twelveCalendarMonthsAfter(endedAt);
}
