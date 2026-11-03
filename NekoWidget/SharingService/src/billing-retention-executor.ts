import { sha256Base64url } from './encoding';
import type { VerifiedBillingTransaction } from './billing-verifier-client';
import { ApiError } from './errors';
import { billingRetentionJournal, requireBillingRetentionSnapshot,
  type BillingRetentionEntry, type BillingRetentionEnv } from './billing-retention-journal';

// Child first. Shared history commits/cursors and other accounts' records survive.
export const billingRetentionEraseSteps = [
  ['billing_window_sponsorships', `last_request_id IN (SELECT client_request_id FROM billing_window_sponsorship_requests WHERE billing_account_id=?)`],
  ['billing_window_sponsorship_requests', 'billing_account_id=?'],
  ['billing_apple_notification_history_page_records', `(environment,notification_uuid) IN (SELECT environment,notification_uuid FROM billing_apple_notification_events WHERE billing_account_id=?)`],
  ['billing_apple_notification_reconciliation_causes', `(environment,notification_uuid) IN (SELECT environment,notification_uuid FROM billing_apple_notification_events WHERE billing_account_id=?)`],
  ['billing_reconciliation_jobs', `(environment,original_transaction_id) IN (SELECT environment,original_transaction_id FROM billing_transaction_lineages WHERE billing_account_id=?)`],
  ['billing_effective_entitlement_current', 'billing_account_id=?'],
  ['billing_effective_entitlement_decisions', 'billing_account_id=?'],
  ['billing_subscription_authority_observations', 'billing_account_id=?'],
  ['billing_account_apple_identities', 'billing_account_id=?'],
  ['billing_account_recovery_requests', 'billing_account_id=?'],
  ['billing_transaction_events', 'billing_account_id=?'],
  ['billing_apple_notification_events', 'billing_account_id=?'],
  ['billing_transaction_lineages', 'billing_account_id=?'],
] as const;

export async function requireBillingAccountNotErasing(env: BillingRetentionEnv, account: string): Promise<void> {
  await requireBillingRetentionSnapshot(env);
  if (env.BILLING_TRANSACTION_RETENTION_REQUIRED !== 'YES') return;
  const fence = await env.DB.prepare('SELECT state FROM billing_retention_fences WHERE billing_account_id=?')
    .bind(account).first<{ state: string }>();
  if (fence && fence.state !== 'active') {
    throw new ApiError(409, 'billing_account_erased', 'Explicit verified purchase recovery is required.');
  }
}

/** A stale D1 checkpoint never means no deletion. Reapply external receipts
 * in bounded, atomic steps before any ordinary caller may serve restored data.
 */
