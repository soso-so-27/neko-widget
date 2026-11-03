import type { Env } from './env';
import { authenticateBillingSignedRequest, consumeBillingNonce } from './billing-auth';
import { base64urlDecode, randomBase64url } from './encoding';
import { ApiError, jsonResponse } from './errors';
import { exactKeys, protocolVersion, uuidField, binaryField } from './validation';
import { parseJsonBody, readBody, enforceRateLimit, transientNetworkKey } from './http';
import { billingRetentionJournal, requireBillingRetentionSnapshot } from './billing-retention-journal';
import { billingDeletionCompleted, reconcileBillingRetentionJournal, retentionDigest } from './billing-retention-executor';
import { accountRetentionDeadline, type RetentionLineageFact } from './billing-retention-policy';

const disabled=()=>new ApiError(503,'billing_retention_unavailable','Billing deletion is temporarily unavailable.');

export async function requestBillingTransactionDeletion(request:Request,env:Env):Promise<Response> {
  if(env.BILLING_TRANSACTION_RETENTION_REQUIRED!=='YES') throw disabled();
  await requireBillingRetentionSnapshot(env);
  await enforceRateLimit(env,env.BILLING_RATE_LIMITER,transientNetworkKey(request,'billing-deletion'));
  const body=await readBody(request,2048);
  const account=await authenticateBillingSignedRequest(request,env,body);
  const value=parseJsonBody(request,body); exactKeys(value,['protocolVersion','clientRequestId','receipt']); protocolVersion(value);
  const requestId=uuidField(value,'clientRequestId'), receipt=binaryField(value,'receipt',32);
  await consumeBillingNonce(env,account);
  const now=Date.now(), journal=billingRetentionJournal(env), control=await journal.control();
  const pending=await env.DB.prepare(`SELECT r.request_id FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence
    WHERE f.billing_account_id=? AND f.state='deleting'`).bind(account.billingAccountId).first<{request_id:string}>();
  if(pending && pending.request_id!==requestId) throw new ApiError(409,'billing_deletion_in_progress','Billing deletion is in progress.');
  await journal.append({requestId,billingAccountId:account.billingAccountId,
    receiptHash:await retentionDigest(receipt),reason:'account-deletion',requestedAtMs:now,endedAtMs:null,
    cutoffMs:now,factsHash:await retentionDigest('account-deletion:'+account.billingAccountId+':'+requestId),expectedRevision:0},control.sequence);
  await reconcileBillingRetentionJournal(env);
  return jsonResponse({protocolVersion:1,requestId,scope:'apple-transaction-records',state:'processing',subscriptionCancelled:false},202);
}

export async function billingTransactionDeletionStatus(request:Request,env:Env,requestId:string):Promise<Response> {
  if(env.BILLING_TRANSACTION_RETENTION_REQUIRED!=='YES') throw disabled();
  const bearer=request.headers.get('Authorization')?.match(/^Bearer ([A-Za-z0-9_-]{43})$/u)?.[1];
  if(!bearer || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(requestId)) {
    throw new ApiError(401,'invalid_deletion_receipt','Deletion receipt is invalid.');
  }
  try { base64urlDecode(bearer,32); } catch { throw new ApiError(401,'invalid_deletion_receipt','Deletion receipt is invalid.'); }
  const entry=await billingRetentionJournal(env).request(requestId);
  if(!entry || entry.receiptHash!==await retentionDigest(bearer)) throw new ApiError(401,'invalid_deletion_receipt','Deletion receipt is invalid.');
  return jsonResponse({protocolVersion:1,requestId,scope:'apple-transaction-records',
    state:await billingDeletionCompleted(env,entry)?'completed':'processing',subscriptionCancelled:false});
}

