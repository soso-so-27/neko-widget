import { base64urlEncode } from './encoding';
import { authenticateCloudflareAccessRequest,type AuthenticatedModerationOperatorAccess as Access } from './moderation-operator-auth';
import { actorSQL,guard,admitSession,type Actor } from './moderation-operator-identity';
import { prepareModerationOperatorWebAuthnRequest } from './moderation-operator-request';
import { verifyPreparedModerationOperatorWebAuthnAssertion } from './moderation-operator-webauthn';
import type { LocalModerationTriageEnvironment } from './moderation-operator-triage-local';
import { groupCaseReference,groupModerationSHA,groupSourceSHA,groupSourceSQL,readGroupModerationSource,type GroupModerationSource } from './group-moderation-source';
import { groupModerationConsole } from './group-moderation-console';
import {groupReceiptNumber} from './group-report-number';

export interface GroupReviewHost {
 (input:Readonly<{source:GroupModerationSource;sourceSHA256:string;signal:AbortSignal;
 readCurrentSource():Promise<GroupModerationSource>;audit(phase:'started'|'disclosure_ready'):Promise<void>}>):Promise<Uint8Array>;
}
export interface GroupOperatorConfiguration {runtimeEnabled:string;caseHmacKey:Uint8Array;reviewEvidence:GroupReviewHost}
export interface GroupOperatorEnvironment extends LocalModerationTriageEnvironment {group:GroupOperatorConfiguration}
interface Challenge {
 id:string;operator_id:string;credential_id_sha256:string;enrollment_admission_id:string;access_session_sha256:string;
 policy_revision:number;value_sha256:string;case_reference:string|null;case_revision:number|null;source_sha256:string|null;
 receipt_id:string|null;action:string;expires_at:number;queue_after:number;
}
class Failure extends Error {constructor(readonly status:number,readonly code='group_operator_unavailable'){super(code);}}
const fail=(status=409,code?:string):never=>{throw new Failure(status,code);};
const headers={'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'};
const json=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers});
const ref='[0-9a-f]{64}',uuid='[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const issuePattern=new RegExp(`^/operator/group/v1/cases/(${ref})/(read|release|(?:no_action|photo|person|window)/(${uuid}))$`,'u');
const queuePattern=/^\/operator\/group\/v1\/queue(?:\/([0-9]{1,15}))?$/u;
const assertionPattern=new RegExp(`^/operator/group/v1/assertions/(${uuid})$`,'u');
function policyGuard(env:GroupOperatorEnvironment,access:Access,actor:Actor,revision?:number):D1PreparedStatement {
 return env.db.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM moderation_owner_current_policies p
 JOIN moderation_operator_access_sessions s ON s.access_session_sha256=? AND s.operator_id=p.owner_operator_id
 WHERE p.owner_operator_id=? AND p.enrollment_admission_id=? AND (? IS NULL OR p.policy_revision=?)
 AND s.rowid>p.session_rowid_floor AND s.token_expires_at>unixepoch()) THEN 'true' ELSE 'denied' END)`)
 .bind(access.accessSessionSHA256,actor.operator_id,actor.enrollment_admission_id,revision??null,revision??null);
}
function auth(env:GroupOperatorEnvironment,access:Access,actor:Actor,revision?:number):D1PreparedStatement[] {
 return [guard(env.db,access,actor),admitSession(env.db,access,actor),policyGuard(env,access,actor,revision)];
}
function current(env:GroupOperatorEnvironment,access:Access,actor:Actor,c:Challenge,needsLive=true):D1PreparedStatement[] {
 const checks=[...auth(env,access,actor,c.policy_revision),env.db.prepare(`SELECT json(CASE WHEN EXISTS(
 SELECT 1 FROM group_moderation_challenges WHERE id=? AND operator_id=? AND credential_id_sha256=?
 AND enrollment_admission_id=? AND access_session_sha256=? AND expires_at>unixepoch()) THEN 'true' ELSE 'denied' END)`)
 .bind(c.id,actor.operator_id,actor.credential_id_sha256,actor.enrollment_admission_id,access.accessSessionSHA256)];
 if(c.case_reference)checks.push(env.db.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM group_moderation_cases
 WHERE case_reference=? AND revision=?) THEN 'true' ELSE 'denied' END)`).bind(c.case_reference,c.case_revision));
 if(needsLive&&c.case_reference&&c.action!=='release')checks.push(env.db.prepare(`SELECT json(CASE WHEN EXISTS(${groupSourceSQL}) THEN 'true' ELSE 'denied' END)`).bind(c.case_reference));
 return checks;
}
async function issue(env:GroupOperatorEnvironment,access:Access,actor:Actor,action:string,reference?:string,receipt?:string,queueAfter=0):Promise<Response> {
 const policy=await env.db.prepare(`SELECT policy_revision FROM moderation_owner_current_policies WHERE owner_operator_id=? AND enrollment_admission_id=?`)
 .bind(actor.operator_id,actor.enrollment_admission_id).first<{policy_revision:number}>();if(!policy)fail(403);
 const k=reference?await env.db.prepare('SELECT revision,outcome FROM group_moderation_cases WHERE case_reference=?').bind(reference).first<{revision:number;outcome:string}>():null;
 if(reference&&!k)fail(404);if(action==='release'&&(!k||!['window','person','photo'].includes(k.outcome)))fail();
 if(action==='no_action'&&k&&['window','person','photo'].includes(k.outcome))fail(409,'use_explicit_release');
 const source=reference&&action!=='release'?await readGroupModerationSource(env.db,reference):null;
 const sourceSHA=source?await groupSourceSHA(source):null;
 if(receipt){
  const valid=await env.db.prepare(`SELECT 1 AS ok FROM group_moderation_receipts r JOIN group_moderation_challenges c ON c.id=r.challenge_id
   WHERE r.id=? AND r.expires_at>unixepoch() AND c.case_reference=? AND c.case_revision=? AND c.source_sha256=?
   AND c.operator_id=? AND c.access_session_sha256=?`).bind(receipt,reference,k!.revision,sourceSHA,actor.operator_id,access.accessSessionSHA256).first();if(!valid)fail();
 }
 const id=crypto.randomUUID(),random=crypto.getRandomValues(new Uint8Array(32));
 const expires=Math.min(Math.floor(Date.now()/1000)+300,access.expiresAt,source?.metadata.contentExpiresAt??Number.MAX_SAFE_INTEGER);
 await env.db.batch([...auth(env,access,actor,policy!.policy_revision),env.db.prepare(`INSERT INTO group_moderation_challenges
 (id,operator_id,credential_id_sha256,enrollment_admission_id,access_session_sha256,policy_revision,value_sha256,
 case_reference,case_revision,source_sha256,receipt_id,action,expires_at,queue_after) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
 .bind(id,actor.operator_id,actor.credential_id_sha256,actor.enrollment_admission_id,access.accessSessionSHA256,policy!.policy_revision,
 await groupModerationSHA(random),reference??null,k?.revision??null,sourceSHA,receipt??null,action,expires,queueAfter)]);
 return json({challengeId:id,challenge:base64urlEncode(random),rpId:env.rpId,userVerification:'required',
 assertionPath:`/operator/group/v1/assertions/${id}`,action,expiresAt:expires,caseReference:reference??null,sourceSHA256:sourceSHA},202);
}
async function queue(env:GroupOperatorEnvironment,access:Access,actor:Actor,c:Challenge):Promise<Response> {
 const rows=await env.db.prepare(`SELECT r.report_id AS id FROM group_report_records r WHERE NOT EXISTS
 (SELECT 1 FROM group_moderation_cases c WHERE c.report_id=r.report_id) ORDER BY r.committed_at,r.report_id LIMIT 50`).all<{id:string}>();
 for(const row of rows.results){
  const reference=await groupCaseReference(row.id,env.group.caseHmacKey);
  await groupReceiptNumber(env.db,row.id);
  await env.db.batch([...current(env,access,actor,c),env.db.prepare(`INSERT INTO group_moderation_cases(case_reference,report_id,key_version,revision,outcome)
   SELECT ?,report_id,1,revision,outcome FROM group_report_records WHERE report_id=?
   ON CONFLICT(report_id) DO NOTHING`).bind(reference,row.id)]);
 }
 const unnumbered=await env.db.prepare(`SELECT n.report_id FROM group_report_numbers n JOIN group_moderation_cases c USING(report_id)
  WHERE n.receipt_number IS NULL AND c.rowid>? ORDER BY c.rowid LIMIT 100`).bind(c.queue_after).all<{report_id:string}>();
 for(const row of unnumbered.results)await groupReceiptNumber(env.db,row.report_id);
 const result=await env.db.batch([...current(env,access,actor,c),env.db.prepare(`SELECT c.rowid AS cursor,c.case_reference AS caseReference,c.revision,c.outcome,
 n.receipt_number AS receiptNumber,e.origin AS decisionOrigin,COALESCE(k.committed_at,c.created_at) AS receivedAt,k.evidence_expires_at AS evidenceExpiresAt,
 COALESCE((r.state='committed' AND r.content_expires_at>unixepoch() AND NOT EXISTS(SELECT 1 FROM group_report_object_deletions d WHERE d.report_id=r.id)),0) AS evidenceAvailable
 FROM group_moderation_cases c JOIN group_report_records k ON k.report_id=c.report_id
 JOIN group_report_numbers n ON n.report_id=c.report_id
 LEFT JOIN group_report_events e ON e.report_id=k.report_id AND e.revision=k.revision
 LEFT JOIN group_reports r ON r.id=c.report_id WHERE c.rowid>? ORDER BY c.rowid LIMIT 100`).bind(c.queue_after)]);
 const cases=result.at(-1)!.results as Array<{cursor:number;[key:string]:unknown}>;
 // A signed monotonic cursor keeps older cases and release operations reachable.
 return json({cases,nextAfter:cases.length?cases.at(-1)!.cursor:null});
}
async function disclose(request:Request,env:GroupOperatorEnvironment,access:Access,actor:Actor,c:Challenge):Promise<Response> {
 const controller=new AbortController(),abort=()=>controller.abort();request.signal.addEventListener('abort',abort,{once:true});
 if(request.signal.aborted)controller.abort();const deadline=Date.now()+60000;
 const active=()=>{if(controller.signal.aborted||Date.now()>=deadline)fail(503);};
 const checks=()=>[...current(env,access,actor,c),env.db.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM group_moderation_consumptions WHERE challenge_id=?) THEN 'true' ELSE 'denied' END)`).bind(c.id)];
 const readCurrentSource=async()=>{
  active();await env.db.batch(checks());const s=await readGroupModerationSource(env.db,c.case_reference!);
  if(await groupSourceSHA(s)!==c.source_sha256)fail();await env.db.batch(checks());active();return s;
 };
 let jpeg:Uint8Array|undefined,timer:ReturnType<typeof setTimeout>|undefined;
 try {
  const source=await readCurrentSource();
  const operation=env.group.reviewEvidence(Object.freeze({source,sourceSHA256:c.source_sha256!,signal:controller.signal,readCurrentSource,
   audit:async(phase:'started'|'disclosure_ready')=>{active();if(!['started','disclosure_ready'].includes(phase))fail();
    await env.db.batch([...checks(),env.db.prepare('INSERT INTO group_moderation_read_events(challenge_id,phase) VALUES (?,?)').bind(c.id,phase)]);active();}}));
  const owned=Promise.resolve(operation).then(value=>{if(controller.signal.aborted||Date.now()>=deadline){value?.fill(0);fail(503);}return value;});
  jpeg=await Promise.race([owned,new Promise<never>((_,reject)=>{timer=setTimeout(()=>{controller.abort();reject(new Failure(503));},Math.max(1,deadline-Date.now()));})]);
  if(!(jpeg instanceof Uint8Array)||jpeg.length<4||jpeg.length>950244||jpeg[0]!==255||jpeg[1]!==216||jpeg.at(-2)!==255||jpeg.at(-1)!==217)fail(503);
  await readCurrentSource();const receipt=crypto.randomUUID(),expiry=Math.min(access.expiresAt,source.metadata.contentExpiresAt);
  await env.db.batch([...checks(),env.db.prepare(`INSERT INTO group_moderation_read_events(challenge_id,phase) VALUES (?,'delivered')`).bind(c.id),
   env.db.prepare('INSERT INTO group_moderation_receipts VALUES (?,?,?)').bind(receipt,c.id,expiry)]);active();
  return new Response(jpeg.slice().buffer,{headers:{...headers,'Content-Type':'image/jpeg','X-Moderation-Read-Receipt':receipt,
   'X-Moderation-Source-SHA256':c.source_sha256!,'X-Moderation-Review-Expires-At':String(expiry)}});
 }finally{clearTimeout(timer);controller.abort();request.signal.removeEventListener('abort',abort);jpeg?.fill(0);}
}
async function decide(env:GroupOperatorEnvironment,access:Access,actor:Actor,c:Challenge,consume:D1PreparedStatement):Promise<Response> {
 const target=await env.db.prepare(`SELECT r.space_id,r.moment_id,m.person_id FROM group_moderation_cases k JOIN group_reports r ON r.id=k.report_id
 JOIN group_members m ON m.space_id=r.space_id AND m.participant_id=r.accused_participant_id WHERE k.case_reference=?`)
 .bind(c.case_reference).first<{space_id:string;moment_id:string;person_id:string}>();if(!target&&c.action!=='release')fail();
 if(c.action!=='release'&&await groupSourceSHA(await readGroupModerationSource(env.db,c.case_reference!))!==c.source_sha256)fail();
 const id=crypto.randomUUID(),revision=c.case_revision!+1,reply=c.action==='no_action'?'review_no_action_v1':c.action==='release'?'review_released_v1':'review_restricted_v1';
 const statements=[...current(env,access,actor,c),consume,
  env.db.prepare(`INSERT INTO group_moderation_decisions(id,challenge_id,case_reference,revision,outcome,reply_template) VALUES (?,?,?,?,?,?)`)
   .bind(id,c.id,c.case_reference,revision,c.action,reply),
  env.db.prepare(`UPDATE group_moderation_restrictions SET active=0,revision=revision+1,updated_at=unixepoch()
   WHERE active=1 AND (case_reference=? OR case_reference='deadline:'||(SELECT report_id FROM group_moderation_cases WHERE case_reference=?))`)
   .bind(c.case_reference,c.case_reference)];
 if(['window','person','photo'].includes(c.action))statements.push(env.db.prepare(`INSERT INTO group_moderation_restrictions
 (id,case_reference,space_id,target_kind,target_id,active,revision,created_at,updated_at) VALUES (?,?,?,?,?,1,1,unixepoch(),unixepoch())
 ON CONFLICT(case_reference,space_id,target_kind,target_id) DO UPDATE SET active=1,revision=revision+1,updated_at=unixepoch()`)
 .bind(crypto.randomUUID(),c.case_reference,target!.space_id,c.action,c.action==='window'?target!.space_id:c.action==='person'?target!.person_id:target!.moment_id));
 // The decision trigger updates the durable record and local case revision in
 // this same transaction. This remains true after the evidence row is gone.
 statements.push(env.db.prepare(`SELECT EXISTS(SELECT 1 FROM group_report_records r JOIN group_moderation_cases c ON c.report_id=r.report_id
 WHERE c.case_reference=? AND r.reporter_person_id IS NOT NULL AND r.reporter_device_id IS NOT NULL) AS available`).bind(c.case_reference));
 const saved=await env.db.batch(statements),available=(saved.at(-1)!.results[0] as {available:number}).available===1;
 return json({caseReference:c.case_reference,revision,outcome:c.action,replyTemplate:reply,replyAvailable:available});
}
async function prove(request:Request,env:GroupOperatorEnvironment,access:Access,actor:Actor,id:string):Promise<Response> {
 const c=await env.db.prepare(`SELECT * FROM group_moderation_challenges WHERE id=? AND operator_id=? AND credential_id_sha256=?
 AND enrollment_admission_id=? AND access_session_sha256=? AND expires_at>unixepoch()`)
 .bind(id,actor.operator_id,actor.credential_id_sha256,actor.enrollment_admission_id,access.accessSessionSHA256).first<Challenge>();if(!c)fail();
 const prepared=await prepareModerationOperatorWebAuthnRequest(request,{expectedOrigin:env.origin,expectedRPID:env.rpId,
 expectedChallengeSHA256:c!.value_sha256,credential:{credentialIdSHA256:actor.credential_id_sha256,publicKeyCose:new Uint8Array(actor.public_key_cose),counter:actor.sign_count}});
 await env.db.batch([...current(env,access,actor,c!),env.db.prepare('INSERT INTO group_moderation_attempts(challenge_id,assertion_sha256) VALUES (?,?)').bind(id,prepared.assertionSHA256)]);
 const verified=await verifyPreparedModerationOperatorWebAuthnAssertion(prepared);
 const consume=env.db.prepare('INSERT INTO group_moderation_consumptions(challenge_id,assertion_sha256,authenticator_sign_count) VALUES (?,?,?)')
 .bind(id,verified.assertionSHA256,verified.newCounter);
 if(c!.action==='queue'||c!.action==='read'){
  await env.db.batch([...current(env,access,actor,c!),consume]);
  return c!.action==='queue'?queue(env,access,actor,c!):disclose(request,env,access,actor,c!);
 }
 return decide(env,access,actor,c!,consume);
}
/** Trusted local host only. No public Worker imports this operator router. */
export async function routeGroupOperator(request:Request,env:GroupOperatorEnvironment):Promise<Response> {
 if(env.environment!=='local'||env.runtimeEnabled!=='YES'||env.group.runtimeEnabled!=='YES'||env.group.caseHmacKey.byteLength!==32||typeof env.group.reviewEvidence!=='function')return json({error:'group_operator_disabled'},503);
 try{
  const url=new URL(request.url),origin=new URL(env.origin);
  if(origin.protocol!=='https:'||origin.origin!==env.origin||origin.hostname!==env.rpId||url.origin!==env.origin||url.search||url.hash)fail(403);
  let access:Access;try{access=await authenticateCloudflareAccessRequest(request,env.access);}catch{return json({error:'operator_authentication_required'},401);}
  const actor=await env.db.prepare(actorSQL).bind(access.operatorSubjectHmac,access.subjectHmacKeyVersion).first<Actor>();if(!actor)fail(403);
  await env.db.batch(auth(env,access,actor!));
  if(request.method==='GET'&&url.pathname==='/operator/group/console')return groupModerationConsole();
  if(request.method!=='POST'||request.headers.get('origin')!==env.origin)fail(403);
  const assertion=assertionPattern.exec(url.pathname);if(assertion)return await prove(request,env,access,actor!,assertion[1]!);
  if(request.body!==null)fail(400);
  const page=queuePattern.exec(url.pathname);if(page)return await issue(env,access,actor!,'queue',undefined,undefined,Number(page[1]??0));
  const match=issuePattern.exec(url.pathname);if(!match)fail(400);
  return await issue(env,access,actor!,match![2]!.split('/')[0]!,match![1],match![3]);
 }catch(error){return json({error:error instanceof Failure?error.code:'group_operator_unavailable'},error instanceof Failure?error.status:409);}
}
