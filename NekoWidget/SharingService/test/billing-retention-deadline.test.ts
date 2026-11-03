import { env } from 'cloudflare:workers';
import { expect,it } from 'vitest';
import type { Env } from '../src/env';
import type { VerifiedBillingTransaction } from '../src/billing-verifier-client';
import type { VerifiedSubscriptionStatus } from '../src/billing-apple-client';
import { ingestVerifiedAppleBillingNotification,runBillingSubscriptionReconciliation } from '../src/billing-authority';
import { requestBillingReconciliation } from '../src/billing-reconciliation-queue';
import { billingAccountRetentionCandidate,scheduleBillingTransactionRetention } from '../src/billing-retention-api';
import { runBillingTransactionDeletion,remainingBillingTransactionRows } from '../src/billing-retention-executor';

it('an unattended signed termination reaches the existing bounded authority queue before twelve-month deletion',async()=>{
  const e={...env,ENVIRONMENT:'local',BILLING_STORE_ENVIRONMENT:'Production',BILLING_TRANSACTION_RETENTION_REQUIRED:'YES'} as unknown as Env;
  await e.MEDIA!.put('__billing_retention/v1/control',JSON.stringify({version:1,deployment:'local',sequence:0}));
  const account=crypto.randomUUID(), initial=Date.now(), now=initial+2*86400000, end=initial-400*86400000, past=Math.floor(initial/1000);
  await e.DB.prepare('INSERT INTO billing_accounts(id) VALUES(?)').bind(account).run();
  await e.DB.prepare('UPDATE billing_runtime_gate SET generation=generation+1,subscription_reconciliation_enabled=1,updated_at=unixepoch()').run();
  const t:VerifiedBillingTransaction={transactionId:'555000000000001',originalTransactionId:'555000000000001',billingAccountId:account,
    productId:'jp.nekowidget.plus.monthly',subscriptionGroupId:'20999999',bundleId:'jp.nekowidget.app',environment:'Production',ownershipType:'PURCHASED',
    transactionReason:'PURCHASE',purchaseDateMs:end-86400000,originalPurchaseDateMs:end-86400000,expiresDateMs:end,signedDateMs:end+1000,
    revocationDateMs:null,revocationReason:null,isUpgraded:false};
  const status=(at:number):VerifiedSubscriptionStatus=>({requestedTransactionId:t.originalTransactionId,environment:'Production',bundleId:t.bundleId,
    fetchedAtMs:at,items:[{status:2,originalTransactionId:t.originalTransactionId,transaction:t,renewal:{originalTransactionId:t.originalTransactionId,
      billingAccountId:account,productId:t.productId,autoRenewProductId:null,autoRenewStatus:0,isInBillingRetryPeriod:false,
      gracePeriodExpiresDateMs:null,renewalDateMs:null,signedDateMs:end+1000,environment:'Production'}}]});
  await ingestVerifiedAppleBillingNotification(e,{notificationUUID:crypto.randomUUID(),notificationType:'EXPIRED',subtype:null,
    signedDateMs:end+1000,environment:'Production',bundleId:t.bundleId,status:2,relevant:true,transaction:t,renewal:null},'E'.repeat(43));
  await requestBillingReconciliation(e,t.originalTransactionId,past,'Production');
  await runBillingSubscriptionReconciliation(e,async()=>status(past*1000),past,past);
  expect(await e.DB.prepare('SELECT * FROM billing_reconciliation_jobs WHERE original_transaction_id=?').bind(t.originalTransactionId).first()).toBeNull();
  expect(await billingAccountRetentionCandidate(e,account,now)).toBeNull();
  await scheduleBillingTransactionRetention(e,now);
  const job=await e.DB.prepare('SELECT attempts,not_before,request_generation FROM billing_reconciliation_jobs WHERE original_transaction_id=?').bind(t.originalTransactionId).first();
  expect(job).not.toBeNull();
  expect(await e.DB.prepare('SELECT state FROM billing_retention_fences WHERE billing_account_id=?').bind(account).first()).toBeNull();
  // A repeated scan does not reset retry backoff or generation.
  await e.DB.prepare('UPDATE billing_reconciliation_jobs SET attempts=2,not_before=? WHERE original_transaction_id=?').bind(Math.floor(now/1000)+60,t.originalTransactionId).run();
  await billingAccountRetentionCandidate(e,account,now,true);
  expect(await e.DB.prepare('SELECT attempts,not_before FROM billing_reconciliation_jobs WHERE original_transaction_id=?').bind(t.originalTransactionId).first())
    .toEqual({attempts:2,not_before:Math.floor(now/1000)+60});
  const refreshed=Math.floor(now/1000)+61;
  await runBillingSubscriptionReconciliation(e,async()=>status(refreshed*1000),refreshed,refreshed);
  expect(await billingAccountRetentionCandidate(e,account,refreshed*1000)).not.toBeNull();
  await e.DB.prepare('UPDATE billing_retention_scan SET last_account_rowid=0').run();
  await scheduleBillingTransactionRetention(e,refreshed*1000);
  expect((await e.DB.prepare('SELECT reason,state FROM billing_retention_requests WHERE billing_account_id=?').bind(account).first()))
    .toEqual({reason:'subscription-ended',state:'deleting'});
  await runBillingTransactionDeletion(e,refreshed*1000+1);
  expect(await remainingBillingTransactionRows(e,account)).toBe(0);
  expect((await e.DB.prepare('SELECT state FROM billing_retention_requests WHERE billing_account_id=?').bind(account).first())).toEqual({state:'completed'});
});