/** Signed termination + fresh authority for every lineage, across both stores. */
export async function billingAccountRetentionCandidate(env:Env,account:string,now:number,queueStale=false):Promise<{
  deadline:number;endedAt:number;revision:number;factsHash:string
}|null> {
  const rows=await env.DB.prepare(`SELECT l.environment,l.original_transaction_id,
    CASE WHEN EXISTS(SELECT 1 FROM billing_account_recovery_requests recovered
      WHERE recovered.billing_account_id=l.billing_account_id AND recovered.recovered_at*1000>=c.source_fetched_at_ms)
      THEN 'unconfirmed' ELSE c.materialized_status END materialized_status,c.authority_stale_at_ms,
    (SELECT MAX(e.signed_date_ms) FROM billing_transaction_events e WHERE e.environment=l.environment AND e.original_transaction_id=l.original_transaction_id) latest_signed,
    (SELECT MAX(n.signed_date_ms) FROM billing_apple_notification_events n WHERE n.environment=l.environment AND n.original_transaction_id=l.original_transaction_id
      AND n.transaction_id=c.transaction_id AND ((n.notification_type='EXPIRED' AND n.apple_status=2 AND c.materialized_status='expired')
        OR (n.notification_type IN('REVOKE','REFUND') AND n.apple_status=5 AND c.materialized_status='revoked'))) end_signed,
    CASE WHEN c.materialized_status='expired' THEN c.expires_date_ms WHEN c.materialized_status='revoked' THEN c.revocation_date_ms END ended_at,
    COALESCE(r.revision,0) revision
    FROM billing_transaction_lineages l LEFT JOIN billing_effective_entitlement_current c ON c.environment=l.environment AND c.original_transaction_id=l.original_transaction_id
    LEFT JOIN billing_retention_account_revisions r ON r.billing_account_id=l.billing_account_id
    WHERE l.billing_account_id=? ORDER BY l.environment,l.original_transaction_id LIMIT 101`).bind(account)
    .all<{environment:'Production'|'Sandbox';original_transaction_id:string;materialized_status:RetentionLineageFact['currentStatus']|null;
      authority_stale_at_ms:number|null;latest_signed:number|null;end_signed:number|null;ended_at:number|null;revision:number}>();
  if(rows.results.length>100) return null;
  const facts=rows.results.map(r=>({environment:r.environment,originalTransactionId:r.original_transaction_id,
    terminationAtMs:r.ended_at,terminationSignedAtMs:r.end_signed,latestSignedAtMs:r.latest_signed??Number.MAX_SAFE_INTEGER,
    currentStatus:r.materialized_status??'unconfirmed',authorityFreshUntilMs:r.authority_stale_at_ms??0}));
  const deadline=accountRetentionDeadline(facts,now);
  if(deadline===null || deadline>now) {
    // This relaxed freshness view can only enqueue a recheck, never authorize deletion.
    const recheckDue=accountRetentionDeadline(facts.map(f=>({...f,authorityFreshUntilMs:now+1})),now);
    if(queueStale && recheckDue!==null && recheckDue<=now) {
      const stale=facts.filter(f=>f.authorityFreshUntilMs<=now);
      if(stale.length) await env.DB.batch(stale.map(f=>env.DB.prepare(`INSERT OR IGNORE INTO billing_reconciliation_jobs
        (environment,original_transaction_id,requested_at,not_before,request_generation)
        SELECT ?,?,?,?,COALESCE((SELECT request_generation+1 FROM billing_effective_entitlement_current
          WHERE environment=? AND original_transaction_id=?),1)
        WHERE NOT EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=? AND state<>'active')`)
        .bind(f.environment,f.originalTransactionId,Math.floor(now/1000),Math.floor(now/1000),f.environment,f.originalTransactionId,account)));
    }
    return null;
  }
  return {deadline,endedAt:Math.max(...facts.map(f=>f.terminationAtMs!)),revision:rows.results[0]!.revision,
    factsHash:await retentionDigest(JSON.stringify(facts))};
}

/** A committed fresh authority is consumed immediately, independently of the
 * account scanner's next turn. Large populations cannot repeatedly age out the
 * same recheck before the cursor returns. */
export async function scheduleBillingAccountRetention(env:Env,account:string,now=Date.now(),queueStale=false):Promise<void> {
  if(env.BILLING_TRANSACTION_RETENTION_REQUIRED!=='YES') return;
  await requireBillingRetentionSnapshot(env);
    const control=await billingRetentionJournal(env).control();
    const fence=await env.DB.prepare('SELECT state FROM billing_retention_fences WHERE billing_account_id=?').bind(account).first<{state:string}>();
    if(!fence || fence.state==='active') {
      const candidate=await billingAccountRetentionCandidate(env,account,now,queueStale);
      if(candidate) {
        await billingRetentionJournal(env).append({requestId:crypto.randomUUID(),billingAccountId:account,
          receiptHash:await retentionDigest(randomBase64url(32)),reason:'subscription-ended',requestedAtMs:now,
          endedAtMs:candidate.endedAt,cutoffMs:now,factsHash:candidate.factsHash,expectedRevision:candidate.revision},control.sequence);
        await reconcileBillingRetentionJournal(env);
      }
    }

}

export async function scheduleBillingTransactionRetention(env:Env,now=Date.now()):Promise<void> {
  if(env.BILLING_TRANSACTION_RETENTION_REQUIRED!=='YES') return;
  await requireBillingRetentionSnapshot(env);
  const cursor=await env.DB.prepare('SELECT last_account_rowid FROM billing_retention_scan WHERE singleton=1').first<{last_account_rowid:number}>();
  if(!cursor) throw disabled();
  const rows=await env.DB.prepare(`SELECT rowid,id FROM billing_accounts WHERE rowid>? ORDER BY rowid LIMIT 4`)
    .bind(cursor.last_account_rowid).all<{rowid:number;id:string}>();
  for(const row of rows.results) {
    await scheduleBillingAccountRetention(env,row.id,now,true);
    await env.DB.prepare('UPDATE billing_retention_scan SET last_account_rowid=? WHERE singleton=1').bind(row.rowid).run();
  }
  if(!rows.results.length) await env.DB.prepare('UPDATE billing_retention_scan SET last_account_rowid=0 WHERE singleton=1').run();
}
