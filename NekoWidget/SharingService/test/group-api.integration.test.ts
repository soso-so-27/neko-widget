import {describe,expect,it} from 'vitest';
import {randomBase64url,base64urlEncode} from '../src/encoding';
import {groupFields} from '../src/group-protocol';
import {testEnv,db,key,sign,send,post,person,signed,call,ok,create,invitation,apply,transition} from './group-fixture';

describe('gated group HTTP identity, invitation and membership',()=>{
  it('defaults closed, including registration, and respects the lower media gate',async()=>{
    const request=new Request('https://group.invalid/v3/group-identities/challenges',{method:'POST',headers:{'content-type':'application/json'},body:'{}'});
    const closed:Env={...testEnv};delete closed.GROUP_RUNTIME_ENABLED;
    expect((await send(request,closed)).data.error.code).toBe('group_runtime_disabled');
    await db.prepare('UPDATE personal_staging_runtime_gate SET media_enabled=0,apns_enabled=0,generation=generation+1').run();
    expect((await send(request)).status).toBe(503);
    await db.prepare('UPDATE personal_staging_runtime_gate SET media_enabled=1,apns_enabled=1,generation=generation+1').run();
  });
  it('registers only with both root and device proofs; replay is stable; a root has at most three phones',async()=>{
    const p=await person();
    expect(ok(await post('/v3/group-identities',p.registration)).deviceId).toBe(p.deviceId);
    const altered={...p.registration,deviceSignature:randomBase64url(64)};
    expect((await post('/v3/group-identities',altered)).data.error.code).toBe('invalid_proof');
    await person(p.identity);await person(p.identity);
    // Registering a fourth device is rejected by the actual HTTP/DB path.
    await person(p.identity,409);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_person_devices WHERE person_id=?').bind(p.id).first<{n:number}>())?.n).toBe(3);
  });
  it('signs method/path/raw-body, rejects nonce replay and unknown plaintext-name fields',async()=>{
    const owner=await person(),w=await create(owner),path=`/v3/group-windows/${w.windowId}`;
    const request=await signed(owner,path);
    ok(await send(request.clone() as Request));
    expect((await send(request.clone() as Request)).data.error.code).toBe('replay');
    const modified=new Request(`https://group.invalid${path}/different`,request);
    expect((await send(modified)).data.error.code).toBe('invalid_authentication');
    expect((await call(owner,`${path}/invitations`,{operationId:crypto.randomUUID(),expectedRevision:1,proofPublicKey:(await key()).publicKey,notificationLabel:'private'})).status).toBe(400);
    expect((await call(owner,'/v3/group-windows',{})).status).toBe(400);
  });
  it('admits three people, preserves idempotency, and never gives pre-join keys or other device envelopes',async()=>{
    const owner=await person(),bob=await person(),cat=await person();let w=await create(owner);
    const invite=await invitation(owner,w),b=await apply(bob,w,invite),c=await apply(cat,w,invite);
    ok(b.response,201);ok(c.response,201);
    expect((await call(bob,`/v3/group-windows/${w.windowId}`)).status).toBe(404);
    expect((await call(cat,`/v3/group-windows/${w.windowId}/join-status`,{requestId:b.id})).status).toBe(404);
    const a=await transition(owner,w,'admit',b.id,[...w.roster.members,b.member]);ok(a.response);w=a.next;
    const repeat=await call(owner,`/v3/group-windows/${w.windowId}/join-requests/${b.id}/approve`,a.body);
    expect(ok(repeat).revision).toBe(2);
    const added=await transition(owner,w,'admit',c.id,[...w.roster.members,c.member]);ok(added.response);w=added.next;
    const current=ok(await call(bob,`/v3/group-windows/${w.windowId}/keys/3`));
    expect(current.envelopeForThisDevice.deviceId).toBe(bob.deviceId);
    expect(current).not.toHaveProperty('envelopes');
    expect((await call(bob,`/v3/group-windows/${w.windowId}/keys/1`)).status).toBe(403);
    expect(ok(await call(owner,`/v3/group-windows/${w.windowId}/members/list`,{after:null,limit:50})).items).toHaveLength(3);
    expect(ok(await call(bob,`/v3/group-windows/${w.windowId}/rosters/list`,{afterRevision:0,limit:50})).items).toHaveLength(3);
    expect((await call(bob,`/v3/group-windows/${w.windowId}/invitations`,{operationId:crypto.randomUUID(),expectedRevision:3,proofPublicKey:(await key()).publicKey})).status).toBe(403);
  });
  it('cancels reusable invitations without unsigned roster revisions; rejects pending approval after cancellation',async()=>{
    const owner=await person(),bob=await person(),cat=await person(),w=await create(owner),invite=await invitation(owner,w);
    const b=await apply(bob,w,invite),c=await apply(cat,w,invite);ok(b.response,201);ok(c.response,201);
    const revoked=ok(await call(owner,`/v3/group-windows/${w.windowId}/invitations/${invite.id}/revoke`,{operationId:crypto.randomUUID(),expectedRevision:1}));
    expect(revoked.revision).toBe(1);
    expect((await transition(owner,w,'admit',b.id,[...w.roster.members,b.member])).response.data.error.code).toBe('request_not_pending');
    expect(ok(await call(bob,`/v3/group-windows/${w.windowId}/join-status`,{requestId:b.id})).state).toBe('cancelled');
  });
  it('rejects or withdraws only pending requests; a member cannot reject another candidate',async()=>{
    const owner=await person(),bob=await person(),cat=await person(),w=await create(owner),invite=await invitation(owner,w);
    const b=await apply(bob,w,invite),c=await apply(cat,w,invite);ok(b.response,201);ok(c.response,201);
    const base=`/v3/group-windows/${w.windowId}/join-requests`;
    expect((await call(cat,`${base}/${b.id}/cancel`,{operationId:crypto.randomUUID()})).status).toBe(404);
    ok(await call(bob,`${base}/${b.id}/cancel`,{operationId:crypto.randomUUID()}));
    ok(await call(owner,`${base}/${c.id}/reject`,{operationId:crypto.randomUUID(),expectedRevision:1}));
    expect((await call(owner,`${base}/${c.id}/reject`,{operationId:crypto.randomUUID(),expectedRevision:1})).data.error.code).toBe('request_not_pending');
  });
  it('rolls back an incomplete key set and rejects an outdated approval',async()=>{
    const owner=await person(),bob=await person(),cat=await person(),w=await create(owner),invite=await invitation(owner,w);
    const b=await apply(bob,w,invite),c=await apply(cat,w,invite);ok(b.response,201);ok(c.response,201);
    const trial=await transition(owner,w,'admit',b.id,[...w.roster.members,b.member]);ok(trial.response);
    const competing=await transition(owner,w,'admit',c.id,[...w.roster.members,c.member]);
    expect(competing.response.data.error.code).toBe('stale_revision');
    expect(ok(await call(cat,`/v3/group-windows/${w.windowId}/join-status`,{requestId:c.id})).state).toBe('pending');
    const next=trial.next,roster={...next.roster,revision:3,keyEpoch:3,previousHash:next.hash,members:[...next.roster.members,c.member]};
    const data=await packet(owner,roster);data.envelopes.pop();const {hash,...wire}=data;
    const result=await call(owner,`/v3/group-windows/${w.windowId}/join-requests/${c.id}/approve`,{operationId:crypto.randomUUID(),expectedRevision:2,kind:'admit',targetId:c.id,...wire});
    expect(result.data.error.code).toBe('invalid_envelope');
    expect(ok(await call(cat,`/v3/group-windows/${w.windowId}/join-status`,{requestId:c.id})).state).toBe('pending');
  });
  it('has one winner for simultaneous approvals and leaves the other request pending',async()=>{
    const owner=await person(),bob=await person(),cat=await person(),w=await create(owner),invite=await invitation(owner,w);
    const b=await apply(bob,w,invite),c=await apply(cat,w,invite);ok(b.response,201);ok(c.response,201);
    const results=await Promise.all([transition(owner,w,'admit',b.id,[...w.roster.members,b.member]),
      transition(owner,w,'admit',c.id,[...w.roster.members,c.member])]);
    expect(results.map(r=>r.response.status).sort()).toEqual([200,409]);
    expect(results.find(r=>r.response.status===409)!.response.data.error.code).toBe('stale_revision');
    const states=await db.prepare('SELECT state FROM group_join_requests WHERE space_id=? ORDER BY state').bind(w.windowId).all<{state:string}>();
    expect(states.results.map(r=>r.state)).toEqual(['approved','pending']);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_members WHERE space_id=?').bind(w.windowId).first<{n:number}>())?.n).toBe(2);
  });
  it('binds another phone to the same person and revokes both phones on removal',async()=>{
    const owner=await person(),bob=await person(),phone2=await person(bob.identity);let w=await create(owner);
    const invite=await invitation(owner,w),b=await apply(bob,w,invite);ok(b.response,201);
    let a=await transition(owner,w,'admit',b.id,[...w.roster.members,b.member]);ok(a.response);w=a.next;
    const other=await apply(phone2,w,invite);ok(other.response,201);
    const bobTwo={...b.member,devices:[...b.member.devices,...other.member.devices]};
    a=await transition(owner,w,'admit',other.id,[w.roster.members[0]!,bobTwo]);ok(a.response);w=a.next;
    expect(ok(await call(phone2,`/v3/group-windows/${w.windowId}/keys/3`)).envelopeForThisDevice.deviceId).toBe(phone2.deviceId);
    expect((await call(phone2,`/v3/group-windows/${w.windowId}/keys/2`)).status).toBe(403);
    a=await transition(owner,w,'remove',b.member.participantId,[w.roster.members[0]!]);ok(a.response);
    expect((await call(phone2,`/v3/group-windows/${w.windowId}`)).status).toBe(404);
    expect((await call(bob,`/v3/group-windows/${w.windowId}`)).status).toBe(404);
  });
  it('keeps creation in its verified allowance and paginates only this phone’s joined windows',async()=>{
    const firstOwner=await person(),secondOwner=await person(),bob=await person(),w1=await create(firstOwner),w2=await create(secondOwner);
    await create(firstOwner,409);
    expect((await db.prepare('SELECT COUNT(*) n FROM group_windows WHERE owner_person_id=?').bind(firstOwner.id).first<{n:number}>())?.n).toBe(1);
    for(const [owner,w] of [[firstOwner,w1],[secondOwner,w2]] as const) {
      const invite=await invitation(owner,w),request=await apply(bob,w,invite);ok(request.response,201);
      ok((await transition(owner,w,'admit',request.id,[...w.roster.members,request.member])).response);
    }
    const first=ok(await call(bob,'/v3/group-windows/list',{after:null,limit:1}));
    expect(first.items).toHaveLength(1);expect(first.next).toBeTypeOf('string');
    const second=ok(await call(bob,'/v3/group-windows/list',{after:first.next,limit:1}));
    expect(second.items).toHaveLength(1);expect(second.next).toBeNull();
    expect(first.items[0].windowId).not.toBe(second.items[0].windowId);
    expect((await call(firstOwner,'/v3/group-windows/list',{after:first.next,limit:1})).data.error.code).toBe('invalid_cursor');
    expect(ok(await call(secondOwner,'/v3/group-windows/list',{after:null,limit:50})).items).toHaveLength(1);
  });
  it('revokes all phones on removal, immediately blocks leavers, and rotates before future writes',async()=>{
    const owner=await person(),bob=await person();let w=await create(owner);let invite=await invitation(owner,w);
    let b=await apply(bob,w,invite);ok(b.response,201);
    let a=await transition(owner,w,'admit',b.id,[...w.roster.members,b.member]);ok(a.response);w=a.next;
    const signature=await sign(bob.signing.privateKey,groupFields(['NW3.LEAVE',w.windowId,b.member.participantId,'2','00000000-0000-4000-8000-000000000001']));
    const leave=ok(await call(bob,`/v3/group-windows/${w.windowId}/leave`,{operationId:'00000000-0000-4000-8000-000000000001',expectedRevision:2,selfSignature:signature}));
    expect(leave.rotationRequired).toBe(true);
    expect((await call(bob,`/v3/group-windows/${w.windowId}/keys/2`)).status).toBe(404);
    expect(ok(await call(owner,`/v3/group-windows/${w.windowId}`)).window.rotationRequired).toBe(true);
    a=await transition(owner,w,'rotate',w.windowId,[w.roster.members[0]!]);ok(a.response);w=a.next;
    invite=await invitation(owner,w);b=await apply(bob,w,invite);ok(b.response,201);
    const oldParticipant=(await db.prepare('SELECT participant_id FROM group_members WHERE space_id=? AND person_id=?').bind(w.windowId,bob.id).first<{participant_id:string}>())!.participant_id;
    b.member={...b.member,participantId:oldParticipant};
    a=await transition(owner,w,'admit',b.id,[...w.roster.members,b.member]);ok(a.response);w=a.next;
    expect((await call(bob,`/v3/group-windows/${w.windowId}/keys/2`)).status).toBe(403);
    a=await transition(owner,w,'remove',b.member.participantId,[w.roster.members[0]!]);ok(a.response);
    expect((await call(bob,`/v3/group-windows/${w.windowId}`)).status).toBe(404);
    expect((await call(bob,`/v3/group-windows/${w.windowId}/keys/5`)).status).toBe(404);
  });
});
