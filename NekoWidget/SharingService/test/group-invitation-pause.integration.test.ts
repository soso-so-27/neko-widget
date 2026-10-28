import {env} from 'cloudflare:workers';
import {applyD1Migrations,reset,type D1Migration} from 'cloudflare:test';
import {beforeEach,describe,expect,it} from 'vitest';
import {fixture as operatorFixture} from './fixtures/moderation-operator';
import {routeGroupOperator,type GroupOperatorEnvironment} from '../src/group-moderation-operator';
import {plusOwner} from './group-billing-fixture';
import {apply,call,create,db,invitation,key,member,ok,packet,person,send,sign,signed,testEnv,transition} from './group-fixture';
import {groupFields} from '../src/group-protocol';
import {randomBase64url} from '../src/encoding';

const prefix='/operator/group/v1/invitations';
interface Challenge {challengeId:string;challenge:string;assertionPath:string}
async function operator() {
 const f=await operatorFixture();
 await db.prepare(`INSERT INTO moderation_owner_policies(policy_revision,owner_operator_id,enrollment_admission_id,session_rowid_floor)
 SELECT COALESCE((SELECT MAX(policy_revision) FROM moderation_owner_policies),0)+1,?,enrollment_admission_id,
 COALESCE((SELECT MAX(rowid) FROM moderation_operator_access_sessions),0)
 FROM moderation_operator_enrollment_admissions a JOIN moderation_operator_enrollment_requests e USING(enrollment_request_id)
 WHERE e.target_operator_id=? ORDER BY a.rowid DESC LIMIT 1`).bind(f.operatorId,f.operatorId).run();
 const local:GroupOperatorEnvironment={...f.local,group:{runtimeEnabled:'YES',caseHmacKey:new Uint8Array(32),reviewEvidence:async()=>{throw Error('not used');}}};
 const failures:string[]=[];
 local.db=new Proxy(db,{get(target,name){if(name==='batch')return async(s:D1PreparedStatement[])=>{try{return await target.batch(s);}catch(e){failures.push(String(e));throw e;}};
  const v=Reflect.get(target,name);return typeof v==='function'?v.bind(target):v;}});
 const dispatch=(path:string,body?:string,headers?:Record<string,string>)=>routeGroupOperator(f.request(path,'POST',body,headers),local);
 let counter=0;
 const issue=async(action:string)=>{const r=await dispatch(prefix+'/'+action);expect(r.status,failures.join('\n')).toBe(202);return r.json() as Promise<Challenge>;};
 const prove=async(c:Challenge,invalidSignature=false)=>dispatch(c.assertionPath,await f.assertion(c.challenge,{counter:++counter,invalidSignature}));
 const change=async(action:string)=>{const r=await prove(await issue(action));expect(r.status,failures.join('\n')).toBe(200);return r.json() as Promise<{paused:boolean;revision:number;operatorId:string|null;changedAt:number|null}>;};
 return {f,local,dispatch,issue,prove,change,failures};
}
beforeEach(async()=>{
 await reset();await applyD1Migrations(db,(env as unknown as {TEST_MIGRATIONS:D1Migration[]}).TEST_MIGRATIONS);
 await db.prepare(`UPDATE personal_staging_runtime_gate SET generation=generation+1,media_enabled=1,apns_enabled=1,
 report_ingestion_enabled=1,updated_at=unixepoch() WHERE singleton=1 AND generation=0`).run();
});