export async function reconcileBillingRetentionJournal(env: BillingRetentionEnv, limit = 8): Promise<number> {
  if (!Number.isInteger(limit) || limit < 1 || limit > 32) throw new Error('invalid retention limit');
  const journal = billingRetentionJournal(env);
  const control = await journal.control();
  const local = await env.DB.prepare('SELECT applied_sequence FROM billing_retention_checkpoint WHERE singleton=1')
    .first<{ applied_sequence: number }>();
  if (!local || local.applied_sequence > control.sequence) throw new Error('retention checkpoint mismatch');
  let applied = local.applied_sequence;
  while (applied < control.sequence && applied - local.applied_sequence < limit) {
    const entry = await journal.entry(applied + 1);
    const canceled = await journal.canceled(entry);
    const completed = await journal.completed(entry);
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO billing_retention_requests(request_id,sequence,billing_account_id,
        receipt_hash,reason,requested_at_ms,ended_at_ms,cutoff_ms,facts_hash,expected_revision,state,completed_at_ms)
        VALUES(?,?,?,?,?,?,?,?,?,?,CASE WHEN ?=1 THEN 'canceled'
          WHEN ?='account-deletion' OR ?=1 OR COALESCE((SELECT revision FROM billing_retention_account_revisions WHERE billing_account_id=?),0)=?
          THEN 'deleting' ELSE 'canceled' END,NULL)`)
        .bind(entry.requestId,entry.sequence,entry.billingAccountId,entry.receiptHash,entry.reason,
          entry.requestedAtMs,entry.endedAtMs,entry.cutoffMs,entry.factsHash,entry.expectedRevision,
          canceled?1:0,entry.reason,completed!==null?1:0,entry.billingAccountId,entry.expectedRevision),
      env.DB.prepare(`INSERT INTO billing_retention_fences(billing_account_id,sequence,state,cutoff_ms)
        SELECT ?,?,'deleting',? WHERE EXISTS(SELECT 1 FROM billing_retention_requests WHERE request_id=? AND state='deleting')
        ON CONFLICT(billing_account_id) DO UPDATE SET
        sequence=excluded.sequence,state='deleting',cutoff_ms=excluded.cutoff_ms,
        recovery_environment=NULL,recovery_lineage_hash=NULL,recovery_transaction_hash=NULL,recovery_request_id=NULL
        WHERE excluded.sequence>billing_retention_fences.sequence`)
        .bind(entry.billingAccountId,entry.sequence,entry.cutoffMs,entry.requestId),
      env.DB.prepare(`DELETE FROM billing_retention_recoveries WHERE billing_account_id=?
        AND EXISTS(SELECT 1 FROM billing_retention_requests WHERE request_id=? AND state='deleting')`)
        .bind(entry.billingAccountId,entry.requestId),
      env.DB.prepare(`DELETE FROM billing_reconciliation_jobs WHERE (environment,original_transaction_id)
        IN(SELECT environment,original_transaction_id FROM billing_transaction_lineages WHERE billing_account_id=?)
        AND EXISTS(SELECT 1 FROM billing_retention_requests WHERE request_id=? AND state='deleting')`)
        .bind(entry.billingAccountId,entry.requestId),
      env.DB.prepare(`DELETE FROM billing_effective_entitlement_current WHERE billing_account_id=?
        AND EXISTS(SELECT 1 FROM billing_retention_requests WHERE request_id=? AND state='deleting')`).bind(entry.billingAccountId,entry.requestId),
    ]);
    const actual = await env.DB.prepare('SELECT request_id,facts_hash,state FROM billing_retention_requests WHERE sequence=?')
      .bind(entry.sequence).first<{ request_id: string; facts_hash: string; state:string }>();
    if (!actual || actual.request_id !== entry.requestId || actual.facts_hash !== entry.factsHash) throw new Error('retention receipt mismatch');
    // The external cancellation must survive rollback before ordinary service resumes.
    if(actual.state==='canceled') await journal.cancel(entry);
    await env.DB.prepare('UPDATE billing_retention_checkpoint SET applied_sequence=? WHERE singleton=1 AND applied_sequence=?')
      .bind(entry.sequence,applied).run();
    applied = entry.sequence;
  }
  return applied;
}

export async function remainingBillingTransactionRows(env: BillingRetentionEnv, account: string): Promise<number> {
  const results = await env.DB.batch(billingRetentionEraseSteps.map(([table, predicate]) =>
    env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${predicate}`).bind(account)));
  return results.reduce((sum, result) => sum + Number((result.results[0] as { n: number }).n), 0);
}

export async function runBillingTransactionDeletion(env: BillingRetentionEnv, nowMs = Date.now(), budget = 32): Promise<void> {
  if (env.BILLING_TRANSACTION_RETENTION_REQUIRED !== 'YES') return;
  if (!Number.isInteger(budget) || budget < 1 || budget > 64) throw new Error('invalid deletion budget');
  await reconcileBillingRetentionJournal(env);
  await requireBillingRetentionSnapshot(env);
  const journal = billingRetentionJournal(env);
  const pending = await env.DB.prepare(`SELECT request_id,state,completed_at_ms FROM billing_retention_requests
    WHERE state='deleting' OR (state='completed' AND receipt_recorded=0) ORDER BY sequence LIMIT 1`)
    .first<{ request_id: string; state: string; completed_at_ms: number | null }>();
  if (!pending) return;
  const entry = await journal.request(pending.request_id);
  if (!entry) throw new Error('independent deletion receipt missing');
  if (pending.state === 'completed') {
    if (pending.completed_at_ms === null || await remainingBillingTransactionRows(env, entry.billingAccountId) !== 0) {
      throw new Error('completed deletion requires recheck');
    }
    await journal.complete(entry, pending.completed_at_ms);
    await env.DB.prepare('UPDATE billing_retention_requests SET receipt_recorded=1 WHERE request_id=?')
      .bind(entry.requestId).run();
    return;
  }
  const fence = await env.DB.prepare('SELECT sequence,state FROM billing_retention_fences WHERE billing_account_id=?')
    .bind(entry.billingAccountId).first<{ sequence: number; state: string }>();
  if (!fence || fence.sequence !== entry.sequence || fence.state !== 'deleting') throw new Error('deletion fence mismatch');
  let used = 0;
  for (const [table, predicate] of billingRetentionEraseSteps) {
    for (;;) {
      if (used++ >= budget) return;
      const result = await env.DB.prepare(`DELETE FROM ${table} WHERE rowid IN
        (SELECT rowid FROM ${table} WHERE ${predicate} LIMIT 50)`).bind(entry.billingAccountId).run();
      if (result.meta.changes === 0) break;
    }
  }
  if (await remainingBillingTransactionRows(env, entry.billingAccountId) !== 0) throw new Error('billing deletion incomplete');
  await env.DB.batch([
    env.DB.prepare(`UPDATE billing_retention_requests SET state='completed',completed_at_ms=?
      WHERE request_id=? AND sequence=? AND state='deleting'`).bind(nowMs,entry.requestId,entry.sequence),
    env.DB.prepare(`UPDATE billing_retention_fences SET state='closed' WHERE billing_account_id=?
      AND sequence=? AND state='deleting'`).bind(entry.billingAccountId,entry.sequence),
  ]);
  await journal.complete(entry, nowMs);
  await env.DB.prepare('UPDATE billing_retention_requests SET receipt_recorded=1 WHERE request_id=?')
    .bind(entry.requestId).run();
}

