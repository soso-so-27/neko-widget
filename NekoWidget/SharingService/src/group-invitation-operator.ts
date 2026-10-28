import {base64urlEncode} from './encoding';
import type {AuthenticatedModerationOperatorAccess as Access} from './moderation-operator-auth';
import type {Actor} from './moderation-operator-identity';
import {prepareModerationOperatorWebAuthnRequest} from './moderation-operator-request';
import {verifyPreparedModerationOperatorWebAuthnAssertion} from './moderation-operator-webauthn';
import {groupModerationSHA} from './group-moderation-source';
import type {GroupOperatorEnvironment} from './group-moderation-operator';

type Action='status'|'pause'|'resume';
interface Challenge {id:string;value_sha256:string;action:Action;state_revision:number;policy_revision:number}
type Authorization=(revision?:number)=>D1PreparedStatement[];
const prefix='/operator/group/v1/invitations';
const headers={'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'};
const json=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers});
function denied():never {throw new Error('invitation_operator_unavailable');}

/** Only called after the local host's origin, Access, active actor and owner-policy checks. */
export async function groupInvitationOperator(request:Request,env:GroupOperatorEnvironment,access:Access,actor:Actor,auth:Authorization):Promise<Response> {
 const path=new URL(request.url).pathname;
 const assertion=new RegExp(`^${prefix}/assertions/([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$`,'u').exec(path);
 if(assertion){
  const id=assertion[1]!;
  const c=await env.db.prepare(`SELECT id,value_sha256,action,state_revision,policy_revision FROM group_invitation_challenges
   WHERE id=? AND operator_id=? AND credential_id_sha256=? AND enrollment_admission_id=? AND access_session_sha256=? AND expires_at>unixepoch()`)
   .bind(id,actor.operator_id,actor.credential_id_sha256,actor.enrollment_admission_id,access.accessSessionSHA256).first<Challenge>();if(!c)denied();
  const current=()=>[...auth(c.policy_revision),env.db.prepare(`SELECT json(CASE WHEN EXISTS(
   SELECT 1 FROM group_invitation_challenges c JOIN group_invitation_state s ON s.revision=c.state_revision
   WHERE c.id=? AND c.expires_at>unixepoch()) THEN 'true' ELSE 'denied' END)`).bind(id)];
  const prepared=await prepareModerationOperatorWebAuthnRequest(request,{expectedOrigin:env.origin,expectedRPID:env.rpId,
   expectedChallengeSHA256:c.value_sha256,credential:{credentialIdSHA256:actor.credential_id_sha256,publicKeyCose:new Uint8Array(actor.public_key_cose),counter:actor.sign_count}});
  // Record even an invalid cryptographic attempt; the same challenge cannot be retried.
  await env.db.batch([...current(),env.db.prepare('INSERT INTO group_invitation_attempts(challenge_id,assertion_sha256) VALUES (?,?)').bind(id,prepared.assertionSHA256)]);
  const verified=await verifyPreparedModerationOperatorWebAuthnAssertion(prepared);
  const statements=[...current(),env.db.prepare(`INSERT INTO group_invitation_consumptions(challenge_id,assertion_sha256,authenticator_sign_count) VALUES (?,?,?)`)
   .bind(id,verified.assertionSHA256,verified.newCounter)];
  if(c.action!=='status')statements.push(env.db.prepare('INSERT INTO group_invitation_events(revision,challenge_id,paused) VALUES (?,?,?)')
   .bind(c.state_revision+1,id,c.action==='pause'?1:0));
  statements.push(env.db.prepare('SELECT revision,paused,operator_id AS operatorId,changed_at AS changedAt FROM group_invitation_state'));
  const result=await env.db.batch(statements),state=result.at(-1)!.results[0] as {revision:number;paused:number;operatorId:string|null;changedAt:number|null};
  return json({...state,paused:state.paused===1});
 }
 const action=path.slice(prefix.length+1);if(request.body!==null||!['status','pause','resume'].includes(action))denied();
 const state=await env.db.prepare('SELECT revision,paused FROM group_invitation_state').first<{revision:number;paused:number}>();if(!state)denied();
 if((action==='pause'&&state.paused===1)||(action==='resume'&&state.paused===0))denied();
 const policy=await env.db.prepare('SELECT policy_revision FROM moderation_owner_current_policies WHERE owner_operator_id=? AND enrollment_admission_id=?')
  .bind(actor.operator_id,actor.enrollment_admission_id).first<{policy_revision:number}>();if(!policy)denied();
 const id=crypto.randomUUID(),random=crypto.getRandomValues(new Uint8Array(32)),expires=Math.min(Math.floor(Date.now()/1000)+300,access.expiresAt);
 await env.db.batch([...auth(policy.policy_revision),env.db.prepare(`INSERT INTO group_invitation_challenges
  (id,operator_id,credential_id_sha256,enrollment_admission_id,access_session_sha256,policy_revision,value_sha256,action,state_revision,expires_at)
  VALUES (?,?,?,?,?,?,?,?,?,?)`).bind(id,actor.operator_id,actor.credential_id_sha256,actor.enrollment_admission_id,
  access.accessSessionSHA256,policy.policy_revision,await groupModerationSHA(random),action,state.revision,expires)]);
 return json({challengeId:id,challenge:base64urlEncode(random),rpId:env.rpId,userVerification:'required',
  assertionPath:`${prefix}/assertions/${id}`,action,expiresAt:expires},202);
}