describe('local owner invitation pause and atomic public admission',()=>{
 it('requires fresh WebAuthn, records who/when/value, rejects replay and resumes without editing invitation rows',async()=>{
  const f=await operator();expect(await f.change('status')).toEqual({revision:0,paused:false,operatorId:null,changedAt:null});
  const invalid=await f.issue('pause');expect((await f.prove(invalid,true)).status).toBe(409);
  expect((await f.prove(invalid)).status).toBe(409);
  const c=await f.issue('pause'),body=await f.f.assertion(c.challenge,{counter:10});
  expect((await f.dispatch(c.assertionPath,body)).status).toBe(200);expect((await f.dispatch(c.assertionPath,body)).status).toBe(409);
  const event=await db.prepare(`SELECT e.revision,e.paused,c.operator_id,e.created_at FROM group_invitation_events e JOIN group_invitation_challenges c ON c.id=e.challenge_id`).first();
  expect(event).toMatchObject({revision:1,paused:1,operator_id:f.f.operatorId,created_at:expect.any(Number)});
  const resume=await f.issue('resume');expect((await f.dispatch(resume.assertionPath,await f.f.assertion(resume.challenge,{counter:11}))).status).toBe(200);
  expect(await db.prepare('SELECT revision,paused FROM group_invitation_state').first()).toEqual({revision:2,paused:0});
  await expect(db.prepare('DELETE FROM group_invitation_events').run()).rejects.toThrow('append_only');
 });
 it('blocks issue and final new-person approval, keeps pending visible, and retries the exact failed operation after resume',async()=>{
  const owner=await plusOwner(),bob=await person(),w=await create(owner),invite=await invitation(owner,w),f=await operator();
  await f.change('pause');
  const issueBody={operationId:crypto.randomUUID(),expectedRevision:1,proofPublicKey:(await key()).publicKey};
  expect(await call(owner,`/v3/group-windows/${w.windowId}/invitations`,issueBody)).toMatchObject({status:503,data:{error:{code:'invitation_paused'}}});
  const b=await apply(bob,w,invite);expect(ok(b.response,201).admissionPaused).toBe(true);
  const joinBody=JSON.parse((await db.prepare('SELECT signed_request FROM group_join_requests WHERE id=?').bind(b.id).first<{signed_request:string}>())!.signed_request) as unknown;
  const retry=ok(await call(bob,`/v3/group-windows/${w.windowId}/join-requests`,joinBody));
  expect(retry).toEqual(b.response.data);
  expect(ok(await call(bob,`/v3/group-windows/${w.windowId}/join-status`,{requestId:b.id}))).toMatchObject({state:'pending',admissionPaused:true});
  const rejected=await transition(owner,w,'admit',b.id,[...w.roster.members,b.member]);
  expect(rejected.response).toMatchObject({status:503,data:{error:{code:'invitation_paused'}}});
  expect(await db.prepare('SELECT revision,key_epoch FROM group_windows WHERE space_id=?').bind(w.windowId).first()).toEqual({revision:1,key_epoch:1});
  expect(await db.prepare('SELECT state FROM group_join_requests WHERE id=?').bind(b.id).first()).toEqual({state:'pending'});
  expect(await db.prepare('SELECT participant_id FROM group_members WHERE person_id=?').bind(bob.id).first()).toBeNull();
  await f.change('resume');
  ok(await call(owner,`/v3/group-windows/${w.windowId}/join-requests/${b.id}/approve`,rejected.body));
  await f.change('pause');
  // Response loss: a previously successful operation returns its original result while paused.
  ok(await call(owner,`/v3/group-windows/${w.windowId}/join-requests/${b.id}/approve`,rejected.body));
  expect(ok(await call(bob,`/v3/group-windows/${w.windowId}/join-status`,{requestId:b.id}))).toMatchObject({state:'approved',admissionPaused:false});
  expect(ok(await call(bob,`/v3/group-windows/${w.windowId}/join-requests`,joinBody))).toEqual({...b.response.data,admissionPaused:false});
 });
 it('checks pause inside the final approval batch after request validation, rolling back nonce/request/roster writes',async()=>{
  const owner=await plusOwner(),bob=await person(),w=await create(owner),invite=await invitation(owner,w),b=await apply(bob,w,invite),f=await operator();
  const data=await packet(owner,{...w.roster,revision:2,keyEpoch:2,previousHash:w.hash,members:[...w.roster.members,b.member]});
  const {hash,...wire}=data;void hash;
  const body={operationId:crypto.randomUUID(),expectedRevision:1,kind:'admit',targetId:b.id,...wire};
  let batches=0;
  const racingDB=new Proxy(db,{get(target,name){if(name==='batch')return async(s:D1PreparedStatement[])=>{batches++;await f.change('pause');return target.batch(s);};
   const v=Reflect.get(target,name);return typeof v==='function'?v.bind(target):v;}});
  const r=await send(await signed(owner,`/v3/group-windows/${w.windowId}/join-requests/${b.id}/approve`,body),{...testEnv,DB:racingDB});
  expect(batches).toBe(1);expect(r).toMatchObject({status:503,data:{error:{code:'invitation_paused'}}});
  expect(await db.prepare('SELECT response_json FROM group_mutations WHERE operation_id=?').bind(body.operationId).first()).toBeNull();
  expect(await db.prepare('SELECT state,result_revision FROM group_join_requests WHERE id=?').bind(b.id).first()).toEqual({state:'pending',result_revision:null});
 });
 it('allows both active-member device recovery routes and leaving; a former member cannot rejoin while paused',async()=>{
  const owner=await plusOwner(),bob=await person(),phone2=await person(bob.identity),phone3=await person(bob.identity);let w=await create(owner);
  const invite=await invitation(owner,w),b=await apply(bob,w,invite);w=(await transition(owner,w,'admit',b.id,[...w.roster.members,b.member])).next;
  const f=await operator();await f.change('pause');
  const second=await apply(phone2,w,invite);expect(ok(second.response,201).admissionPaused).toBe(false);
  const two={...b.member,devices:[...b.member.devices,...second.member.devices]};
  let added=await transition(owner,w,'admit',second.id,[w.roster.members[0]!,two]);ok(added.response);w=added.next;
  const third=await member(phone3,w.windowId),three={...two,devices:[...two.devices,...third.devices]};
  added=await transition(owner,w,'addDevice',phone3.deviceId,[w.roster.members[0]!,three],{personSponsorSignature:third.devices[0]!.personAuthorization});ok(added.response);w=added.next;
  ok(await call(phone3,`/v3/group-windows/${w.windowId}/keys/${w.roster.keyEpoch}`));
  const operationId=crypto.randomUUID();ok(await call(bob,`/v3/group-windows/${w.windowId}/leave`,{operationId,expectedRevision:w.roster.revision,
   selfSignature:await sign(bob.signing.privateKey,groupFields(['NW3.LEAVE',w.windowId,b.member.participantId,String(w.roster.revision),operationId]))}));
  const rotation=await transition(owner,w,'rotate',w.windowId,[w.roster.members[0]!]);ok(rotation.response);w=rotation.next;
  const again=await apply(bob,w,invite);expect(ok(again.response,201).admissionPaused).toBe(true);
  const denied=await transition(owner,w,'admit',again.id,[...w.roster.members,{...again.member,participantId:b.member.participantId}]);
  expect(denied.response.data.error.code).toBe('invitation_paused');
 });
 it('preserves cancellation and does not revive cancelled or expired invitations on resume',async()=>{
  const owner=await plusOwner(),bob=await person(),w=await create(owner),invite=await invitation(owner,w),b=await apply(bob,w,invite),f=await operator();
  const expired=randomBase64url(16),now=Math.floor(Date.now()/1000);
  await db.prepare('INSERT INTO group_invitations VALUES (?,?,?,?,?,?,NULL)').bind(expired,w.windowId,(await key()).publicKey,owner.deviceId,now-90000,now-3600).run();
  await f.change('pause');
  ok(await call(bob,`/v3/group-windows/${w.windowId}/join-requests/${b.id}/cancel`,{operationId:crypto.randomUUID()}));
  expect(ok(await call(bob,`/v3/group-windows/${w.windowId}/join-status`,{requestId:b.id}))).toMatchObject({state:'cancelled',admissionPaused:false});
  const joinBody=JSON.parse((await db.prepare('SELECT signed_request FROM group_join_requests WHERE id=?').bind(b.id).first<{signed_request:string}>())!.signed_request) as unknown;
  expect(ok(await call(bob,`/v3/group-windows/${w.windowId}/join-requests`,joinBody))).toEqual({...b.response.data,admissionPaused:false});
  ok(await call(owner,`/v3/group-windows/${w.windowId}/invitations/${invite.id}/revoke`,{operationId:crypto.randomUUID(),expectedRevision:1}));
  await f.change('resume');
  expect((await call(bob,`/v3/group-windows/${w.windowId}/invitation-challenges`,{invitationId:invite.id})).data.error.code).toBe('invitation_revoked');
  expect((await call(bob,`/v3/group-windows/${w.windowId}/invitation-challenges`,{invitationId:expired})).data.error.code).toBe('invitation_expired');
 });
 it('rejects stale operator decisions, wrong Origin, counter reuse, revoked actors and public operator requests',async()=>{
  const f=await operator(),stale=await f.issue('pause');await f.change('pause');
  expect((await f.prove(stale)).status).toBe(409);
  expect((await f.dispatch(prefix+'/resume',undefined,{origin:'https://wrong.invalid'})).status).toBe(403);
  const next=await f.issue('resume');expect((await f.dispatch(next.assertionPath,await f.f.assertion(next.challenge,{counter:1}))).status).toBe(409);
  const revoked=await f.issue('resume');await db.prepare("INSERT INTO moderation_operator_credential_events(credential_id_sha256,event_type) VALUES (?,'revoked')").bind(f.f.credentialDigest).run();
  expect((await f.prove(revoked)).status).toBe(403);
  expect((await send(new Request('https://group.invalid'+prefix+'/pause',{method:'POST'}))).status).toBe(404);
  expect(await db.prepare('SELECT revision,paused FROM group_invitation_state').first()).toEqual({revision:1,paused:1});
 });
 it('scopes the recovery exception to the same window and reports it on the owner pending list',async()=>{
  const owner=await plusOwner(),bob=await person(),phone=await person(bob.identity);let first=await create(owner);
  const second=await create(owner),one=await invitation(owner,first),two=await invitation(owner,second);
  const b=await apply(bob,first,one);first=(await transition(owner,first,'admit',b.id,[...first.roster.members,b.member])).next;
  const f=await operator();await f.change('pause');
  const recover=await apply(phone,first,one),join=await apply(phone,second,two);
  expect(ok(recover.response,201).admissionPaused).toBe(false);expect(ok(join.response,201).admissionPaused).toBe(true);
  for(const [w,expected] of [[first,false],[second,true]] as const){
   const rows=ok(await call(owner,`/v3/group-windows/${w.windowId}/join-requests/list`,{after:null,limit:50})).items;
   expect(rows).toHaveLength(1);expect(rows[0].admissionPaused).toBe(expected);
  }
  const rejected=await transition(owner,second,'admit',join.id,[...second.roster.members,join.member]);
  expect(rejected.response.data.error.code).toBe('invitation_paused');
 });
 it('rechecks authority after WebAuthn verification and shares the counter floor with existing group operations',async()=>{
  const f=await operator();await f.change('status');
  const queueResponse=await f.dispatch('/operator/group/v1/queue');expect(queueResponse.status).toBe(202);
  const queue=await queueResponse.json() as Challenge;
  expect((await f.dispatch(queue.assertionPath,await f.f.assertion(queue.challenge,{counter:1}))).status).toBe(409);
  const c=await f.issue('pause'),database=f.local.db;let batches=0;
  f.local.db=new Proxy(database,{get(target,name){if(name==='batch')return async(s:D1PreparedStatement[])=>{
   if(++batches===3)await db.prepare("INSERT INTO moderation_operator_role_events(operator_id,role_code,event_type) VALUES (?,'triage','revoked')").bind(f.f.operatorId).run();
   return target.batch(s);
  };const value=Reflect.get(target,name);return typeof value==='function'?value.bind(target):value;}});
  expect((await f.prove(c)).status).toBe(409);expect(batches).toBe(3);
  expect(await db.prepare('SELECT revision,paused FROM group_invitation_state').first()).toEqual({revision:0,paused:0});
  expect(await db.prepare('SELECT challenge_id FROM group_invitation_consumptions WHERE challenge_id=?').bind(c.challengeId).first()).toBeNull();
 });
});