/** External receipt alone cannot attest that a restored D1 is still empty. */
export async function billingDeletionCompleted(env: BillingRetentionEnv, entry: BillingRetentionEntry): Promise<boolean> {
  try { await requireBillingRetentionSnapshot(env); } catch { return false; }
  const row = await env.DB.prepare(`SELECT state,receipt_hash,sequence FROM billing_retention_requests WHERE request_id=?`)
    .bind(entry.requestId).first<{ state: string; receipt_hash: string; sequence: number }>();
  if (!row || row.state !== 'completed' || row.sequence !== entry.sequence || row.receipt_hash !== entry.receiptHash) return false;
  const fence=await billingRetentionFence(env,entry.billingAccountId);
  if(!fence || fence.sequence<entry.sequence || !['closed','active'].includes(fence.state)) return false;
  if(fence.state==='closed' && await remainingBillingTransactionRows(env, entry.billingAccountId) !== 0) return false;
  if(fence.state==='active' && fence.receipt_recorded!==1) return false;
  return await billingRetentionJournal(env).completed(entry) !== null;
}

export async function billingRetentionFence(env: BillingRetentionEnv, account:string):Promise<{
  sequence:number;state:string;cutoff_ms:number;receipt_recorded:number
}|null> {
  await requireBillingRetentionSnapshot(env);
  if(env.BILLING_TRANSACTION_RETENTION_REQUIRED!=='YES') return null;
  return env.DB.prepare(`SELECT f.sequence,f.state,f.cutoff_ms,r.receipt_recorded FROM billing_retention_fences f
    JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=?`)
    .bind(account).first();
}

export const retentionDigest = (value:string):Promise<string> => sha256Base64url(new TextEncoder().encode(value));

/** Called before replay reads as well as before insertion. A notification never
 * adds recovery authorization. Only the explicit fresh-proof recovery can. */
export async function billingRetentionTransactionSequence(env:BillingRetentionEnv,value:VerifiedBillingTransaction):Promise<number> {
  const fence=await billingRetentionFence(env,value.billingAccountId);
  if(!fence) return 0;
  if(fence.state!=='active') throw new ApiError(409,'billing_account_erased','Explicit verified purchase recovery is required.');
  const lineage=await retentionDigest(value.environment+':'+value.originalTransactionId);
  const transaction=await retentionDigest(value.environment+':'+value.transactionId);
  const allowed=await env.DB.prepare(`SELECT transaction_hash FROM billing_retention_recoveries
    WHERE billing_account_id=? AND sequence=? AND environment=? AND lineage_hash=?`)
    .bind(value.billingAccountId,fence.sequence,value.environment,lineage).all<{transaction_hash:string}>();
  if(!allowed.results.length || (!allowed.results.some(row=>row.transaction_hash===transaction)
    && (value.purchaseDateMs<=fence.cutoff_ms || value.signedDateMs<=fence.cutoff_ms))) {
    throw new ApiError(409,'billing_retention_old_transaction','Explicit verified purchase recovery is required.');
  }
  return fence.sequence;
}

export function billingRetentionWriteCondition(env:BillingRetentionEnv,account:string,sequence:number):{sql:string;bindings:(string|number)[]} {
  return env.BILLING_TRANSACTION_RETENTION_REQUIRED==='YES'
    ? {sql:`COALESCE((SELECT sequence FROM billing_retention_fences WHERE billing_account_id=?),0)=?
       AND NOT EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=? AND state<>'active')`,
      bindings:[account,sequence,account]}
    : {sql:'1',bindings:[]};
}
