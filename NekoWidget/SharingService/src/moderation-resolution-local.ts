import { base64urlEncode } from './encoding';
import { authenticateCloudflareAccessRequest, type AuthenticatedModerationOperatorAccess } from './moderation-operator-auth';
import { actorSQL, guard, admitSession, type Actor } from './moderation-operator-identity';
import { prepareModerationOperatorWebAuthnRequest } from './moderation-operator-request';
import { verifyPreparedModerationOperatorWebAuthnAssertion } from './moderation-operator-webauthn';
import type { LocalModerationOwnerEnvironment } from './moderation-owner-local';
import { readLocalModerationReviewSource, type LocalModerationReviewSource } from './moderation-review-source';
import { localModerationReviewSourceSHA256 } from './moderation-review-binding';

type Operation = 'hide' | 'release' | 'no_action';
interface Target { moment_id:string; space_id:string; key_epoch:number; ciphertext_sha256:string; committed_at:number; unreceived_expires_at:number }
interface State { event_id:string; operation:Operation; source_sha256:string }
interface Challenge {
 challenge_id:string; operation:Operation; expected_revision:number; source_sha256:string; binding_sha256:string;
 challenge_value_sha256:string; case_reference_hmac:string; case_reference_hmac_key_version:number;
 read_receipt_id:string|null; restriction_event_id:string|null;
}
const uuid='[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const pattern=new RegExp(`^/operator/resolution/v1/cases/([0-9a-f]{64})/([1-9][0-9]{0,9})/(state|(?:hide|release|no_action)/(${uuid})/(0|[1-9][0-9]{0,9}))(?:/assertions/(${uuid}))?$`,'u');
const headers={'Cache-Control':'no-store','Content-Type':'application/json; charset=utf-8','X-Content-Type-Options':'nosniff'};
const json=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers});
class ResolutionError extends Error { constructor(readonly status:number) {super('resolution_unavailable')} }
function fail(status=409):never {throw new ResolutionError(status)}
const digest=async(bytes:Uint8Array)=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',new Uint8Array(bytes).buffer))].map(v=>v.toString(16).padStart(2,'0')).join('');
// A linked album copy has its own lifetime. Clearing its overlay never changes
// the delivery's state/TTL or revives withdrawn records and readers.
const activeTargetSQL=`((m.state='committed' AND m.closed_at IS NULL AND m.unreceived_expires_at>unixepoch()
 AND NOT EXISTS(SELECT 1 FROM moment_object_deletions d WHERE d.object_key=m.object_key OR (d.object_type='moment' AND d.owner_id=m.id)))
 OR EXISTS(SELECT 1 FROM family_record_moments link JOIN family_records record ON record.space_id=link.space_id AND record.id=link.photo_id
  WHERE link.moment_id=m.id AND link.space_id=m.space_id AND record.kind='photo' AND record.state='active' AND record.key_epoch=m.key_epoch))`;

