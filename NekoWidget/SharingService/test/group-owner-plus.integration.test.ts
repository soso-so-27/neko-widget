import { describe,expect,it } from 'vitest';
import { randomBase64url,sha256Base64url } from '../src/encoding';
import { billingSignedRequestTranscript } from '../src/billing-protocol';
import { ingestVerifiedAppleBillingNotification,reconcileBillingTransactionNow } from '../src/billing-authority';
import { requestBillingReconciliation } from '../src/billing-reconciliation-queue';
import type { VerifiedSubscriptionStatus } from '../src/billing-apple-client';
import type { VerifiedBillingTransaction } from '../src/billing-verifier-client';
import { groupDeliveryPolicies,groupDeliveryPolicyStatements,GROUP_TRIAL_SECONDS } from '../src/group-owner-plus';
import { effectiveBillingEntitlement } from '../src/billing-entitlement';
import { apply,call,create,db,invitation,key,ok,person,send,sign,signed,testEnv,transition,type Person } from './group-fixture';

const settings={...testEnv,BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'YES',BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED:'YES',
  BILLING_STORE_ENVIRONMENT:'Sandbox',ENVIRONMENT:'local',BILLING_SANDBOX_OWNER_ONLY_REQUIRED:'NO'};
async function gates(effective=1) {
  await db.prepare(`UPDATE billing_runtime_gate SET generation=generation+1,effective_entitlement_enabled=?,
    subscription_reconciliation_enabled=1,updated_at=unixepoch() WHERE singleton=1`).bind(effective).run();
}
async function billing() {
  const id=crypto.randomUUID(),billingKey=await key(),keyId=randomBase64url(16);
  await db.batch([db.prepare('INSERT INTO billing_accounts(id) VALUES (?)').bind(id),
    db.prepare("INSERT INTO billing_account_keys(id,billing_account_id,signing_public_key,state) VALUES (?,?,?,'active')").bind(keyId,id,billingKey.publicKey)]);
  return {id,keyId,billingKey};
}
async function connection(p:Person,b:Awaited<ReturnType<typeof billing>>,operationId=crypto.randomUUID(),nonce=randomBase64url(16)) {
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
async function authority(b:Awaited<ReturnType<typeof billing>>,ownershipType:'PURCHASED'|'FAMILY_SHARED'='PURCHASED',observedAt=Date.now()) {
  await gates();
  const now=observedAt,id=String(++sequence);
  const transaction:VerifiedBillingTransaction={transactionId:id,originalTransactionId:id,billingAccountId:b.id,
    productId:'jp.nekowidget.plus.monthly',subscriptionGroupId:'20999999',bundleId:'jp.nekowidget.app',environment:'Sandbox',ownershipType,
    transactionReason:'PURCHASE',purchaseDateMs:now-1000,originalPurchaseDateMs:now-1000,expiresDateMs:now+86400000,
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
    await reconcileBillingTransactionNow(settings,b.id,id,async()=>value);
    const current=await db.prepare('SELECT apple_status,transaction_id FROM billing_effective_entitlement_current WHERE original_transaction_id=?').bind(id).first();
    const job=await db.prepare('SELECT * FROM billing_reconciliation_jobs WHERE original_transaction_id=?').bind(id).first();
    expect({current,jobError:job?.last_error_code}).toMatchObject({current:{apple_status:status,transaction_id:t.transactionId}});
  }
  await refresh({},1,now);return {transaction,refresh};
}
async function age(windowId:string,seconds=GROUP_TRIAL_SECONDS) {
  await db.prepare('UPDATE group_windows SET created_at=unixepoch()-? WHERE space_id=?').bind(seconds,windowId).run();
}
describe('group creator Plus, independent from recipient membership and old sponsorship',()=>{
  it('reports trial, pauses exactly at 14 days, keeps roster/keys and allows member operations',async()=>{
    const owner=await person(),guest=await person();let w=await create(owner);
    let policy=ok(await call(owner,`/v3/group-windows/${w.windowId}`)).window;
    expect(policy).toMatchObject({deliveryStatus:'active',deliveryReason:'trial',ownerParticipantId:w.roster.members[0]!.participantId});
    await age(w.windowId,GROUP_TRIAL_SECONDS-30);
    await db.batch(groupDeliveryPolicyStatements(settings,w.windowId));
    await age(w.windowId);
    await expect(db.batch(groupDeliveryPolicyStatements(settings,w.windowId))).rejects.toThrow('group_window_paused');
    policy=ok(await call(owner,`/v3/group-windows/${w.windowId}`)).window;
    expect(policy).toMatchObject({deliveryStatus:'paused',deliveryReason:'owner_plus_required'});
    expect(ok(await call(owner,'/v3/group-windows/list',{after:null,limit:50})).items[0]).toMatchObject({deliveryStatus:'paused',deliveryReason:'owner_plus_required',trialEndsAt:policy.trialEndsAt,ownerParticipantId:policy.ownerParticipantId});
    const invite=await invitation(owner,w),join=await apply(guest,w,invite);ok(join.response,201);
    const approved=await transition(owner,w,'admit',join.id,[...w.roster.members,join.member]);ok(approved.response);w=approved.next;
    expect(ok(await call(guest,`/v3/group-windows/${w.windowId}/keys/2`)).envelopeForThisDevice.deviceId).toBe(guest.deviceId);
    ok((await transition(owner,w,'remove',join.member.participantId,[w.roster.members[0]!])).response);
    expect((await db.prepare('SELECT COUNT(*) AS n FROM group_rosters WHERE space_id=?').bind(w.windowId).first<{n:number}>())?.n).toBe(3);
  });
  it('binds only with both signatures, is idempotent, rejects reused billing nonce and another person',async()=>{
    await gates();const owner=await person(),other=await person(),b=await billing(),c=await connection(owner,b);
    expect((await send(await signed(owner,'/v3/group-windows/billing-connection',c.body),settings)).status).toBe(401);
    const copied=await signed(other,'/v3/group-windows/billing-connection',c.body),copiedHeaders=new Headers(copied.headers);
    c.request.headers.forEach((value,name)=>{if(name.startsWith('neko-billing-'))copiedHeaders.set(name,value);});
    expect((await send(new Request(copied,{headers:copiedHeaders}),settings)).status).toBe(401);
    ok(await send(c.request,settings));
    ok(await send((await connection(owner,b,c.body.operationId)).request,settings));
    const reused=await connection(owner,b,crypto.randomUUID(),c.nonce);
    expect((await send(reused.request,settings)).data.error.code).toBe('replayed_billing_request');
    expect((await send((await connection(other,b)).request,settings)).data.error.code).toBe('billing_connection_conflict');
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_connections WHERE billing_account_id=?').bind(b.id).first<{n:number}>())?.n).toBe(1);
  });
  it('resumes from current verified owner Plus, pauses on revocation and resumes on renewal without a cron',async()=>{
    const owner=await person(),w=await create(owner),b=await billing();const a=await authority(b);
    ok(await send((await connection(owner,b)).request,settings));await age(w.windowId);
    expect((await groupDeliveryPolicies(settings,[w.windowId])).get(w.windowId)?.deliveryReason).toBe('owner_plus');
    await db.batch(groupDeliveryPolicyStatements(settings,w.windowId));
    await a.refresh({revocationDateMs:Date.now(),revocationReason:1},5,Date.now()+10);
    await expect(db.batch(groupDeliveryPolicyStatements(settings,w.windowId))).rejects.toThrow('group_window_paused');
    await a.refresh({transactionId:String(++sequence),transactionReason:'RENEWAL',purchaseDateMs:Date.now()},1,Date.now()+20);
    await db.batch(groupDeliveryPolicyStatements(settings,w.windowId));
    expect((await groupDeliveryPolicies(settings,[w.windowId])).get(w.windowId)?.deliveryStatus).toBe('active');
  });
  it('a paying guest cannot resume the unpaid creator’s window',async()=>{
    const owner=await person(),guest=await person(),w=await create(owner),b=await billing();await authority(b);
    ok(await send((await connection(guest,b)).request,settings));await age(w.windowId);
    expect((await groupDeliveryPolicies(settings,[w.windowId])).get(w.windowId)?.deliveryStatus).toBe('paused');
  });
  it('accepts verified FAMILY_SHARED facts only for group policy; old APIs retain their policy',async()=>{
    const owner=await person(),w=await create(owner),b=await billing();await authority(b,'FAMILY_SHARED');
    ok(await send((await connection(owner,b)).request,settings));await age(w.windowId);
    expect((await groupDeliveryPolicies(settings,[w.windowId])).get(w.windowId)?.deliveryReason).toBe('owner_plus');
    expect((await effectiveBillingEntitlement(settings,b.id)).grantsPlus).toBe(false);
  });
  it('fails paid access closed on upper/lower gate, stale authority and environment mismatch',async()=>{
    const owner=await person(),w=await create(owner),b=await billing();await authority(b);
    ok(await send((await connection(owner,b)).request,settings));await age(w.windowId);
    const reason=async(e= settings)=>(await groupDeliveryPolicies(e,[w.windowId])).get(w.windowId)?.deliveryStatus;
    expect(await reason({...settings,BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'NO'})).toBe('paused');
    expect(await reason({...settings,BILLING_STORE_ENVIRONMENT:'Production'})).toBe('paused');
    expect(await reason({...settings,ENVIRONMENT:'production'})).toBe('paused');
    const planned=groupDeliveryPolicyStatements(settings,w.windowId);
    const before=await db.prepare('SELECT updated_at FROM group_windows WHERE space_id=?').bind(w.windowId).first<{updated_at:number}>();
    await gates(0);expect(await reason()).toBe('paused');
    await expect(db.batch([db.prepare('UPDATE group_windows SET updated_at=updated_at+1 WHERE space_id=?').bind(w.windowId),...planned]))
      .rejects.toThrow('group_window_paused');
    expect((await db.prepare('SELECT updated_at FROM group_windows WHERE space_id=?').bind(w.windowId).first<{updated_at:number}>())?.updated_at).toBe(before?.updated_at);
    await gates();
    // Use a valid, already old signed observation through the same authority seam.
    const staleOwner=await person(),staleWindow=await create(staleOwner),stale=await billing();
    await authority(stale,'PURCHASED',Date.now()-37*3600000);
    ok(await send((await connection(staleOwner,stale)).request,settings));await age(staleWindow.windowId);
    expect((await groupDeliveryPolicies(settings,[staleWindow.windowId])).get(staleWindow.windowId)?.deliveryStatus).toBe('paused');
  });
  it('has five owned windows during the creation trial; expiry blocks new creation and Plus restores it',async()=>{
    const owner=await person(),w=await create(owner);await age(w.windowId);
    // The SQL check is after insertion but in the same transaction: rollback
    // must remove all new membership, keys, metadata and the attempted window.
    const path='/v3/group-windows',before=await db.prepare('SELECT COUNT(*) n FROM group_windows WHERE owner_person_id=?').bind(owner.id).first<{n:number}>();
    await create(owner,403,'owner_plus_required');
    expect((await db.prepare('SELECT COUNT(*) n FROM group_windows WHERE owner_person_id=?').bind(owner.id).first<{n:number}>())?.n).toBe(before?.n);
    const b=await billing();await authority(b);ok(await send((await connection(owner,b)).request,settings));
    // fixture's generic call uses the default closed billing upper gate. Send
    // the same signed creation under the explicit local test billing setting.
    const {member,packet}=await import('./group-fixture');const windowId=randomBase64url(16);
    const roster={...w.roster,windowId,members:[await member(owner,windowId,'owner')]};
    const {hash,...wire}=await packet(owner,roster);
    ok(await send(await signed(owner,path,{operationId:crypto.randomUUID(),...wire}),settings),201);
  });
});
