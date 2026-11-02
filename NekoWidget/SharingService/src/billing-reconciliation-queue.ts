import type { Env } from "./env";

export async function requestBillingReconciliation(
  env: Env,
  originalTransactionId: string,
  now = Math.floor(Date.now() / 1_000),
  storeEnvironment = env.BILLING_STORE_ENVIRONMENT,
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO billing_reconciliation_jobs(
       environment, original_transaction_id, requested_at, not_before, request_generation
     ) VALUES (?, ?, ?, ?, COALESCE((SELECT request_generation + 1
       FROM billing_effective_entitlement_current WHERE environment = ? AND original_transaction_id = ?), 1))
     ON CONFLICT(environment, original_transaction_id) DO UPDATE SET
       requested_at = MAX(billing_reconciliation_jobs.requested_at, excluded.requested_at),
       not_before = MIN(billing_reconciliation_jobs.not_before, excluded.not_before),
       request_generation = MAX(billing_reconciliation_jobs.request_generation + 1,
                                excluded.request_generation),
       updated_at = unixepoch()`,
  ).bind(storeEnvironment, originalTransactionId, now, now, storeEnvironment, originalTransactionId).run();
}