async function target(db:D1Database,reference:string,version:number):Promise<Target|null> {
 return db.prepare(`SELECT m.id AS moment_id,m.space_id,m.key_epoch,m.ciphertext_sha256,m.committed_at,m.unreceived_expires_at
  FROM moments m WHERE ${activeTargetSQL}
  AND EXISTS(SELECT 1 FROM moment_spaces WHERE space_id=m.space_id AND state='active')
  AND (EXISTS(SELECT 1 FROM moderation_resolution_case_states s WHERE s.case_reference_hmac=? AND s.case_reference_hmac_key_version=? AND s.moment_id=m.id)
   OR (NOT EXISTS(SELECT 1 FROM moderation_resolution_events e JOIN moderation_resolution_challenges c USING(challenge_id)
      WHERE c.case_reference_hmac=?)
    AND EXISTS(SELECT 1 FROM moderation_operator_versioned_case_references ref JOIN moment_reports r ON r.id=ref.report_id
      WHERE ref.case_reference_hmac=? AND ref.case_reference_hmac_key_version=? AND r.moment_id=m.id)))`)
  .bind(reference,version,reference,reference,version).first<Target>();
}
async function caseState(db:D1Database,reference:string,version:number) {return db.prepare(`SELECT event_id,operation,source_sha256 FROM moderation_resolution_case_states WHERE case_reference_hmac=? AND case_reference_hmac_key_version=?`).bind(reference,version).first<State>();}
async function momentState(db:D1Database,id:string) {return await db.prepare(`SELECT revision,hidden FROM moderation_moment_states WHERE moment_id=?`).bind(id).first<{revision:number;hidden:number}>()??{revision:0,hidden:0};}
function currentGuard(db:D1Database,id:string,access:AuthenticatedModerationOperatorAccess,actor:Actor) {
 return db.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM moderation_resolution_current_challenges WHERE challenge_id=?
  AND operator_id=? AND credential_id_sha256=? AND enrollment_admission_id=? AND access_session_sha256=?) THEN 'true' ELSE 'denied' END)`)
  .bind(id,actor.operator_id,actor.credential_id_sha256,actor.enrollment_admission_id,access.accessSessionSHA256);
}
function sourceGuard(db:D1Database,s:LocalModerationReviewSource) {
 const m=s.metadata;
 return db.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM moment_reports r JOIN moment_report_tombstones t ON t.report_id=r.id
  JOIN moderation_operator_versioned_case_references ref ON ref.report_id=r.id
  WHERE ref.case_reference_hmac=? AND ref.case_reference_hmac_key_version=? AND r.id=? AND r.object_key=? AND r.moment_id=?
   AND r.reporter_participant_id=? AND r.reason_code=? AND r.moderation_key_id=? AND r.ciphertext_size=? AND r.ciphertext_sha256=?
   AND r.committed_at=? AND r.content_expires_at=? AND r.state='committed' AND r.closed_at IS NULL AND r.content_expires_at>unixepoch()
   AND t.content_deleted_at IS NULL AND t.committed_at=r.committed_at AND t.content_expires_at=r.content_expires_at
   AND NOT EXISTS(SELECT 1 FROM moment_object_deletions d WHERE d.object_key=r.object_key OR (d.object_type='report' AND d.owner_id=r.id))) THEN 'true' ELSE 'denied' END)`)
  .bind(s.caseReferenceHmac,s.caseReferenceHmacKeyVersion,m.reportId,s.objectKey,m.momentId,m.reporterParticipantId,m.reasonCode,m.moderationKeyId,m.ciphertextSize,m.ciphertextSHA256,m.committedAt,m.contentExpiresAt);
}
async function issue(env:LocalModerationOwnerEnvironment,access:AuthenticatedModerationOperatorAccess,actor:Actor,
 reference:string,version:number,operation:Operation,identity:string,revision:number,path:string,policy:number) {
 const t=await target(env.db,reference,version); if(!t)fail();
 const previous=await caseState(env.db,reference,version), effective=await momentState(env.db,t.moment_id);
 if(effective.revision!==revision||previous?.operation==='no_action')fail();
 let sourceSHA:string;
 if(operation==='release') {
  if(previous?.operation!=='hide'||previous.event_id!==identity)fail();
  sourceSHA=previous.source_sha256;
 } else {
  if(previous?.operation==='hide')fail();
  const s=await readLocalModerationReviewSource(env.db,{caseReferenceHmac:reference,caseReferenceHmacKeyVersion:version});
  if(!s||s.metadata.momentId!==t.moment_id)fail();
  sourceSHA=await localModerationReviewSourceSHA256(s);
 }
 const binding=await digest(new TextEncoder().encode(JSON.stringify(['NW.MODERATION-RESOLUTION.v1',reference,version,operation,identity,revision,t,sourceSHA])));
 const random=crypto.getRandomValues(new Uint8Array(32)),id=crypto.randomUUID();
 const result=await env.db.batch([guard(env.db,access,actor),admitSession(env.db,access,actor),
  env.db.prepare(`INSERT INTO moderation_resolution_challenges(challenge_id,policy_revision,operator_id,credential_id_sha256,enrollment_admission_id,
   access_session_sha256,challenge_value_sha256,case_reference_hmac,case_reference_hmac_key_version,operation,expected_revision,
   restriction_event_id,read_receipt_id,binding_sha256,source_sha256,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,MIN(unixepoch()+300,?)) RETURNING expires_at`)
   .bind(id,policy,actor.operator_id,actor.credential_id_sha256,actor.enrollment_admission_id,access.accessSessionSHA256,await digest(random),reference,version,
    operation,revision,operation==='release'?identity:null,operation==='release'?null:identity,binding,sourceSHA,access.expiresAt),
  env.db.prepare(`INSERT INTO moderation_resolution_scopes VALUES(?,?,?,?,?,?,?)`).bind(id,t.moment_id,t.space_id,t.key_epoch,t.ciphertext_sha256,t.committed_at,t.unreceived_expires_at),
  currentGuard(env.db,id,access,actor)]);
 return json({challengeId:id,challenge:base64urlEncode(random),assertionPath:`${path}/assertions/${id}`,caseReferenceHmac:reference,
  bindingSHA256:binding,sourceSHA256:sourceSHA,operation,expectedRevision:revision,rpId:env.rpId,userVerification:'required',
  expiresAt:(result[2]!.results[0] as {expires_at:number}).expires_at},202);
}
async function prove(request:Request,env:LocalModerationOwnerEnvironment,access:AuthenticatedModerationOperatorAccess,actor:Actor,
 reference:string,version:number,operation:Operation,identity:string,revision:number,id:string) {
 const c=await env.db.prepare(`SELECT * FROM moderation_resolution_current_challenges WHERE challenge_id=? AND case_reference_hmac=?
  AND case_reference_hmac_key_version=? AND operation=? AND expected_revision=? AND read_receipt_id IS ? AND restriction_event_id IS ?
  AND operator_id=? AND credential_id_sha256=? AND enrollment_admission_id=? AND access_session_sha256=?`)
  .bind(id,reference,version,operation,revision,operation==='release'?null:identity,operation==='release'?identity:null,
   actor.operator_id,actor.credential_id_sha256,actor.enrollment_admission_id,access.accessSessionSHA256).first<Challenge>();
 if(!c)fail();
 const prepared=await prepareModerationOperatorWebAuthnRequest(request,{expectedOrigin:env.origin,expectedRPID:env.rpId,
  expectedChallengeSHA256:c.challenge_value_sha256,credential:{credentialIdSHA256:actor.credential_id_sha256,publicKeyCose:new Uint8Array(actor.public_key_cose),counter:actor.sign_count}});
 await env.db.batch([guard(env.db,access,actor),currentGuard(env.db,id,access,actor),env.db.prepare(`INSERT INTO moderation_resolution_attempts(challenge_id,assertion_sha256) VALUES(?,?)`).bind(id,prepared.assertionSHA256)]);
 const verified=await verifyPreparedModerationOperatorWebAuthnAssertion(prepared);
 // Snapshot recipient BEFORE the transaction, then verify every source field
 // again INSIDE it. Release remains possible after source/recipient expiry.
 const s=await readLocalModerationReviewSource(env.db,{caseReferenceHmac:reference,caseReferenceHmacKeyVersion:version});
 const replySource=s&&await localModerationReviewSourceSHA256(s)===c.source_sha256?s:null;
 if(operation!=='release'&&!replySource)fail();
 const event=crypto.randomUUID();
 const statements=[guard(env.db,access,actor),currentGuard(env.db,id,access,actor)];
 if(replySource)statements.push(sourceGuard(env.db,replySource));
 statements.push(env.db.prepare(`INSERT INTO moderation_resolution_consumptions(challenge_id,verified_assertion_sha256,authenticator_sign_count) VALUES(?,?,?)`).bind(id,verified.assertionSHA256,verified.newCounter),
  env.db.prepare(`INSERT INTO moderation_resolution_events(event_id,challenge_id) VALUES(?,?)`).bind(event,id));
 if(replySource)statements.push(env.db.prepare(`INSERT INTO moderation_resolution_replies(event_id,report_id,recipient_participant_id,template_code,expires_at)
  VALUES(?,?,?,?,MIN(?,unixepoch()+86400))`).bind(event,replySource.metadata.reportId,replySource.metadata.reporterParticipantId,operation,replySource.metadata.contentExpiresAt));
 if(operation==='no_action')statements.push(env.db.prepare(`DELETE FROM moderation_advisory_jobs WHERE report_id IN(SELECT report_id FROM moderation_operator_versioned_case_references WHERE case_reference_hmac=?)`).bind(reference));
 await env.db.batch(statements);
 return json({caseReferenceHmac:reference,eventId:event,operation,revision:revision+1,reply:replySource?'available_in_app':'not_created_source_unavailable',recipientViewed:false});
}

