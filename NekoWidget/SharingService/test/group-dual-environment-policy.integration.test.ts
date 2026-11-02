import {describe,expect,it} from 'vitest';
import type {Env} from '../src/env';
import {base64urlDecode,randomBase64url,sha256Base64url} from '../src/encoding';
import {groupFields} from '../src/group-protocol';
import {groupCreationPolicyStatements,groupDeliveryPolicies,groupDeliveryPolicyStatements} from '../src/group-owner-plus';
import {route} from '../src/index';
import {apply,create,db,invitation,ok,person,send,sign,signed,transition} from './group-fixture';
import {authority,billing,connection,gates,plusOwner,settings} from './group-billing-fixture';

const syntheticRateLimit:RateLimit={limit:async()=>({success:true})};
const dual:Env={...settings,ENVIRONMENT:'production',BILLING_STORE_ENVIRONMENT:'Production',BILLING_ACCEPT_SANDBOX_IN_PRODUCTION:'YES',
  CREATE_RATE_LIMITER:syntheticRateLimit,INVITE_RATE_LIMITER:syntheticRateLimit,MEMBER_RATE_LIMITER:syntheticRateLimit,
  BILLING_RATE_LIMITER:syntheticRateLimit};
const single:Env={...dual,BILLING_ACCEPT_SANDBOX_IN_PRODUCTION:'NO'};
async function policy(windowId:string,env:Env=dual){return (await groupDeliveryPolicies(env,[windowId])).get(windowId);}

