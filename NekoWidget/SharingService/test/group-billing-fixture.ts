import {expect} from 'vitest';
import {randomBase64url,sha256Base64url} from '../src/encoding';
import {billingSignedRequestTranscript} from '../src/billing-protocol';
import {ingestVerifiedAppleBillingNotification,reconcileBillingTransactionNow,runBillingSubscriptionReconciliation} from '../src/billing-authority';
import {requestBillingReconciliation} from '../src/billing-reconciliation-queue';
import type {VerifiedSubscriptionStatus} from '../src/billing-apple-client';
import type {VerifiedBillingTransaction} from '../src/billing-verifier-client';
import {db,key,ok,person,send,sign,signed,testEnv,type Person} from './group-fixture';
export const settings={...testEnv,BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'YES',BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED:'YES',
  BILLING_STORE_ENVIRONMENT:'Sandbox',ENVIRONMENT:'local',BILLING_SANDBOX_OWNER_ONLY_REQUIRED:'NO'};
export async function gates(effective=1) {
  await db.prepare(`UPDATE billing_runtime_gate SET generation=generation+1,effective_entitlement_enabled=?,
    subscription_reconciliation_enabled=1,updated_at=unixepoch() WHERE singleton=1`).bind(effective).run();
}
export async function billing() {
  const id=crypto.randomUUID(),billingKey=await key(),keyId=randomBase64url(16);
  await db.batch([db.prepare('INSERT INTO billing_accounts(id) VALUES (?)').bind(id),
    db.prepare("INSERT INTO billing_account_keys(id,billing_account_id,signing_public_key,state) VALUES (?,?,?,'active')").bind(keyId,id,billingKey.publicKey)]);
  return {id,keyId,billingKey};
}
export async function connection(p:Person,b:Awaited<ReturnType<typeof billing>>,operationId=crypto.randomUUID(),nonce=randomBase64url(16)) {
  const path='/v3/group-windows/billing-connection',body={operationId,billingAccountId:b.id,personId:p.id,deviceId:p.deviceId},request=await signed(p,path,body);
  const timestamp=Math.floor(Date.now()/1000),headers=new Headers(request.headers);
  for(const [k,v] of Object.entries({'neko-billing-protocol-version':'1','neko-billing-account-id':b.id,'neko-billing-key-id':b.keyId,
    'neko-billing-timestamp':String(timestamp),'neko-billing-nonce':nonce,'neko-billing-signature':await sign(b.billingKey.privateKey,
      billingSignedRequestTranscript({billingAccountId:b.id,billingKeyId:b.keyId,timestamp,nonce,method:'POST',pathname:path,
        bodySHA256:await sha256Base64url(new TextEncoder().encode(JSON.stringify(body)))}))}))headers.set(k,v);
  return {request:new Request(request,{headers}),body,nonce};
}
let sequence=220000000000000;
// Exercise the existing verified-authority persistence/reconciliation boundary.
// Apple JWS verification and real Family Sharing are NOT simulated as success.
export async function authority(b:Awaited<ReturnType<typeof billing>>,ownershipType:'PURCHASED'|'FAMILY_SHARED'='PURCHASED',observedAt=Date.now()) {
  await gates();
  const now=observedAt,id=String(++sequence);
  const transaction:VerifiedBillingTransaction={transactionId:id,originalTransactionId:id,billingAccountId:b.id,
    productId:'jp.nekowidget.plus.monthly',subscriptionGroupId:'20999999',bundleId:'jp.nekowidget.app',environment:'Sandbox',ownershipType,
    transactionReason:'PURCHASE',purchaseDateMs:now-1000,originalPurchaseDateMs:now-1000,expiresDateMs:Date.now()+14*86400000,
    signedDateMs:now,revocationDateMs:null,revocationReason:null,isUpgraded:false};
  await ingestVerifiedAppleBillingNotification(settings,{notificationUUID:crypto.randomUUID(),notificationType:'DID_RENEW',subtype:null,
    signedDateMs:now,environment:'Sandbox',bundleId:transaction.bundleId,status:1,relevant:true,transaction,renewal:null},randomBase64url(32));
  async function refresh(overrides:Partial<VerifiedBillingTransaction>={},status:1|2|3|4|5=1,fetchedAt=Date.now()) {
    const t={...transaction,...overrides,signedDateMs:fetchedAt};
    const value:VerifiedSubscriptionStatus={requestedTransactionId:id,environment:'Sandbox',bundleId:transaction.bundleId,fetchedAtMs:fetchedAt,items:[{
      status,originalTransactionId:id,transaction:t,renewal:{originalTransactionId:id,billingAccountId:b.id,productId:t.productId,
        autoRenewProductId:t.productId,autoRenewStatus:status===5?0:1,isInBillingRetryPeriod:status===3||status===4,
        gracePeriodExpiresDateMs:status===4?fetchedAt+300000:null,renewalDateMs:t.expiresDateMs,signedDateMs:fetchedAt,environment:'Sandbox'}}]};
    await requestBillingReconciliation(settings,id);
    if(fetchedAt<Date.now()-36*3600000) {
      // Model a successfully verified authority which has since aged out. An
      // old transaction fetched TODAY would correctly be a fresh verification.
      // Keep the actual D1 lease/fences; only the supported completion clock is
      // set to the earlier verification time in this isolated local fixture.
      await runBillingSubscriptionReconciliation(settings,async()=>value,Math.floor(Date.now()/1000),Math.floor(fetchedAt/1000));
    } else await reconcileBillingTransactionNow(settings,b.id,id,async()=>value);
    const current=await db.prepare('SELECT apple_status,transaction_id FROM billing_effective_entitlement_current WHERE original_transaction_id=?').bind(id).first();
    const job=await db.prepare('SELECT * FROM billing_reconciliation_jobs WHERE original_transaction_id=?').bind(id).first();
    expect({current,jobError:job?.last_error_code}).toMatchObject({current:{apple_status:status,transaction_id:t.transactionId}});
  }
  await refresh({},1,now);return {transaction,refresh};
}

export async function plusOwner(ownershipType:'PURCHASED'|'FAMILY_SHARED'='PURCHASED') {
  const p=await person(),account=await billing(),verified=await authority(account,ownershipType);
  ok(await send((await connection(p,account)).request,settings));
  return {...p,account,verified};
}
export async function pauseOwner(owner:Awaited<ReturnType<typeof plusOwner>>) {
  await owner.verified.refresh({revocationDateMs:Date.now(),revocationReason:1},5);
}