/** Local owner entry only; production operator remains disabled. Public reply
 * reads are separately authenticated as the exact report participant. */
export async function routeLocalModerationResolution(request:Request,env:LocalModerationOwnerEnvironment):Promise<Response> {
 if(env.runtimeEnabled!=='YES'||env.environment!=='local')return json({error:'owner_runtime_disabled'},503);
 try {
  const url=new URL(request.url),m=pattern.exec(url.pathname);
  if(request.method!=='POST'||!m||Number(m[2])>2147483647)return json({error:'not_found'},404);
  const origin=new URL(env.origin);
  if(origin.protocol!=='https:'||origin.origin!==env.origin||origin.hostname!==env.rpId||url.origin!==env.origin||url.search||request.headers.get('origin')!==env.origin)fail(403);
  let access:AuthenticatedModerationOperatorAccess;
  try{access=await authenticateCloudflareAccessRequest(request,env.access)}catch{fail(401)}
  const actor=await env.db.prepare(actorSQL).bind(access.operatorSubjectHmac,access.subjectHmacKeyVersion).first<Actor>();if(!actor)fail(403);
  const p=await env.db.prepare(`SELECT policy_revision FROM moderation_owner_current_policies WHERE owner_operator_id=? AND enrollment_admission_id=?`).bind(actor.operator_id,actor.enrollment_admission_id).first<{policy_revision:number}>();if(!p)fail(403);
  if(!m[6]&&request.body!==null)fail(400);
  await env.db.batch([guard(env.db,access,actor),admitSession(env.db,access,actor),
   env.db.prepare(`DELETE FROM moderation_resolution_scopes WHERE challenge_id IN(SELECT challenge_id FROM moderation_resolution_challenges WHERE expires_at<=unixepoch())`),
   env.db.prepare(`DELETE FROM moderation_resolution_replies WHERE expires_at<=unixepoch()`)]);
  const ref=m[1]!,version=Number(m[2]);
  if(m[3]==='state') {
   if(m[6])fail(404);
   const result=await env.db.batch([guard(env.db,access,actor),
    env.db.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM moderation_owner_current_policies p
      JOIN moderation_operator_access_sessions a ON a.operator_id=p.owner_operator_id AND a.access_subject_hmac=p.access_subject_hmac
       AND a.access_subject_hmac_key_version=p.access_subject_hmac_key_version
      WHERE p.policy_revision=? AND p.owner_operator_id=? AND p.enrollment_admission_id=? AND p.credential_id_sha256=?
       AND a.access_session_sha256=? AND a.rowid>p.session_rowid_floor AND a.admitted_at>=p.created_at AND a.token_expires_at>unixepoch())
     THEN 'true' ELSE 'denied' END)`)
      .bind(p.policy_revision,actor.operator_id,actor.enrollment_admission_id,actor.credential_id_sha256,access.accessSessionSHA256),
    env.db.prepare(`SELECT cs.event_id,cs.operation,
      COALESCE(ms.revision,0) AS revision,COALESCE(ms.hidden,0) AS hidden,
      CASE WHEN m.id IS NOT NULL AND ${activeTargetSQL}
       AND EXISTS(SELECT 1 FROM moment_spaces WHERE space_id=m.space_id AND state='active')
       THEN 1 ELSE 0 END AS available
     FROM (SELECT ? AS reference,? AS version) subject
     LEFT JOIN moderation_resolution_case_states cs ON cs.case_reference_hmac=subject.reference AND cs.case_reference_hmac_key_version=subject.version
     LEFT JOIN moderation_operator_versioned_case_references ref ON ref.case_reference_hmac=subject.reference AND ref.case_reference_hmac_key_version=subject.version
     LEFT JOIN moment_reports r ON r.id=ref.report_id
     LEFT JOIN moments m ON m.id=CASE WHEN cs.event_id IS NOT NULL THEN cs.moment_id
       WHEN NOT EXISTS(SELECT 1 FROM moderation_resolution_events e JOIN moderation_resolution_challenges c USING(challenge_id) WHERE c.case_reference_hmac=subject.reference)
       THEN r.moment_id ELSE NULL END
     LEFT JOIN moderation_moment_states ms ON ms.moment_id=m.id`).bind(ref,version)]);
   const state=result[2]!.results[0] as {event_id:string|null;operation:Operation|null;revision:number;hidden:number;available:number};
   return json({caseReferenceHmac:ref,targetAvailable:state.available===1,revision:state.revision,hidden:state.available===1?state.hidden===1:null,
    restrictionEventId:state.operation==='hide'?state.event_id:null,canRelease:state.available===1&&state.operation==='hide',operation:state.operation});
  }
  const operation=m[3]!.split('/')[0] as Operation,identity=m[4]!,revision=Number(m[5]);if(revision>=2147483647)fail(400);
  if(m[6])return await prove(request,env,access,actor,ref,version,operation,identity,revision,m[6]);
  return await issue(env,access,actor,ref,version,operation,identity,revision,url.pathname,p.policy_revision);
 }catch(error) {
  const message=error instanceof Error?error.message:'';
  const status=error instanceof ResolutionError?error.status:/quota|too many/u.test(message)?429:/constraint|denied|malformed JSON|replay|stale|expired|requires|counter|not current/u.test(message)?409:503;
  return json({error:'resolution_unavailable'},status);
 }
}
