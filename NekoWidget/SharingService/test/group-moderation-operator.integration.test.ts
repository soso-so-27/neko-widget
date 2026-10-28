import {env} from 'cloudflare:workers';
import {applyD1Migrations,reset,type D1Migration} from 'cloudflare:test';
import {beforeEach,describe,expect,it} from 'vitest';
import {fixture as operatorFixture} from './fixtures/moderation-operator';
import {plusOwner} from './group-billing-fixture';
import {apply,call,create,db,invitation,ok,person,send,sign,signed,testEnv,transition,type Person} from './group-fixture';
import {base64urlDecode,randomBase64url,sha256Base64url} from '../src/encoding';
import {groupFields} from '../src/group-protocol';
import {routeGroupOperator,type GroupOperatorEnvironment,type GroupReviewHost} from '../src/group-moderation-operator';
import {runGroupReportCleanup} from '../src/group-report-cleanup';

const settings={...testEnv,GROUP_REPORT_RUNTIME_ENABLED:'YES',GROUP_MODERATION_RUNTIME_ENABLED:'YES',REPORT_INGESTION_RUNTIME_ENABLED:'YES'};
const image=new Uint8Array([255,216,255,217]);
type Window=Awaited<ReturnType<typeof create>>;
interface Challenge {challenge:string;challengeId:string;assertionPath:string;caseReference:string|null;sourceSHA256:string|null}
const review:GroupReviewHost=async input=>{
  // Trusted JPEG transport is the sole synthetic seam. The dedicated Node
  // suite verifies real NW3 decryption; these tests use real Access/WebAuthn,
  // signed group requests and D1 transaction/expiry/recipient guards.
  await input.audit('started');await input.readCurrentSource();
  await input.audit('disclosure_ready');await input.readCurrentSource();return image.slice();
};
async function groupPhoto(owner:Person,w:Window) {
  const bytes=crypto.getRandomValues(new Uint8Array(48)),hash=await sha256Base64url(bytes),clientMomentId=randomBase64url(16);
  const participant=w.roster.members.find(m=>m.personId===owner.id)!.participantId;
  const aad=groupFields(['NW3.PHOTO',w.windowId,clientMomentId,String(w.roster.keyEpoch),base64urlDecode(w.hash,32),participant,owner.deviceId,String(bytes.length)]);
  const body={operationId:crypto.randomUUID(),clientMomentId,keyEpoch:w.roster.keyEpoch,rosterRevision:w.roster.revision,
    ciphertextSize:bytes.length,ciphertextSHA256:hash,kind:'photo',
    senderSignature:await sign(owner.signing.privateKey,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)]))};
  const id=ok(await call(owner,`/v3/group-windows/${w.windowId}/moments/reserve`,body),201).momentId as string;
  ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/moments/${id}/ciphertext`,bytes,randomBase64url(16),'PUT')));
  ok(await call(owner,`/v3/group-windows/${w.windowId}/moments/${id}/commit`,{operationId:crypto.randomUUID(),
    expectedRevision:w.roster.revision,keyEpoch:w.roster.keyEpoch,ciphertextSHA256:hash}));return id;
}
async function submittedReport(owner:Person,reporter:Person,w:Window) {
  const momentId=await groupPhoto(owner,w),bytes=crypto.getRandomValues(new Uint8Array(93)),root=`/v3/group-windows/${w.windowId}/reports`;
  const reserved=ok(await send(await signed(reporter,root+'/reserve',{operationId:crypto.randomUUID(),momentId,
    reasonCode:'privacy',moderationKeyId:'moderation-v2',ciphertextSize:bytes.length,ciphertextSHA256:await sha256Base64url(bytes),
    reporterConsent:{version:1,acceptedAt:Math.floor(Date.now()/1000)}}),settings),201);
  const id=reserved.report.id as string;
  ok(await send(await signed(reporter,`${root}/${id}/ciphertext`,bytes,randomBase64url(16),'PUT'),settings));
  ok(await send(await signed(reporter,`${root}/${id}/commit`,{operationId:crypto.randomUUID()}),settings));
  return {id,momentId,path:`${root}/${id}/status`};
}
async function fixture() {
  const owner=await plusOwner(),reporter=await person();let w=await create(owner);
  const invitationProof=await invitation(owner,w),pending=await apply(reporter,w,invitationProof);ok(pending.response,201);
  const admitted=await transition(owner,w,'admit',pending.id,[...w.roster.members,pending.member]);ok(admitted.response);w=admitted.next;
  const report=await submittedReport(owner,reporter,w),operator=await operatorFixture();
  await db.prepare(`INSERT INTO moderation_owner_policies(policy_revision,owner_operator_id,enrollment_admission_id,session_rowid_floor)
   SELECT COALESCE((SELECT MAX(policy_revision) FROM moderation_owner_policies),0)+1,?,enrollment_admission_id,
   COALESCE((SELECT MAX(rowid) FROM moderation_operator_access_sessions),0)
   FROM moderation_operator_enrollment_admissions a JOIN moderation_operator_enrollment_requests e USING(enrollment_request_id)
   WHERE e.target_operator_id=? ORDER BY a.rowid DESC LIMIT 1`).bind(operator.operatorId,operator.operatorId).run();
  const databaseFailures:string[]=[];
  const observedDB=new Proxy(db,{get(target,name){
    if(name==='batch')return async(statements:D1PreparedStatement[])=>{
      try{return await target.batch(statements);}catch(error){databaseFailures.push(String(error));throw error;}
    };
    const value=Reflect.get(target,name);return typeof value==='function'?value.bind(target):value;
  }});
  const local:GroupOperatorEnvironment={...operator.local,db:observedDB,group:{runtimeEnabled:'YES',
    caseHmacKey:crypto.getRandomValues(new Uint8Array(32)),reviewEvidence:review}};
  let counter=0;
  const request=(path:string,body?:string,headers?:Record<string,string>)=>operator.request(path,'POST',body,headers);
  const dispatch=(path:string,body?:string,headers?:Record<string,string>)=>routeGroupOperator(request(path,body,headers),local);
  async function issue(path:string):Promise<Challenge> {
    const response=await dispatch(path);expect(response.status,(await response.clone().text())+' '+databaseFailures.join('\n')).toBe(202);
    return response.json();
  }
  async function prove(challenge:Challenge,invalidSignature=false,headers?:Record<string,string>) {
    return dispatch(challenge.assertionPath,await operator.assertion(challenge.challenge,{counter:++counter,invalidSignature}),headers);
  }
  async function queue() {
    const response=await prove(await issue('/operator/group/v1/queue'));
    expect(response.status,(await response.clone().text())+' '+databaseFailures.join('\n')).toBe(200);
    return (await response.json() as {cases:{caseReference:string;revision:number;outcome:string;evidenceAvailable:number}[]}).cases;
  }
  async function read(reference:string) {
    const challenge=await issue(`/operator/group/v1/cases/${reference}/read`),response=await prove(challenge);
    expect(response.status,(response.status===200?'':await response.clone().text())+' '+databaseFailures.join('\n')).toBe(200);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(image);
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(response.headers.get('X-Moderation-Source-SHA256')).toBe(challenge.sourceSHA256);
    return response.headers.get('X-Moderation-Read-Receipt')!;
  }
  async function status(actor=reporter,path=report.path) {return send(await signed(actor,path),settings);}
  return {owner,reporter,w,report,operator,local,databaseFailures,dispatch,issue,prove,queue,read,status,
    anotherReport:()=>submittedReport(owner,reporter,w)};
}
const count=async(table:string)=>(await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{n:number}>())!.n;

beforeEach(async()=>{
  await reset();
  await applyD1Migrations(db,(env as unknown as {TEST_MIGRATIONS:D1Migration[]}).TEST_MIGRATIONS);
  await db.prepare(`UPDATE personal_staging_runtime_gate SET generation=generation+1,media_enabled=1,
    apns_enabled=1,report_ingestion_enabled=1,updated_at=unixepoch() WHERE singleton=1 AND generation=0`).run();
});

describe('group operator selected-evidence workflow',()=>{
  it('lists a received case, reads submitted evidence, restricts only its photo and exposes the reporter reply',async()=>{
    const f=await fixture(),cases=await f.queue();expect(cases).toHaveLength(1);
    const c=cases[0]!;expect(c).toMatchObject({revision:0,outcome:'received',evidenceAvailable:1});
    expect(JSON.stringify(cases)).not.toContain(f.report.id);
    expect(JSON.stringify(cases)).not.toMatch(/objectKey|ciphertext|reporter/);
    expect((await f.status()).data.report).toMatchObject({id:f.report.id,outcome:'received',revision:0,replyTemplate:null});
    const receipt=await f.read(c.caseReference),challenge=await f.issue(`/operator/group/v1/cases/${c.caseReference}/photo/${receipt}`);
    const decided=await f.prove(challenge);expect(decided.status,(await decided.clone().text())+' '+f.databaseFailures.join('\n')).toBe(200);
    expect(await decided.json()).toMatchObject({revision:1,outcome:'photo',replyAvailable:true});
    expect(await db.prepare('SELECT target_kind,target_id,space_id,active FROM group_moderation_restrictions').first())
      .toEqual({target_kind:'photo',target_id:f.report.momentId,space_id:f.w.windowId,active:1});
    expect((await f.status()).data.report).toMatchObject({id:f.report.id,outcome:'photo',revision:1,replyTemplate:'review_restricted_v1'});
    expect(await count('group_moderation_receipts')).toBe(1);expect(await count('group_moderation_decisions')).toBe(1);
  });
  it('burns an invalid signature once without reading evidence or consuming a successful proof',async()=>{
    const f=await fixture(),c=(await f.queue())[0]!,challenge=await f.issue(`/operator/group/v1/cases/${c.caseReference}/read`);
    let calls=0;f.local.group.reviewEvidence=async input=>{calls++;return review(input);};
    expect((await f.prove(challenge,true)).status).toBeGreaterThanOrEqual(400);
    expect(await count('group_moderation_attempts')).toBe(2);expect(await count('group_moderation_consumptions')).toBe(1);
    expect((await f.prove(challenge)).status).toBe(409);expect(calls).toBe(0);expect(await count('group_moderation_receipts')).toBe(0);
  });
  for(const change of ['source','operator'] as const)it(`withdraws a read when ${change} is revoked after awaited audit`,async()=>{
    const f=await fixture(),c=(await f.queue())[0]!,challenge=await f.issue(`/operator/group/v1/cases/${c.caseReference}/read`);
    f.local.group.reviewEvidence=async input=>{
      await input.audit('started');
      if(change==='source')await db.prepare("UPDATE group_reports SET state='expired',expired_at=unixepoch() WHERE id=?").bind(f.report.id).run();
      else await db.prepare("INSERT INTO moderation_operator_state_events(operator_id,event_type) VALUES (?,'revoked')").bind(f.operator.operatorId).run();
      await input.readCurrentSource();throw Error('must not reach image');
    };
    const response=await f.prove(challenge);expect(response.status).toBeGreaterThanOrEqual(400);
    expect(response.headers.get('X-Moderation-Read-Receipt')).toBeNull();expect(await count('group_moderation_receipts')).toBe(0);
    expect(await count('group_moderation_consumptions')).toBe(2);
  });
  it('cannot apply a read receipt to a different case',async()=>{
    const f=await fixture(),first=(await f.queue())[0]!,receipt=await f.read(first.caseReference);
    await f.anotherReport();const second=(await f.queue()).find(c=>c.caseReference!==first.caseReference)!;
    expect((await f.dispatch(`/operator/group/v1/cases/${second.caseReference}/photo/${receipt}`)).status).toBe(409);
    expect(await count('group_moderation_decisions')).toBe(0);
  });
  it('rejects the second decision signed against a stale case revision',async()=>{
    const f=await fixture(),c=(await f.queue())[0]!,receipt=await f.read(c.caseReference);
    const first=await f.issue(`/operator/group/v1/cases/${c.caseReference}/no_action/${receipt}`);
    const stale=await f.issue(`/operator/group/v1/cases/${c.caseReference}/photo/${receipt}`);
    expect((await f.prove(first)).status).toBe(200);expect((await f.prove(stale)).status).toBe(409);
    expect(await count('group_moderation_decisions')).toBe(1);expect(await count('group_moderation_restrictions')).toBe(0);
    expect((await f.status()).data.report).toMatchObject({outcome:'no_action',revision:1,replyTemplate:'review_no_action_v1'});
  });
  it('rolls back proof, decision, restriction and reply when restriction persistence fails',async()=>{
    const f=await fixture(),c=(await f.queue())[0]!,receipt=await f.read(c.caseReference);
    const challenge=await f.issue(`/operator/group/v1/cases/${c.caseReference}/photo/${receipt}`);
    await db.exec("CREATE TRIGGER synthetic_group_restriction_failure BEFORE INSERT ON group_moderation_restrictions BEGIN SELECT RAISE(ABORT,'synthetic write failure'); END;");
    expect((await f.prove(challenge)).status).toBe(409);
    expect(await count('group_moderation_consumptions')).toBe(2);expect(await count('group_moderation_decisions')).toBe(0);
    expect(await count('group_moderation_restrictions')).toBe(0);
    expect((await f.status()).data.report).toMatchObject({outcome:'received',revision:0,replyTemplate:null});
    expect((await f.prove(challenge)).status).toBe(409);
  });
  it('binds the challenge to the exact Access session, not only the same operator',async()=>{
    const f=await fixture(),c=(await f.queue())[0]!,challenge=await f.issue(`/operator/group/v1/cases/${c.caseReference}/read`);
    const other=await f.operator.sessionToken(600);
    expect((await f.prove(challenge,false,{'Cf-Access-Jwt-Assertion':other})).status).toBe(409);
    expect(await count('group_moderation_receipts')).toBe(0);
  });
  it('keeps status scoped to the original reporter device and window after leaving, with intake OFF',async()=>{
    const f=await fixture(),c=(await f.queue())[0]!,receipt=await f.read(c.caseReference);
    expect((await f.prove(await f.issue(`/operator/group/v1/cases/${c.caseReference}/no_action/${receipt}`))).status).toBe(200);
    expect((await f.status(f.owner)).status).toBe(404);expect((await f.status(await person())).status).toBe(404);
    expect((await f.status(await person(f.reporter.identity))).status).toBe(404);
    expect((await f.status(f.reporter,`/v3/group-windows/${randomBase64url(16)}/reports/${f.report.id}/status`)).status).toBe(404);
    await db.prepare("UPDATE group_members SET state='left' WHERE space_id=? AND person_id=?").bind(f.w.windowId,f.reporter.id).run();
    await db.prepare(`UPDATE personal_staging_runtime_gate SET generation=generation+1,media_enabled=0,apns_enabled=0,
      report_ingestion_enabled=0,updated_at=unixepoch() WHERE singleton=1`).run();
    const result=await send(await signed(f.reporter,f.report.path),{...settings,GROUP_RUNTIME_ENABLED:'NO',MOMENT_RUNTIME_ENABLED:'NO',
      GROUP_REPORT_RUNTIME_ENABLED:'NO',REPORT_INGESTION_RUNTIME_ENABLED:'NO'});
    expect(result.status).toBe(200);expect(result.data.report.replyTemplate).toBe('review_no_action_v1');
    expect(JSON.stringify(result.data)).not.toMatch(/objectKey|ciphertext|sourceSHA|person_id|reporterParticipant/);
    expect((await send(await signed(f.reporter,f.report.path),{...settings,GROUP_MODERATION_RUNTIME_ENABLED:'NO'})).status).toBe(503);
    await db.prepare("UPDATE group_person_devices SET state='revoked',revoked_at=unixepoch() WHERE id=?").bind(f.reporter.deviceId).run();
    expect((await f.status()).status).toBe(401);
  });
  it('keeps the group operator runtime OFF without changing or consuming authority',async()=>{
    const f=await fixture();f.local.group.runtimeEnabled='NO';
    expect((await f.dispatch('/operator/group/v1/queue')).status).toBe(503);
    expect(await count('group_moderation_challenges')).toBe(0);expect(await count('group_moderation_cases')).toBe(0);
  });
  it('pages cases using a signed cursor without repeating or losing older cases',async()=>{
    const f=await fixture();await f.anotherReport();const all=await f.queue();expect(all).toHaveLength(2);
    const first=await db.prepare('SELECT rowid AS cursor FROM group_moderation_cases WHERE case_reference=?').bind(all[0]!.caseReference).first<{cursor:number}>();
    const response=await f.prove(await f.issue(`/operator/group/v1/queue/${first!.cursor}`));expect(response.status).toBe(200);
    const page=await response.json() as {cases:Array<{caseReference:string}>;nextAfter:number};
    expect(page.cases.map(c=>c.caseReference)).toEqual([all[1]!.caseReference]);expect(page.nextAfter).toBeGreaterThan(first!.cursor);
  });
  it('requires explicit release instead of silently clearing a restriction with no_action',async()=>{
    const f=await fixture(),c=(await f.queue())[0]!,receipt=await f.read(c.caseReference);
    expect((await f.prove(await f.issue(`/operator/group/v1/cases/${c.caseReference}/window/${receipt}`))).status).toBe(200);
    const fresh=await f.read(c.caseReference);
    expect((await f.dispatch(`/operator/group/v1/cases/${c.caseReference}/no_action/${fresh}`)).status).toBe(409);
    expect(await db.prepare('SELECT active FROM group_moderation_restrictions WHERE case_reference=?').bind(c.caseReference).first()).toEqual({active:1});
  });
  for(const action of ['window','person'] as const)it(`purges expired evidence metadata while preserving ${action} restriction until fresh release`,async()=>{
    const f=await fixture(),c=(await f.queue())[0]!,receipt=await f.read(c.caseReference);
    expect((await f.prove(await f.issue(`/operator/group/v1/cases/${c.caseReference}/${action}/${receipt}`))).status).toBe(200);
    const evidence=await db.prepare('SELECT object_key,content_expires_at FROM group_reports WHERE id=?').bind(f.report.id)
      .first<{object_key:string;content_expires_at:number}>();expect(evidence).not.toBeNull();
    const disabled={...settings,GROUP_REPORT_RUNTIME_ENABLED:'NO',REPORT_INGESTION_RUNTIME_ENABLED:'NO'};
    // Cleanup first expires/deletes the evidence after seven days; metadata
    // then reaches its existing two-day grace period on a later invocation.
    await runGroupReportCleanup(disabled,evidence!.content_expires_at+1);
    expect(await settings.MODERATION_MEDIA!.get(evidence!.object_key)).toBeNull();
    await runGroupReportCleanup(disabled,evidence!.content_expires_at+172802);
    expect(await db.prepare('SELECT id FROM group_reports WHERE id=?').bind(f.report.id).first()).toBeNull();
    expect((await f.status()).status).toBe(404);
    expect(await db.prepare('SELECT active FROM group_moderation_restrictions WHERE case_reference=?').bind(c.caseReference).first()).toEqual({active:1});
    expect((await f.queue()).find(k=>k.caseReference===c.caseReference)).toMatchObject({outcome:action,revision:1,evidenceAvailable:0});
    const released=await f.prove(await f.issue(`/operator/group/v1/cases/${c.caseReference}/release`));
    expect(released.status,(await released.clone().text())+' '+f.databaseFailures.join('\n')).toBe(200);
    expect(await released.json()).toMatchObject({outcome:'release',revision:2,replyAvailable:false});
    expect(await db.prepare('SELECT active FROM group_moderation_restrictions WHERE case_reference=?').bind(c.caseReference).first()).toEqual({active:0});
    expect((await f.status()).status).toBe(404);
  });
});
