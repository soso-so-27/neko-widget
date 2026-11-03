import { env } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';
import { accountRetentionDeadline, twelveCalendarMonthsAfter, type RetentionLineageFact } from '../src/billing-retention-policy';
import { BillingRetentionJournal, requireBillingRetentionSnapshot, type BillingRetentionEnv } from '../src/billing-retention-journal';

const now = Date.UTC(2026, 10, 3);
const ended = Date.UTC(2025, 10, 3);
const fact = (overrides: Partial<RetentionLineageFact> = {}): RetentionLineageFact => ({
  environment: 'Production', originalTransactionId: '900001', terminationAtMs: ended,
  terminationSignedAtMs: ended + 1000, latestSignedAtMs: ended + 1000,
  currentStatus: 'expired', authorityFreshUntilMs: now + 1000, ...overrides,
});
const testEnv = env as unknown as BillingRetentionEnv;
const bucket = testEnv.MEDIA!;
const prefix = '__billing_retention/v1/';
const candidate = () => ({ requestId: crypto.randomUUID(), billingAccountId: crypto.randomUUID(),
  receiptHash: 'A'.repeat(43), reason: 'subscription-ended' as const, requestedAtMs: now,
  endedAtMs: ended, cutoffMs: now, expectedRevision: 0, factsHash: 'B'.repeat(43) });
async function reset() {
  const old = await bucket.list({ prefix });
  for (const object of old.objects) await bucket.delete(object.key);
  await bucket.put(`${prefix}control`, JSON.stringify({ version: 1, deployment: 'local', sequence: 0 }));
  return new BillingRetentionJournal(bucket);
}

describe('B8 decision-changing local D1/R2 preflight', () => {
  it('uses twelve calendar months including leap day and preserves time of day', () => {
    expect(twelveCalendarMonthsAfter(Date.UTC(2024, 1, 29, 12, 30, 45, 123)))
      .toBe(Date.UTC(2025, 1, 28, 12, 30, 45, 123));
    expect(twelveCalendarMonthsAfter(Date.UTC(2025, 0, 31))).toBe(Date.UTC(2026, 0, 31));
    expect(accountRetentionDeadline([fact()], now)).toBe(now);
  });
  it('does not expire an account with active Production because Sandbox ended', () => {
    expect(accountRetentionDeadline([fact({ environment: 'Sandbox' }),
      fact({ currentStatus: 'active', terminationAtMs: null })], now)).toBeNull();
    for (const currentStatus of ['gracePeriod', 'billingRetry', 'upgraded', 'unconfirmed'] as const) {
      expect(accountRetentionDeadline([fact(), fact({ environment: 'Sandbox', currentStatus })], now)).toBeNull();
    }
  });
  it('requires a signed end for every lineage and stops at renewal, stale authority, or duplicates', () => {
    for (const override of [{ terminationSignedAtMs: null }, { terminationAtMs: null },
      { latestSignedAtMs: ended + 1001 }, { authorityFreshUntilMs: now }]) {
      expect(accountRetentionDeadline([fact(override)], now)).toBeNull();
    }
    expect(accountRetentionDeadline([fact(), fact()], now)).toBeNull();
    expect(accountRetentionDeadline([], now)).toBeNull();
    expect(accountRetentionDeadline([fact(), fact({ environment: 'Sandbox', terminationAtMs: ended + 1,
      terminationSignedAtMs: ended + 1000 })], now)).toBe(now + 1);
  });
  it('does not initialize a missing independent fence during a request', async () => {
    await bucket.delete(`${prefix}control`);
    await expect(new BillingRetentionJournal(bucket).append(candidate())).rejects.toMatchObject({ status: 503 });
    expect(await bucket.get(`${prefix}control`)).toBeNull();
  });
  it('retains an immutable receipt, rejects a changed caller, and stores no raw transaction ID', async () => {
    const journal = await reset();
    const input = candidate();
    const saved = await journal.append(input);
    expect(saved.sequence).toBe(1);
    expect(await journal.append(input)).toEqual(saved);
    expect((await journal.control()).sequence).toBe(1);
    expect(await new BillingRetentionJournal(bucket).request(input.requestId)).toEqual(saved);
    await expect(journal.append({ ...input, billingAccountId: crypto.randomUUID() })).rejects.toMatchObject({ status: 409 });
    expect(JSON.stringify(saved)).not.toContain('900001');
    expect(Object.keys(saved)).not.toContain('originalTransactionId');
  });
  it('resumes a durable entry after interruption before control publication without overwriting it', async () => {
    const journal = await reset();
    const input = candidate();
    const entry = { version: 1 as const, sequence: 1, ...input };
    await bucket.put(`${prefix}entries/0000000000000001`, JSON.stringify(entry));
    await expect(journal.append(candidate())).rejects.toMatchObject({ status: 409 });
    expect((await journal.control()).sequence).toBe(1);
    expect(await journal.append(input)).toEqual(entry);
    expect(await journal.entry(1)).toEqual(entry);
  });
  it('fails closed after an old D1 checkpoint is restored while the independent R2 fence survives', async () => {
    const journal = await reset();
    await testEnv.DB.exec('CREATE TABLE IF NOT EXISTS billing_retention_checkpoint(singleton INTEGER PRIMARY KEY,applied_sequence INTEGER NOT NULL)');
    await testEnv.DB.exec('INSERT OR REPLACE INTO billing_retention_checkpoint VALUES(1,0)');
    const guarded = { ...testEnv, BILLING_TRANSACTION_RETENTION_REQUIRED: 'YES' };
    await requireBillingRetentionSnapshot(guarded);
    await journal.append(candidate());
    await expect(requireBillingRetentionSnapshot(guarded)).rejects.toMatchObject({ status: 503 });
    await testEnv.DB.exec('UPDATE billing_retention_checkpoint SET applied_sequence=1');
    await requireBillingRetentionSnapshot(guarded);
    // Restore only the older D1 state; R2 remains independent.
    await testEnv.DB.exec('UPDATE billing_retention_checkpoint SET applied_sequence=0');
    await expect(requireBillingRetentionSnapshot(guarded)).rejects.toMatchObject({ status: 503 });
  });
});
