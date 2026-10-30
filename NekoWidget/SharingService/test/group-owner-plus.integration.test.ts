import {describe,expect,it} from 'vitest';
import {randomBase64url} from '../src/encoding';
import {effectiveBillingEntitlement} from '../src/billing-entitlement';
import {groupDeliveryPolicies,groupDeliveryPolicyStatements} from '../src/group-owner-plus';
import {apply,call,create,db,invitation,ok,person,send,signed,transition} from './group-fixture';
import {authority,billing,connection,gates,pauseOwner,plusOwner,settings} from './group-billing-fixture';

async function policy(windowId:string,env=settings) {return (await groupDeliveryPolicies(env,[windowId])).get(windowId);}
describe('group ownership requires one verified App Store subscription from the first room',()=>{
  it('does not grant a local trial or accept a billing connection as a subscription',async()=>{
    const p=await person();
    await create(p,403,'owner_plus_required');
    const b=await billing();await gates();ok(await send((await connection(p,b)).request,settings));
    await create(p,403,'owner_plus_required');
    expect((await db.prepare('SELECT COUNT(*) n FROM group_windows WHERE owner_person_id=?').bind(p.id).first<{n:number}>())?.n).toBe(0);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_members WHERE person_id=?').bind(p.id).first<{n:number}>())?.n).toBe(0);
  });
  it('allows five for verified monthly Plus and ignores the age of the room',async()=>{
    const owner=await plusOwner(),w=await create(owner);
    await db.prepare('UPDATE group_windows SET created_at=unixepoch()-365*86400 WHERE space_id=?').bind(w.windowId).run();
    expect(await policy(w.windowId)).toEqual({deliveryStatus:'active',deliveryReason:'owner_plus',ownerParticipantId:w.roster.members[0]!.participantId});
    await db.batch(groupDeliveryPolicyStatements(settings,w.windowId));
    const wire=ok(await call(owner,`/v3/group-windows/${w.windowId}`)).window;
    expect(wire).not.toHaveProperty('trialEndsAt');
    for(let i=0;i<4;i++)await create(owner);
    await create(owner,409);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_windows WHERE owner_person_id=?').bind(owner.id).first<{n:number}>())?.n).toBe(5);
  });
  it('pauses at the verified Apple expiry with no room-age grace, and keeps approval, roster and keys usable',async()=>{
    const owner=await plusOwner(),guest=await person();let w=await create(owner);
    // This is a still-fresh authority read, so only Apple's signed expiry can
    // end access. A future room creation date must not supply a free period.
    await owner.verified.refresh({expiresDateMs:Date.now()-1});
    await db.prepare('UPDATE group_windows SET created_at=unixepoch()+365*86400 WHERE space_id=?').bind(w.windowId).run();
    expect(await policy(w.windowId)).toMatchObject({deliveryStatus:'paused',deliveryReason:'owner_plus_required'});
    const oldReader=await db.prepare(`SELECT (CASE WHEN trial_ends_at>unixepoch() THEN 'trial'
      WHEN EXISTS (SELECT 1 FROM group_verified_plus_people p WHERE p.person_id=w.owner_person_id AND p.environment='Sandbox')
      THEN 'owner_plus' ELSE 'owner_plus_required' END) reason FROM group_window_owner_policy w WHERE space_id=?`).bind(w.windowId).first();
    expect(oldReader?.reason).toBe('owner_plus_required');
    await expect(db.batch(groupDeliveryPolicyStatements(settings,w.windowId))).rejects.toThrow('group_window_paused');
    const invite=await invitation(owner,w),join=await apply(guest,w,invite);ok(join.response,201);
    const approved=await transition(owner,w,'admit',join.id,[...w.roster.members,join.member]);ok(approved.response);w=approved.next;
    expect(ok(await call(guest,`/v3/group-windows/${w.windowId}/keys/2`)).envelopeForThisDevice.deviceId).toBe(guest.deviceId);
    expect(ok(await call(guest,'/v3/group-windows/list',{after:null,limit:50})).items[0]).toMatchObject({deliveryStatus:'paused',deliveryReason:'owner_plus_required'});
    ok((await transition(owner,w,'remove',join.member.participantId,[w.roster.members[0]!])).response);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_rosters WHERE space_id=?').bind(w.windowId).first<{n:number}>())?.n).toBe(3);
  });
  it('binds both signatures to this person and device, and rejects nonce replay or a different person',async()=>{
    await gates();const owner=await person(),other=await person(),b=await billing(),c=await connection(owner,b);
    expect((await send(await signed(owner,'/v3/group-windows/billing-connection',c.body),settings)).status).toBe(401);
    const copied=await signed(other,'/v3/group-windows/billing-connection',c.body),headers=new Headers(copied.headers);
    c.request.headers.forEach((v,k)=>{if(k.startsWith('neko-billing-'))headers.set(k,v);});
    expect((await send(new Request(copied,{headers}),settings)).status).toBe(401);
    ok(await send(c.request,settings));ok(await send((await connection(owner,b,c.body.operationId)).request,settings));
    expect((await send((await connection(owner,b,crypto.randomUUID(),c.nonce)).request,settings)).data.error.code).toBe('replayed_billing_request');
    expect((await send((await connection(other,b)).request,settings)).data.error.code).toBe('billing_connection_conflict');
    expect((await db.prepare('SELECT COUNT(*) n FROM group_billing_connections WHERE billing_account_id=?').bind(b.id).first<{n:number}>())?.n).toBe(1);
  });
  it('resumes on a verified renewal without a new room or a cron',async()=>{
    const owner=await plusOwner(),w=await create(owner);await pauseOwner(owner);
    expect(await policy(w.windowId)).toMatchObject({deliveryStatus:'paused'});
    await owner.verified.refresh({transactionId:'229999999999999',transactionReason:'RENEWAL',purchaseDateMs:Date.now()});
    await db.batch(groupDeliveryPolicyStatements(settings,w.windowId));
    expect(await policy(w.windowId)).toMatchObject({deliveryStatus:'active',deliveryReason:'owner_plus'});
    expect((await db.prepare('SELECT COUNT(*) n FROM group_windows WHERE owner_person_id=?').bind(owner.id).first<{n:number}>())?.n).toBe(1);
  });
  it('a paying guest does not replace the creator subscription',async()=>{
    const owner=await plusOwner(),w=await create(owner),guest=await plusOwner();await pauseOwner(owner);
    expect(await policy(w.windowId)).toMatchObject({deliveryStatus:'paused'});
    expect((await db.prepare('SELECT person_id FROM group_billing_connections WHERE person_id=?').bind(guest.id).first())?.person_id).toBe(guest.id);
  });
  it('does not grant group Plus from FAMILY_SHARED authority in 1.0',async()=>{
    // Normalized verified authority seam, not proof of a real Family receipt.
    const owner=await plusOwner(),w=await create(owner);
    await owner.verified.refresh({ownershipType:'FAMILY_SHARED'});
    expect(await policy(w.windowId)).toMatchObject({deliveryStatus:'paused',deliveryReason:'owner_plus_required'});
    expect((await effectiveBillingEntitlement(settings,owner.account.id)).grantsPlus).toBe(false);
  });
  it('does not substitute grace when the upper/lower gate, environment or authority freshness fails',async()=>{
    const owner=await plusOwner(),w=await create(owner);
    expect(await policy(w.windowId,{...settings,BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'NO'})).toMatchObject({deliveryStatus:'paused'});
    expect(await policy(w.windowId,{...settings,BILLING_STORE_ENVIRONMENT:'Production'})).toMatchObject({deliveryStatus:'paused'});
    expect(await policy(w.windowId,{...settings,ENVIRONMENT:'production'})).toMatchObject({deliveryStatus:'paused'});
    const planned=groupDeliveryPolicyStatements(settings,w.windowId);
    const before=await db.prepare('SELECT updated_at FROM group_windows WHERE space_id=?').bind(w.windowId).first<{updated_at:number}>();
    await gates(0);
    await expect(db.batch([db.prepare('UPDATE group_windows SET updated_at=updated_at+1 WHERE space_id=?').bind(w.windowId),...planned])).rejects.toThrow('group_window_paused');
    expect((await db.prepare('SELECT updated_at FROM group_windows WHERE space_id=?').bind(w.windowId).first<{updated_at:number}>())?.updated_at).toBe(before?.updated_at);
    await gates();
    const staleOwner=await person(),b=await billing();await authority(b,'PURCHASED',Date.now()-37*3600000);
    ok(await send((await connection(staleOwner,b)).request,settings));
    await create(staleOwner,403,'owner_plus_required');
  });
});
