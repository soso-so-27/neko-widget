import {describe,expect,it} from 'vitest';
import {base64urlDecode,randomBase64url,sha256Base64url} from '../src/encoding';
import {billingAccountRecoveryTranscript} from '../src/billing-protocol';
import {recoverBillingAccount} from '../src/billing-recovery';
import {groupDeliveryPolicies} from '../src/group-owner-plus';
import {groupFields} from '../src/group-protocol';
import {connection,plusOwner,settings,type billing} from './group-billing-fixture';
import {apply,call,create,db,invitation,key,ok,person,send,sign,signed,transition} from './group-fixture';
import type {VerifiedBillingTransaction} from '../src/billing-verifier-client';

async function recovery(b:Awaited<ReturnType<typeof billing>>,transaction:VerifiedBillingTransaction,
  appHash=randomBase64url(32),denyProof=false) {
  const next=await key(),clientRequestId=crypto.randomUUID(),deviceVerificationId=crypto.randomUUID();
  const signedAppTransactionInfo='a.b.c',signedTransactionInfo='d.e.f',text=new TextEncoder();
  const input={clientRequestId,billingAccountId:b.id,signingPublicKey:next.publicKey,deviceVerificationId,
    expectedAppTransactionId:'synthetic-device-bound-app',expectedTransactionId:transaction.transactionId,
    expectedOriginalTransactionId:transaction.originalTransactionId,
    signedAppTransactionHash:await sha256Base64url(text.encode(signedAppTransactionInfo)),
    signedTransactionHash:await sha256Base64url(text.encode(signedTransactionInfo))};
  const body={protocolVersion:1,...input,signedAppTransactionInfo,signedTransactionInfo,
    recoverySignature:await sign(next.privateKey,billingAccountRecoveryTranscript(input))};
  const {signedAppTransactionHash:_,signedTransactionHash:__,...wire}=body;
  await db.prepare(`UPDATE billing_runtime_gate SET generation=generation+1,account_recovery_enabled=1,
    updated_at=unixepoch() WHERE singleton=1`).run();
  const request=()=>new Request('https://group.invalid/v1/billing/accounts/recover',{
    method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(wire)});
  const response=await recoverBillingAccount(request(),settings,async supplied=>{
    expect(supplied.deviceVerificationId).toBe(deviceVerificationId);
    expect(supplied.billingAccountId).toBe(b.id);
    if(denyProof)throw new Error('synthetic AppTransaction device proof rejected');
    return {appTransactionIdHash:appHash,transaction};
  },async()=>({requestedTransactionId:transaction.originalTransactionId,environment:transaction.environment,
    bundleId:transaction.bundleId,fetchedAtMs:Date.now(),items:[{status:1,
      originalTransactionId:transaction.originalTransactionId,transaction,
      renewal:{originalTransactionId:transaction.originalTransactionId,billingAccountId:b.id,
        productId:transaction.productId,autoRenewProductId:transaction.productId,autoRenewStatus:1,
        isInBillingRetryPeriod:false,gracePeriodExpiresDateMs:null,renewalDateMs:transaction.expiresDateMs,
        signedDateMs:Date.now(),environment:transaction.environment}}]}));
  const result=await response.json() as {billingKeyId:string};
  expect(response.status).toBe(200);
  return {account:{...b,keyId:result.billingKeyId,billingKey:next},appHash,request};
}

