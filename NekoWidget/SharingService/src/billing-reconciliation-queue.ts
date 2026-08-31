import type { Env } from "./env";

export async function requestBillingReconciliation(
  env: Env,
  originalTransactionId: string,
  now = Math.floor(Date.now() / 1_000),
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO billing_reconciliation_jobs(
       original_transaction_id, requested_at, not_before
     ) VALUES (?, ?, ?)
     ON CONFLICT(original_transaction_id) DO UPDATE SET
       requested_at = MAX(billing_reconciliation_jobs.requested_at, excluded.requested_at),
       not_before = MIN(billing_reconciliation_jobs.not_before, excluded.not_before),
       request_generation = billing_reconciliation_jobs.request_generation + 1,
       updated_at = unixepoch()`,
  ).bind(originalTransactionId, now, now).run();
}