describe('explicit Production and Sandbox group creation/delivery policy',()=>{
  it('creates a room and delivers synthetic encrypted bytes under Production with verified Sandbox Plus',async()=>{
    const owner=await person(),account=await billing();await authority(account);
    ok(await send((await connection(owner,account)).request,dual));
    let w=await create(owner,201,'owned_window_limit',dual);
    expect(await policy(w.windowId)).toMatchObject({deliveryStatus:'active',deliveryReason:'owner_plus'});
    const guest=await person(),invite=await invitation(owner,w),join=await apply(guest,w,invite);ok(join.response,201);
    const approved=await transition(owner,w,'admit',join.id,[...w.roster.members,join.member]);ok(approved.response);w=approved.next;
    const bytes=crypto.getRandomValues(new Uint8Array(48)),hash=await sha256Base64url(bytes),clientMomentId=randomBase64url(16);
    const participant=w.roster.members[0]!.participantId;
    const aad=groupFields(['NW3.PHOTO',w.windowId,clientMomentId,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),participant,owner.deviceId,String(bytes.length)]);
    const reserve=ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/moments/reserve`,{
      operationId:crypto.randomUUID(),clientMomentId,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,
      ciphertextSize:bytes.length,ciphertextSHA256:hash,kind:'photo',
      senderSignature:await sign(owner.signing.privateKey,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)])),
    }),dual),201);
    const path=`/v3/group-windows/${w.windowId}/moments/${reserve.momentId}`;
    ok(await send(await signed(owner,`${path}/ciphertext`,bytes,randomBase64url(16),'PUT'),dual));
    ok(await send(await signed(owner,`${path}/commit`,{operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,
      keyEpoch:w.roster.keyEpoch,ciphertextSHA256:hash}),dual));
    const delivered=await route(await signed(guest,`${path}/ciphertext`),dual);
    expect(delivered.status).toBe(200);expect(new Uint8Array(await delivered.arrayBuffer())).toEqual(bytes);
    const list=ok(await send(await signed(guest,'/v3/group-windows/list',{after:null,limit:50}),dual));
    expect(list.items[0]).toMatchObject({deliveryStatus:'active',deliveryReason:'owner_plus'});
    expect((await db.prepare('SELECT COUNT(*) n FROM group_creation_environment_checks').first())?.n).toBe(0);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_delivery_environment_checks').first())?.n).toBe(0);
  });

  it('keeps paid Production access after equal-ID Sandbox revocation and after dual acceptance turns OFF',async()=>{
    const owner=await person(),account=await billing();
    const paid=await authority(account,'PURCHASED',Date.now(),'Production');
    const sandbox=await authority(account,'PURCHASED',Date.now(),'Sandbox',paid.transaction.originalTransactionId);
    ok(await send((await connection(owner,account)).request,dual));
    const w=await create(owner,201,'owned_window_limit',dual);
    await sandbox.refresh({revocationDateMs:Date.now(),revocationReason:1},5);
    for(const env of [dual,single]){
      expect(await policy(w.windowId,env)).toMatchObject({deliveryStatus:'active'});
      await db.batch(groupDeliveryPolicyStatements(env,w.windowId));
      await create(owner,201,'owned_window_limit',env);
    }
    expect((await db.prepare("SELECT materialized_grants_plus FROM billing_effective_entitlement_current WHERE environment='Production' AND original_transaction_id=?")
      .bind(paid.transaction.originalTransactionId).first())?.materialized_grants_plus).toBe(1);
  });

  it('requires explicit, valid dual permission and retains owner-only and upper/lower gate boundaries',async()=>{
    const owner=await plusOwner(),w=await create(owner);
    for(const invalid of [single,{...dual,BILLING_ACCEPT_SANDBOX_IN_PRODUCTION:undefined},
      {...dual,BILLING_ACCEPT_SANDBOX_IN_PRODUCTION:'yes'}, {...dual,BILLING_STORE_ENVIRONMENT:'Unknown'},
      {...dual,BILLING_STORE_ENVIRONMENT:'Sandbox'}, {...dual,BILLING_SANDBOX_OWNER_ONLY_REQUIRED:'YES'},
      {...dual,BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'NO'}]){
      expect(await policy(w.windowId,invalid as Env)).toMatchObject({deliveryStatus:'paused'});
      await expect(db.batch(groupDeliveryPolicyStatements(invalid as Env,w.windowId))).rejects.toThrow('group_window_paused');
      await create(owner,403,'owner_plus_required',invalid as Env);
    }
    // Existing local owner Sandbox scope remains single-environment and usable.
    expect(await policy(w.windowId,{...settings,BILLING_SANDBOX_OWNER_ONLY_REQUIRED:'YES'})).toMatchObject({deliveryStatus:'active'});
    await db.batch(groupDeliveryPolicyStatements({...settings,BILLING_SANDBOX_OWNER_ONLY_REQUIRED:'YES'},w.windowId));
    const withoutRateLimit={...dual};delete withoutRateLimit.MEMBER_RATE_LIMITER;
    await create(owner,503,'rate_limiter_unavailable',withoutRateLimit);
    const planned=groupDeliveryPolicyStatements(dual,w.windowId);
    const before=await db.prepare('SELECT updated_at FROM group_windows WHERE space_id=?').bind(w.windowId).first();
    await gates(0);
    await expect(db.batch([db.prepare('UPDATE group_windows SET updated_at=updated_at+1 WHERE space_id=?').bind(w.windowId),...planned]))
      .rejects.toThrow('group_window_paused');
    expect(await db.prepare('SELECT updated_at FROM group_windows WHERE space_id=?').bind(w.windowId).first()).toEqual(before);
  });

  it('enforces the dual-context SQL constraints and retains legacy single-store checks',async()=>{
    const owner=await plusOwner(),w=await create(owner);
    for(const [environment,allow] of [['Unknown',1],['Sandbox',1],[null,1]] as const){
      await expect(db.prepare('INSERT INTO group_delivery_environment_checks VALUES(?,?,?,?)')
        .bind(crypto.randomUUID(),w.windowId,environment,allow).run()).rejects.toThrow();
      await expect(db.prepare('INSERT INTO group_creation_environment_checks VALUES(?,?,?,?,?)')
        .bind(crypto.randomUUID(),w.windowId,owner.id,environment,allow).run()).rejects.toThrow();
    }
    await expect(db.prepare('INSERT INTO group_delivery_environment_checks(id,space_id,store_environment) VALUES(?,?,?)')
      .bind(crypto.randomUUID(),w.windowId,'Production').run()).rejects.toThrow('group_window_paused');
    await expect(db.batch(groupCreationPolicyStatements(dual,w.windowId,(await person()).id,crypto.randomUUID())))
      .rejects.toThrow('group_billing_connection_invalid');
    await expect(db.prepare('INSERT INTO group_delivery_policy_checks VALUES(?,?,?)')
      .bind(crypto.randomUUID(),w.windowId,'Production').run()).rejects.toThrow('group_window_paused');
    const legacy=crypto.randomUUID();
    await db.batch([db.prepare('INSERT INTO group_delivery_policy_checks VALUES(?,?,?)').bind(legacy,w.windowId,'Sandbox'),
      db.prepare('DELETE FROM group_delivery_policy_checks WHERE id=?').bind(legacy),
      db.prepare('INSERT INTO group_creation_policy_checks VALUES(?,?,?,?)').bind(legacy,w.windowId,owner.id,'Sandbox'),
      db.prepare('DELETE FROM group_creation_policy_checks WHERE id=?').bind(legacy)]);
    // Even granting Production authority cannot make a non-boolean permission valid.
    await authority(owner.account,'PURCHASED',Date.now(),'Production');
    await expect(db.prepare('INSERT INTO group_delivery_environment_checks VALUES(?,?,?,?)')
      .bind(crypto.randomUUID(),w.windowId,'Production',2).run()).rejects.toThrow('CHECK constraint failed');
    await expect(db.prepare('INSERT INTO group_creation_environment_checks VALUES(?,?,?,?,?)')
      .bind(crypto.randomUUID(),w.windowId,owner.id,'Production',2).run()).rejects.toThrow('CHECK constraint failed');
  });

  it('retains the five-room limit and rejects Family Sharing, expiry and revoked commit races in dual mode',async()=>{
    const owner=await plusOwner(),w=await create(owner,201,'owned_window_limit',dual);
    for(let i=0;i<4;i++)await create(owner,201,'owned_window_limit',dual);
    await create(owner,409,'owned_window_limit',dual);
    await owner.verified.refresh({ownershipType:'FAMILY_SHARED'});
    expect(await policy(w.windowId)).toMatchObject({deliveryStatus:'paused'});
    await expect(db.batch(groupDeliveryPolicyStatements(dual,w.windowId))).rejects.toThrow('group_window_paused');
    await owner.verified.refresh({expiresDateMs:Date.now()-1});
    expect(await policy(w.windowId)).toMatchObject({deliveryStatus:'paused'});
    await owner.verified.refresh();
    const planned=groupDeliveryPolicyStatements(dual,w.windowId);
    await owner.verified.refresh({revocationDateMs:Date.now(),revocationReason:1},5);
    await expect(db.batch(planned)).rejects.toThrow('group_window_paused');
    expect((await db.prepare('SELECT COUNT(*) n FROM group_windows WHERE owner_person_id=?').bind(owner.id).first())?.n).toBe(5);
  });
});