describe('group billing connection after device-bound account recovery',()=>{
  it('moves only the recovered subscription connection while preserving old window ownership',async()=>{
    const owner=await plusOwner(),window=await create(owner),nextPerson=await person();
    const before=await db.prepare('SELECT * FROM group_rosters WHERE space_id=?').bind(window.windowId).all();
    const recovered=await recovery(owner.account,owner.verified.transaction);
    ok(await send((await connection(nextPerson,recovered.account)).request,settings));
    expect(await db.prepare('SELECT person_id FROM group_billing_connections WHERE billing_account_id=?')
      .bind(owner.account.id).first()).toEqual({person_id:nextPerson.id});
    expect(await db.prepare('SELECT owner_person_id FROM group_windows WHERE space_id=?')
      .bind(window.windowId).first()).toEqual({owner_person_id:owner.id});
    expect((await db.prepare('SELECT * FROM group_rosters WHERE space_id=?').bind(window.windowId).all()).results).toEqual(before.results);
    expect((await groupDeliveryPolicies(settings,[window.windowId])).get(window.windowId)?.deliveryStatus).toBe('paused');
    expect((await call(nextPerson,`/v3/group-windows/${window.windowId}`)).status).toBe(404);
    await create(nextPerson);
  });
  it('consumes the recovered key once, allows same-operation replay, and rejects old-key and cross-person reuse',async()=>{
    const owner=await plusOwner(),target=await person(),third=await person();
    const recovered=await recovery(owner.account,owner.verified.transaction);
    const first=await connection(target,recovered.account),reply=ok(await send(first.request,settings));
    expect(ok(await send((await connection(target,recovered.account,first.body.operationId)).request,settings))).toEqual(reply);
    expect((await send((await connection(third,recovered.account)).request,settings)).data.error.code).toBe('billing_connection_conflict');
    expect((await send((await connection(owner,owner.account)).request,settings)).status).toBe(401);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_recovery_uses WHERE billing_account_id=?').bind(owner.account.id).first())?.n).toBe(1);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_recovery_commands').first())?.n).toBe(0);
  });
  it('requires both signatures over the recovered account and exact new person/device',async()=>{
    const owner=await plusOwner(),target=await person(),other=await person();
    const recovered=await recovery(owner.account,owner.verified.transaction),c=await connection(target,recovered.account);
    expect((await send(await signed(target,'/v3/group-windows/billing-connection',c.body),settings)).status).toBe(401);
    const copied=await signed(other,'/v3/group-windows/billing-connection',c.body),headers=new Headers(copied.headers);
    c.request.headers.forEach((v,k)=>{if(k.startsWith('neko-billing-'))headers.set(k,v);});
    expect((await send(new Request(copied,{headers}),settings)).status).toBe(401);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_recovery_uses WHERE billing_account_id=?').bind(owner.account.id).first())?.n).toBe(0);
    ok(await send(c.request,settings));
  });
  it('does not grant a move from rejected AppTransaction proof or another Apple identity',async()=>{
    const owner=await plusOwner();
    await expect(recovery(owner.account,owner.verified.transaction,randomBase64url(32),true)).rejects.toThrow('device proof rejected');
    expect((await db.prepare('SELECT generation FROM billing_account_key_state WHERE billing_account_id=?').bind(owner.account.id).first())?.generation).toBe(0);
    const first=await recovery(owner.account,owner.verified.transaction);
    await expect(recovery(first.account,owner.verified.transaction,randomBase64url(32))).rejects.toMatchObject({code:'billing_recovery_conflict'});
    expect((await db.prepare('SELECT generation FROM billing_account_key_state WHERE billing_account_id=?').bind(owner.account.id).first())?.generation).toBe(1);
    expect((await db.prepare('SELECT person_id FROM group_billing_connections WHERE billing_account_id=?').bind(owner.account.id).first())?.person_id).toBe(owner.id);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_recovery_uses WHERE billing_account_id=?').bind(owner.account.id).first())?.n).toBe(0);
  });
  it('cannot replace a different account already connected to the target person',async()=>{
    const owner=await plusOwner(),other=await plusOwner(),recovered=await recovery(owner.account,owner.verified.transaction);
    expect((await send((await connection(other,recovered.account)).request,settings)).data.error.code).toBe('billing_connection_conflict');
    const rows=(await db.prepare('SELECT person_id,billing_account_id FROM group_billing_connections WHERE billing_account_id IN (?,?)').bind(owner.account.id,other.account.id).all()).results;
    expect(rows).toEqual(expect.arrayContaining([{person_id:owner.id,billing_account_id:owner.account.id},{person_id:other.id,billing_account_id:other.account.id}]));
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_recovery_uses WHERE billing_account_id=?').bind(owner.account.id).first())?.n).toBe(0);
  });
  it('rolls back the connection, consumption and billing nonce on interruption while keeping the group nonce claim',async()=>{
    const owner=await plusOwner(),target=await person(),recovered=await recovery(owner.account,owner.verified.transaction);
    const c=await connection(target,recovered.account);
    const failing=new Proxy(db,{get(db,property){
      if(property==='batch')return (statements:D1PreparedStatement[])=>db.batch([...statements,db.prepare("SELECT json('synthetic interruption')")]);
      const value=Reflect.get(db,property);return typeof value==='function'?value.bind(db):value;
    }});
    expect((await send(c.request,{...settings,DB:failing})).status).toBe(500);
    expect((await db.prepare('SELECT person_id FROM group_billing_connections WHERE billing_account_id=?').bind(owner.account.id).first())?.person_id).toBe(owner.id);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_recovery_uses WHERE billing_account_id=?').bind(owner.account.id).first())?.n).toBe(0);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_recovery_commands').first())?.n).toBe(0);
    expect(await db.prepare('SELECT 1 FROM billing_request_nonces WHERE billing_key_id=? AND nonce=?').bind(recovered.account.keyId,c.nonce).first()).toBeNull();
    expect(await db.prepare('SELECT 1 FROM group_request_nonces WHERE device_id=? AND nonce=?').bind(target.deviceId,c.request.headers.get('neko-nonce')).first()).not.toBeNull();
    ok(await send((await connection(target,recovered.account,c.body.operationId)).request,settings));
  });
  it('rejects a recovery-generation change between proof lookup and the atomic move',async()=>{
    const owner=await plusOwner(),target=await person(),first=await recovery(owner.account,owner.verified.transaction);
    let raced=false;
    const racing=new Proxy(db,{get(db,property){
      if(property==='batch')return async(statements:D1PreparedStatement[])=>{
        if(!raced){raced=true;await recovery(first.account,owner.verified.transaction,first.appHash);}
        return db.batch(statements);
      };
      const value=Reflect.get(db,property);return typeof value==='function'?value.bind(db):value;
    }});
    expect((await send((await connection(target,first.account)).request,{...settings,DB:racing})).data.error.code).toBe('billing_connection_conflict');
    expect(raced).toBe(true);
    expect((await db.prepare('SELECT person_id FROM group_billing_connections WHERE billing_account_id=?').bind(owner.account.id).first())?.person_id).toBe(owner.id);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_recovery_uses WHERE billing_account_id=?').bind(owner.account.id).first())?.n).toBe(0);
    expect((await db.prepare('SELECT generation FROM billing_account_key_state WHERE billing_account_id=?').bind(owner.account.id).first())?.generation).toBe(2);
  });
  it('admits only one of two new people using the same recovered key',async()=>{
    const owner=await plusOwner(),a=await person(),b=await person(),recovered=await recovery(owner.account,owner.verified.transaction);
    const requests=await Promise.all([connection(a,recovered.account),connection(b,recovered.account)]);
    const responses=await Promise.all(requests.map(c=>send(c.request,settings)));
    expect(responses.map(r=>r.status).sort()).toEqual([200,409]);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_recovery_uses WHERE billing_account_id=?').bind(owner.account.id).first())?.n).toBe(1);
    const winner=responses[0]!.status===200?a:b;
    expect((await db.prepare('SELECT person_id FROM group_billing_connections WHERE billing_account_id=?').bind(owner.account.id).first())?.person_id).toBe(winner.id);
    expect((await db.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  });
  it('keeps a delivered photo, cleanup deadline and encrypted bytes when its owner moves the billing connection',async()=>{
    const owner=await plusOwner(),guest=await person(),target=await person();let w=await create(owner);
    const invite=await invitation(owner,w),join=await apply(guest,w,invite);ok(join.response,201);
    const admitted=await transition(owner,w,'admit',join.id,[...w.roster.members,join.member]);ok(admitted.response);w=admitted.next;
    const bytes=crypto.getRandomValues(new Uint8Array(48)),hash=await sha256Base64url(bytes),clientMomentId=randomBase64url(16);
    const participantId=w.roster.members.find(m=>m.personId===owner.id)!.participantId;
    const aad=groupFields(['NW3.PHOTO',w.windowId,clientMomentId,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),participantId,owner.deviceId,'48']);
    const reserved=ok(await call(owner,`/v3/group-windows/${w.windowId}/moments/reserve`,{
      operationId:crypto.randomUUID(),clientMomentId,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,
      ciphertextSize:48,ciphertextSHA256:hash,kind:'photo',
      senderSignature:await sign(owner.signing.privateKey,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)]))}),201);
    const path=`/v3/group-windows/${w.windowId}/moments/${reserved.momentId}`;
    ok(await send(await signed(owner,`${path}/ciphertext`,bytes,randomBase64url(16),'PUT')));
    ok(await call(owner,`${path}/commit`,{operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,keyEpoch:w.roster.keyEpoch,ciphertextSHA256:hash}));
    const before=await db.prepare('SELECT * FROM group_moments WHERE id=?').bind(reserved.momentId).first();
    const deliveries=(await db.prepare('SELECT * FROM group_moment_deliveries WHERE moment_id=?').bind(reserved.momentId).all()).results;
    const recovered=await recovery(owner.account,owner.verified.transaction);
    ok(await send((await connection(target,recovered.account)).request,settings));
    expect(await db.prepare('SELECT * FROM group_moments WHERE id=?').bind(reserved.momentId).first()).toEqual(before);
    expect((await db.prepare('SELECT * FROM group_moment_deliveries WHERE moment_id=?').bind(reserved.momentId).all()).results).toEqual(deliveries);
    const object=await settings.MEDIA!.get(String(before!.object_key));
    expect(new Uint8Array(await object!.arrayBuffer())).toEqual(bytes);
    expect((await call(target,path)).status).toBe(404);
  });
  it('does not resurrect a consumed move after unlink; another valid recovery must advance the generation',async()=>{
    const owner=await plusOwner(),firstPerson=await person(),nextPerson=await person();
    const first=await recovery(owner.account,owner.verified.transaction);
    ok(await send((await connection(firstPerson,first.account)).request,settings));
    await db.prepare('DELETE FROM group_billing_connections WHERE person_id=?').bind(firstPerson.id).run();
    expect((await send((await connection(nextPerson,first.account)).request,settings)).data.error.code).toBe('billing_connection_conflict');
    const second=await recovery(first.account,owner.verified.transaction,first.appHash);
    ok(await send((await connection(nextPerson,second.account)).request,settings));
    expect((await db.prepare('SELECT generation FROM group_billing_recovery_uses WHERE billing_account_id=? ORDER BY generation').bind(owner.account.id).all()).results).toEqual([{generation:1},{generation:2}]);
  });
});
