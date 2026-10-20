import { env } from 'cloudflare:workers';
import { describe,expect,it } from 'vitest';
import type { Env } from '../src/env';
import { errorResponse } from '../src/errors';
import { route } from '../src/index';
import { base64urlDecode,base64urlEncode,randomBase64url,sha256Base64url } from '../src/encoding';
import { groupIdentityTranscript } from '../src/group-identities';
import { groupJoinTranscript } from '../src/group-joins';
import { groupDeviceAuthorization,groupFields,groupRosterBytes,type GroupRoster,type GroupRosterMember,type SignedGroupRoster,type GroupKeyEnvelope } from '../src/group-protocol';

const testEnv={...env as unknown as Env,GROUP_RUNTIME_ENABLED:'YES'};
const db=testEnv.DB;
async function key() {
  const pair=await crypto.subtle.generateKey({name:'Ed25519'},true,['sign','verify']) as CryptoKeyPair;
  return {privateKey:pair.privateKey,publicKey:base64urlEncode(new Uint8Array(await crypto.subtle.exportKey('raw',pair.publicKey)))};
}
async function sign(key:CryptoKey,message:Uint8Array):Promise<string> {
  return base64urlEncode(new Uint8Array(await crypto.subtle.sign('Ed25519',key,message.slice().buffer)));
}
// Test-only response record; requests still pass through the actual HTTP router,
// WebCrypto signature verification, runtime gates and local D1 transactions.
type Reply={status:number;data:Record<string,any>};
async function send(request:Request,settings:Env=testEnv):Promise<Reply> {
  let response:Response;
  try { response=await route(request,settings); } catch(error) { response=errorResponse(error); }
  return {status:response.status,data:await response.json() as Record<string,any>};
}
async function post(path:string,body:unknown):Promise<Reply> {
  return send(new Request(`https://group.invalid${path}`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)}));
}
async function person(root?:Awaited<ReturnType<typeof key>>,expectedStatus=201) {
  const identity=root??await key(),signing=await key(),hpke=randomBase64url(32);
  const challenge=await post('/v3/group-identities/challenges',{purpose:'register',signingPublicKey:signing.publicKey,hpkePublicKey:hpke});
  expect(challenge.status).toBe(201);
  const operationId=crypto.randomUUID(),transcript=groupIdentityTranscript({operationId,challengeId:challenge.data.challengeId,
    challenge:challenge.data.challenge,expiresAt:challenge.data.expiresAt,personPublicKey:identity.publicKey,
    signingPublicKey:signing.publicKey,hpkePublicKey:hpke});
  const body={operationId,challengeId:challenge.data.challengeId,personPublicKey:identity.publicKey,signingPublicKey:signing.publicKey,
    hpkePublicKey:hpke,personSignature:await sign(identity.privateKey,transcript),deviceSignature:await sign(signing.privateKey,transcript)};
  const result=await post('/v3/group-identities',body);
  expect({status:result.status,error:result.data.error?.code}).toEqual({status:expectedStatus,error:expectedStatus===201?undefined:'device_limit'});
  return {identity,signing,hpke,id:result.data.personId as string,deviceId:result.data.deviceId as string,registration:body};
}
type Person=Awaited<ReturnType<typeof person>>;
async function signed(p:Person,path:string,body?:unknown,nonce=randomBase64url(16)) {
  const method=body===undefined?'GET':'POST',raw=body===undefined?new Uint8Array():new TextEncoder().encode(JSON.stringify(body));
  const timestamp=String(Math.floor(Date.now()/1000)),hash=base64urlDecode(await sha256Base64url(raw),32);
  return new Request(`https://group.invalid${path}`,{method,headers:{'content-type':'application/json','neko-protocol-version':'3',
    'neko-device-id':p.deviceId,'neko-timestamp':timestamp,'neko-nonce':nonce,
    'neko-signature':await sign(p.signing.privateKey,groupFields(['NW3.REQUEST','3',p.deviceId,timestamp,nonce,method,path,hash]))},
    ...(body===undefined?{}:{body:raw})});
}
async function call(p:Person,path:string,body?:unknown) { return send(await signed(p,path,body)); }
function ok(result:Reply,status=200) { expect({status:result.status,error:result.data.error?.code}).toEqual({status,error:undefined});return result.data; }
async function member(p:Person,windowId:string,role:'owner'|'member'='member',participantId=randomBase64url(16)):Promise<GroupRosterMember> {
  const device={id:p.deviceId,signingPublicKey:p.signing.publicKey,hpkePublicKey:p.hpke,personAuthorization:''};
  device.personAuthorization=await sign(p.identity.privateKey,groupDeviceAuthorization(windowId,p.id,device));
  return {participantId,personId:p.id,identityPublicKey:p.identity.publicKey,role,devices:[device]};
}
function cipher() { return randomBase64url(48); }
async function packet(owner:Person,roster:GroupRoster) {
  const bytes=groupRosterBytes(roster),hash=await sha256Base64url(bytes);
  const signed:SignedGroupRoster={roster,signerDeviceId:owner.deviceId,
    signature:await sign(owner.signing.privateKey,groupFields(['NW3.ROSTER.SIGN',bytes,owner.deviceId]))};
  const envelopes:GroupKeyEnvelope[]=[];
  for(const d of roster.members.flatMap(m=>m.devices)) {
    const enc=randomBase64url(32),ct=randomBase64url(48);
    const info=groupFields(['NW3.KEY',roster.windowId,String(roster.keyEpoch),base64urlDecode(hash,32),d.id]);
    envelopes.push({windowId:roster.windowId,keyEpoch:roster.keyEpoch,rosterHash:hash,deviceId:d.id,encapsulatedKey:enc,ciphertext:ct,
      signerDeviceId:owner.deviceId,signature:await sign(owner.signing.privateKey,groupFields(['NW3.KEY.SIGN',info,base64urlDecode(enc),base64urlDecode(ct),owner.deviceId]))});
  }
  return {packet:signed,envelopes,encryptedName:cipher(),encryptedMemberNames:Object.fromEntries(roster.members.map(m=>[m.participantId,cipher()])),hash};
}
async function create(owner:Person,status=201) {
  const windowId=randomBase64url(16),roster:GroupRoster={windowId,revision:1,keyEpoch:1,previousHash:base64urlEncode(new Uint8Array(32)),
    ownerPersonId:owner.id,members:[await member(owner,windowId,'owner')]};
  const data=await packet(owner,roster),{hash,...wire}=data,operationId=crypto.randomUUID();
  const response=await call(owner,'/v3/group-windows',{operationId,...wire});
  if(status===201) ok(response,201);
  else expect({status:response.status,code:response.data.error?.code}).toEqual({status,code:'owned_window_limit'});
  return {windowId,roster,hash};
}
async function invitation(owner:Person,w:Awaited<ReturnType<typeof create>>) {
  const proof=await key(),data=ok(await call(owner,`/v3/group-windows/${w.windowId}/invitations`,{
    operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,proofPublicKey:proof.publicKey}),201);
  return {proof,id:data.invitationId as string};
}
async function apply(p:Person,w:Awaited<ReturnType<typeof create>>,invite:Awaited<ReturnType<typeof invitation>>) {
  const root=`/v3/group-windows/${w.windowId}`,challenge=ok(await call(p,`${root}/invitation-challenges`,{invitationId:invite.id}),201);
  const m=await member(p,w.windowId),operationId=crypto.randomUUID(),encryptedDisplayName=cipher(),personAuthorization=m.devices[0]!.personAuthorization;
  const transcript=groupJoinTranscript({windowId:w.windowId,invitationId:invite.id,challengeId:challenge.challengeId,challenge:challenge.challenge,
    expiresAt:challenge.expiresAt,operationId,personId:p.id,deviceId:p.deviceId,encryptedNameHash:await sha256Base64url(base64urlDecode(encryptedDisplayName)),personAuthorization});
  const response=await call(p,`${root}/join-requests`,{operationId,invitationId:invite.id,challengeId:challenge.challengeId,personId:p.id,
    candidateDeviceId:p.deviceId,encryptedDisplayName,personAuthorization,inviteProof:await sign(invite.proof.privateKey,transcript),deviceSignature:await sign(p.signing.privateKey,transcript)});
  return {response,member:m,id:response.data.requestId as string};
}
async function transition(owner:Person,w:Awaited<ReturnType<typeof create>>,kind:'admit'|'remove'|'rotate'|'addDevice',targetId:string,members:GroupRosterMember[],extra={}) {
  const roster:GroupRoster={...w.roster,revision:w.roster.revision+1,keyEpoch:w.roster.keyEpoch+1,previousHash:w.hash,members};
  const data=await packet(owner,roster),{hash,...wire}=data;
  const body={operationId:crypto.randomUUID(),expectedRevision:w.roster.revision,kind,targetId,...wire,...extra};
  const path=kind==='admit'?`join-requests/${targetId}/approve`:kind==='remove'?`members/${targetId}/remove`:kind==='rotate'?'rotate':'devices/admit';
  const response=await call(owner,`/v3/group-windows/${w.windowId}/${path}`,body);
  return {response,body,next:{windowId:w.windowId,roster,hash}};
}

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
