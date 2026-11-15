import { authenticateGroupRequest } from './group-auth';
import { parseJsonBody } from './http';
import { gate as familyGate, familyStorePolicy } from './family-notebook-payer';
import { base64urlDecode,randomBase64url,sha256Base64url } from './encoding';
import { ApiError,jsonResponse } from './errors';
import type { Env } from './env';
import { groupMutationStatement,groupAuthorizationStatements,storedGroupMutation,type GroupActor } from './group-auth';
import { APNS_SUBSCRIPTION_TTL_SECONDS,decryptDeviceToken,encryptDeviceToken,parseProviderCredential,parseTokenKeyring,providerJWT,type APNsDrainSummary } from './push';
import { apnsGateOpen,loadRuntimeGate } from './runtime-gate';
import { exactKeys,stringField,uuidField,type JsonRecord } from './validation';


function enabled(env:Env):boolean {
  return env.FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED==='YES' && env.FAMILY_NOTEBOOK_API_RUNTIME_ENABLED==='YES'
    && env.FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED==='YES' && env.GROUP_RUNTIME_ENABLED==='YES'
    && env.APNS_RUNTIME_ENABLED==='YES' && env.MOMENT_RUNTIME_ENABLED==='YES';
}
export async function cleanupExpiredFamilyPush(env:Env,now:number):Promise<void> {
  await env.DB.prepare(`DELETE FROM family_notification_deliveries WHERE rowid IN (SELECT rowid FROM family_notification_deliveries WHERE available_at<? AND state<>'leased' LIMIT 500)`).bind(now-172800).run();
  // Preserve the generation tombstone, but not expired physical tokens.
  await env.DB.prepare(`UPDATE family_push_subscriptions SET token_ciphertext='',token_nonce='',token_digest=''
    WHERE rowid IN (SELECT rowid FROM family_push_subscriptions WHERE expires_at<=? AND token_ciphertext<>'' LIMIT 100)`)
    .bind(now).run();
}
function gateCheck(env:Env,generation:number):D1PreparedStatement[] {
  const id=crypto.randomUUID();return [env.DB.prepare('INSERT INTO group_push_checks VALUES (?,?)').bind(id,generation),
    env.DB.prepare('DELETE FROM group_push_checks WHERE id=?').bind(id)];
}
export async function familyPushRegistration(request:Request,env:Env,familyId:string,remove=false):Promise<Response> {
  if(env.FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED!=='YES' && !remove) throw new ApiError(503,'family_notifications_disabled','Family notifications are unavailable.');
  const {actor,body}=await authenticateGroupRequest(request,env,8192);
  try { return await changeFamilyPush(env,actor,familyId,parseJsonBody(request,body),remove); }
  catch(error) {
    if(error instanceof Error && error.message.includes('family_notification_not_allowed')) throw new ApiError(403,'family_notification_not_allowed','Family notification registration is no longer allowed.');
    throw error;
  }
}
async function changeFamilyPush(env:Env,actor:GroupActor,familyId:string,body:JsonRecord,remove:boolean):Promise<Response> {
  exactKeys(body,remove?['operationId']:['operationId','token','environment']);
  const operationId=uuidField(body,'operationId');
  // Explicit family consent: window push subscriptions never grant this.
  if(!remove) {
    await familyGate(env);
    const eligible=await env.DB.prepare(`SELECT 1 FROM family_notebook_spaces f WHERE f.id=? AND f.state='active'
      AND (EXISTS(SELECT 1 FROM family_notebook_members m WHERE m.family_id=f.id AND m.person_id=? AND m.state='active')
        OR EXISTS(SELECT 1 FROM family_notebook_join_requests j WHERE j.family_id=f.id AND j.person_id=? AND j.device_id=?
          AND j.state='pending' AND j.expires_at>unixepoch()))`).bind(familyId,actor.personId,actor.personId,actor.deviceId).first();
    if(!eligible)throw new ApiError(404,'not_found','The family request or membership was not found.');
  }
  // Unregister remains available while push is OFF. It cannot send a push or
  // restore an expired subscription; keep the generation tombstone on removal.
  const gate=await loadRuntimeGate(env);
  if(!remove && (!enabled(env) || !apnsGateOpen(gate)))throw new ApiError(503,'family_notifications_disabled','Family notifications are unavailable.');
  const previous=await storedGroupMutation(env,actor,operationId);if(previous)return jsonResponse(previous);
  const receipt={operationId,familyId,notifications:!remove,serverNow:actor.now};
  const statements=[...groupAuthorizationStatements(env,actor)];
  if(remove)statements.push(env.DB.prepare(`UPDATE family_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest='' WHERE space_id=? AND device_id=?`).bind(familyId,actor.deviceId));
  else {
    let credential,keyring,token:Uint8Array;
    try {
      credential=parseProviderCredential(env);keyring=parseTokenKeyring(env);
      token=base64urlDecode(stringField(body,'token'));
    } catch { throw new ApiError(400,'invalid_push_registration','The notification registration is invalid.'); }
    if(token.length<16 || token.length>256 || body.environment!==credential.environment)
      throw new ApiError(400,'invalid_push_registration','The notification registration is invalid.');
    const sealed=await encryptDeviceToken(token,actor.deviceId,credential,keyring);
    statements.push(...gateCheck(env,gate!.generation),
      env.DB.prepare(`INSERT INTO family_push_subscriptions VALUES (?,?,?,?,?,?,?,1,?)
        ON CONFLICT(space_id,device_id) DO UPDATE SET token_ciphertext=excluded.token_ciphertext,token_nonce=excluded.token_nonce,
          token_digest=excluded.token_digest,encryption_key_id=excluded.encryption_key_id,environment=excluded.environment,
          generation=CASE WHEN family_push_subscriptions.expires_at>? AND family_push_subscriptions.token_digest=excluded.token_digest
            AND family_push_subscriptions.environment=excluded.environment THEN family_push_subscriptions.generation ELSE family_push_subscriptions.generation+1 END,
          expires_at=excluded.expires_at`)
        .bind(familyId,actor.deviceId,sealed.ciphertext,sealed.nonce,sealed.digest,sealed.keyID,credential.environment,actor.now+APNS_SUBSCRIPTION_TTL_SECONDS,actor.now));
  }
  statements.push(groupMutationStatement(env,actor,operationId,receipt));
  await env.DB.batch(statements);return jsonResponse(receipt);
}
interface Queued {
  event_id:string;device_id:string;token_digest:string;subscription_generation:number;attempts:number;
}
interface Current extends Queued {
  space_id:string;kind:'join_requested'|'join_approved';expires_at:number;
  token_ciphertext:string;token_nonce:string;encryption_key_id:string;environment:'production'|'development';
}
export function familyNotificationPayload(row:Pick<Current,'kind'|'space_id'>):string {
  return JSON.stringify({aps:{alert:{title:'ねこのまど',body:row.kind==='join_requested'?'家族の手帳に、入りたい人がいます。':'家族の手帳に入りました。'},
    'content-available':1},neko:{v:3,kind:'family_'+row.kind,familyId:row.space_id}});
}
async function finish(env:Env,row:Queued,leaseId:string,state:'accepted'|'skipped'|'invalid'|'pending',now:number):Promise<void> {
  await env.DB.prepare(`UPDATE family_notification_deliveries SET state=?,attempts=attempts+1,available_at=?,lease_id=NULL,lease_expires_at=NULL
    WHERE event_id=? AND device_id=? AND token_digest=? AND subscription_generation=? AND state='leased' AND lease_id=?`)
    .bind(state,now+Math.min(3600,30*2**Math.min(row.attempts,7)),row.event_id,row.device_id,row.token_digest,row.subscription_generation,leaseId).run();
}
async function current(env:Env,row:Queued,leaseId:string,generation:number):Promise<Current|null> {
  const policy=familyStorePolicy(env);
  return env.DB.prepare(`SELECT v.*,q.attempts FROM family_live_notification_deliveries v
    JOIN family_notification_deliveries q ON q.event_id=v.event_id AND q.device_id=v.device_id
    JOIN group_person_devices recipient ON recipient.id=v.device_id
    JOIN personal_staging_runtime_gate g ON g.singleton=1
    WHERE q.event_id=? AND q.device_id=? AND q.token_digest=? AND q.subscription_generation=?
      AND q.state='leased' AND q.lease_id=? AND q.lease_expires_at>unixepoch()
      AND g.generation=? AND g.media_enabled=1 AND g.apns_enabled=1
      AND EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
      AND (v.kind='join_approved' OR EXISTS(SELECT 1 FROM family_notebook_spaces f JOIN group_verified_plus_people p ON p.person_id=f.payer_person_id
        WHERE f.id=v.space_id AND (p.environment=? OR (?='Production' AND ?=1 AND p.environment='Sandbox'))))`)
    .bind(row.event_id,row.device_id,row.token_digest,row.subscription_generation,leaseId,generation,policy.environment,policy.environment,policy.acceptSandbox).first<Current>();
}
export async function drainFamilyNotifications(env:Env,now=Math.floor(Date.now()/1000),fetchImpl:typeof fetch=fetch,
  hooks:{afterLease?:(row:Queued)=>Promise<void>;beforeSend?:(row:Queued)=>Promise<void>}={}):Promise<APNsDrainSummary> {
  const summary:APNsDrainSummary={leased:0,accepted:0,retried:0,invalidated:0,skipped:0,configurationUnavailable:false};
  if(!enabled(env))return summary;
  const gate=await loadRuntimeGate(env);if(!apnsGateOpen(gate))return summary;
  const family=await env.DB.prepare('SELECT enabled FROM family_notebook_runtime_gate WHERE singleton=1').first<{enabled:number}>();if(family?.enabled!==1)return summary;
  let credential,keyring,authorization:string;
  try { credential=parseProviderCredential(env);keyring=parseTokenKeyring(env);authorization=await providerJWT(credential,now); }
  catch { summary.configurationUnavailable=true;return summary; }
  await env.DB.prepare(`INSERT OR IGNORE INTO family_notification_deliveries
    (event_id,device_id,token_digest,subscription_generation,state,available_at)
    SELECT event_id,device_id,token_digest,subscription_generation,'pending',MAX(?,v.available_at) FROM family_notification_recipients v WHERE NOT EXISTS (SELECT 1 FROM family_notification_deliveries q WHERE q.event_id=v.event_id AND q.device_id=v.device_id) LIMIT 500`).bind(now).run();
  // A rotated token can retry an unsent event. Accepted events remain deduplicated.
  await env.DB.prepare(`UPDATE family_notification_deliveries SET token_digest=v.token_digest,subscription_generation=v.subscription_generation,
    state='pending',available_at=MAX(?,v.available_at),lease_id=NULL,lease_expires_at=NULL FROM family_notification_recipients v
    WHERE family_notification_deliveries.event_id=v.event_id AND family_notification_deliveries.device_id=v.device_id
      AND family_notification_deliveries.state<>'accepted'
      AND (family_notification_deliveries.token_digest<>v.token_digest OR family_notification_deliveries.subscription_generation<>v.subscription_generation)`).bind(now).run();
  const candidates=await env.DB.prepare(`SELECT event_id,device_id,token_digest,subscription_generation,attempts FROM family_notification_deliveries
    WHERE (state='pending' AND available_at<=?) OR (state='leased' AND lease_expires_at<=?) ORDER BY available_at,event_id,device_id LIMIT 50`)
    .bind(now,now).all<Queued>();
  for(const row of candidates.results) {
    const leaseId=randomBase64url(16),leased=await env.DB.prepare(`UPDATE family_notification_deliveries SET state='leased',lease_id=?,lease_expires_at=?
      WHERE event_id=? AND device_id=? AND token_digest=? AND subscription_generation=?
        AND ((state='pending' AND available_at<=?) OR (state='leased' AND lease_expires_at<=?))`)
      .bind(leaseId,now+90,row.event_id,row.device_id,row.token_digest,row.subscription_generation,now,now).run();
    if(leased.meta.changes!==1)continue;summary.leased++;
    await hooks.afterLease?.(row);
    const snapshot=await current(env,row,leaseId,gate!.generation);
    if(!snapshot || snapshot.environment!==credential.environment) {
      await finish(env,row,leaseId,'skipped',now);summary.skipped++;continue;
    }
    let token:Uint8Array;
    try { token=await decryptDeviceToken(snapshot,credential,keyring); }
    catch { await finish(env,row,leaseId,row.attempts>=7?'invalid':'pending',now);summary.retried++;continue; }
    const collapseId=await sha256Base64url(new TextEncoder().encode(row.event_id+':'+row.device_id));
    await hooks.beforeSend?.(row);
    // Fresh family role/request, lease, token and gate checks after ALL awaits.
    // No name or notebook content ever leaves in the APNs payload.
    const live=await current(env,row,leaseId,gate!.generation);
    if(!live || live.environment!==snapshot.environment || live.token_ciphertext!==snapshot.token_ciphertext
      || live.token_nonce!==snapshot.token_nonce || live.encryption_key_id!==snapshot.encryption_key_id) {
      await finish(env,row,leaseId,'skipped',now);summary.skipped++;continue;
    }
    const hex=[...token].map(b=>b.toString(16).padStart(2,'0')).join('');
    let response:Response;
    try {
      response=await fetchImpl(`https://${credential.environment==='production'?'api':'api.sandbox'}.push.apple.com/3/device/${hex}`,{
        method:'POST',headers:{authorization:`bearer ${authorization}`,'apns-push-type':'alert','apns-priority':'10',
          'apns-topic':credential.bundleId,'apns-expiration':String(live.expires_at),'apns-collapse-id':`family-${collapseId}`,
          'content-type':'application/json'},body:familyNotificationPayload(live),signal:AbortSignal.timeout(10000)});
    } catch { await finish(env,row,leaseId,'pending',now);summary.retried++;continue; }
    if(response.status===200) {
      await finish(env,row,leaseId,'accepted',now);summary.accepted++;continue;
    }
    // Read only a bounded response. Provider errors are never copied into logs.
    let reason='';
    try { const reader=response.body?.getReader();if(reader) {
      const part=await reader.read();await reader.cancel();
      if(part.value && part.value.length<=1024)reason=(JSON.parse(new TextDecoder().decode(part.value)) as {reason?:string}).reason??'';
    }} catch { /* Unknown response stays retryable. */ }
    if(response.status===410 || (response.status===400 && ['BadDeviceToken','DeviceTokenNotForTopic'].includes(reason))) {
      await env.DB.prepare(`UPDATE family_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce=''
        WHERE space_id=? AND device_id=? AND token_digest=? AND generation=?`)
        .bind(live.space_id,row.device_id,row.token_digest,row.subscription_generation).run();
      await finish(env,row,leaseId,'invalid',now);summary.invalidated++;
    } else {
      const retry=response.status===429 || response.status>=500 || reason==='ExpiredProviderToken';
      await finish(env,row,leaseId,retry?'pending':'skipped',now);if(retry)summary.retried++;else summary.skipped++;
    }
  }
  return summary;
}
