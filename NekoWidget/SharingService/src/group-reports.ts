import { putGroupUpload } from './group-identity-upload';
import { requireCurrentIdentity } from './group-identity-service';
import { deletedReportDelivery } from './group-deleted-delivery';
import { base64urlEncode, randomBase64url, sha256, sha256Base64url } from './encoding';
import { ApiError, jsonResponse } from './errors';
import type { Env } from './env';
import { authenticateGroupRequest, groupMutationStatement, type GroupActor } from './group-auth';
import { groupFields } from './group-protocol';
import { parseJsonBody } from './http';
import { currentModerationReportKey } from './moderation-report-key-policy';
import { loadRuntimeGate, reportIngestionGateOpen } from './runtime-gate';
import { asObject, binaryField, exactKeys, integerField, opaqueId, stringField, uuidField, type JsonRecord } from './validation';
import {groupReceiptNumber,newGroupReceiptNumber,isReceiptNumberCollision} from './group-report-number';

export const GROUP_REPORT_MAX_BYTES=1048576;
export const GROUP_REPORT_UPLOAD_SECONDS=3600;
export const GROUP_REPORT_CONTENT_SECONDS=7*86400;
const reportPath=/^\/v3\/group-windows\/([A-Za-z0-9_-]{22})\/reports\/(reserve|[A-Za-z0-9_-]{22}\/(?:ciphertext|commit))$/u;
export function isGroupReportPath(path:string):boolean { return reportPath.test(path); }
interface Report {
  receipt_number:string;
  id:string;space_id:string;moment_id:string;reporter_person_id:string;reporter_participant_id:string;reporter_device_id:string;
  reason_code:string;moderation_key_id:string;ciphertext_size:number;ciphertext_sha256:string;object_key:string;dedupe_key:string;
  state:'reserved'|'uploaded'|'committed'|'expired';created_at:number;upload_expires_at:number;
  deleted_delivery_until:number|null;uploaded_at:number|null;committed_at:number|null;content_expires_at:number|null;
}
function fail(code:string,status=409):never { throw new ApiError(status,code,'The encrypted report could not be accepted.'); }
function bucket(env:Env):R2Bucket { if(!env.MODERATION_MEDIA)fail('report_storage_unavailable',503);return env.MODERATION_MEDIA; }
function response(row:Report) {
  return {protocolVersion:3,report:{id:row.id,receiptNumber:row.receipt_number,windowId:row.space_id,momentId:row.moment_id,state:row.state,
    moderationKeyId:row.moderation_key_id,ciphertextSize:row.ciphertext_size,ciphertextSHA256:row.ciphertext_sha256,
    uploadExpiresAt:Math.min(row.upload_expires_at,row.deleted_delivery_until??Infinity),committedAt:row.committed_at,contentExpiresAt:row.content_expires_at}};
}
async function load(env:Env,actor:GroupActor,windowId:string,id:string):Promise<Report> {
  const row=await env.DB.prepare('SELECT * FROM group_reports WHERE id=? AND space_id=? AND reporter_person_id=? AND reporter_device_id=?')
    .bind(id,windowId,actor.personId,actor.deviceId).first<Report>();
  if(!row)fail('report_not_found',404);row.receipt_number=await groupReceiptNumber(env.DB,id);return row;
}
function live(row:Report,now=Math.floor(Date.now()/1000)):void {
  if(row.state==='expired' || (row.deleted_delivery_until!==null && row.deleted_delivery_until<=now) || (row.committed_at===null?row.upload_expires_at<=now:(row.content_expires_at??0)<=now))fail('reservation_expired',410);
}
function checks(env:Env,actor:GroupActor,windowId:string,generation:number):D1PreparedStatement[] {
  const id=crypto.randomUUID();
  return [env.DB.prepare('INSERT INTO group_report_checks VALUES (?,?,?,?)').bind(id,windowId,actor.deviceId,generation),
    env.DB.prepare('DELETE FROM group_report_checks WHERE id=?').bind(id)];
}
async function replay(env:Env,actor:GroupActor,windowId:string,generation:number,operationId:string):Promise<Response|null> {
  const row=await env.DB.prepare('SELECT request_hash,response_json FROM group_mutations WHERE actor_device_id=? AND operation_id=? AND expires_at>?')
    .bind(actor.deviceId,operationId,actor.now).first<{request_hash:string;response_json:string}>();
  if(!row)return null;
  if(row.request_hash!==actor.requestHash)fail('idempotency_conflict');
  const receipt=JSON.parse(row.response_json) as ReturnType<typeof response>;
  const current=await load(env,actor,windowId,receipt.report.id);live(current);
  await env.DB.batch([...checks(env,actor,windowId,generation)]);
  return jsonResponse(response(current));
}
async function reserve(env:Env,actor:GroupActor,windowId:string,generation:number,body:JsonRecord,numberAttempt=0):Promise<Response> {
  exactKeys(body,['operationId','momentId','reasonCode','moderationKeyId','ciphertextSize','ciphertextSHA256','reporterConsent']);
  const operationId=uuidField(body,'operationId'),momentId=opaqueId(stringField(body,'momentId'),'moment');
  const reason=stringField(body,'reasonCode');
  if(!['objectionable','harassment','privacy','other'].includes(reason))fail('invalid_reason',400);
  const key=stringField(body,'moderationKeyId');
  if(key!=='moderation-v2' || !await currentModerationReportKey(env.DB,key))fail('moderation_key_required');
  const size=integerField(body,'ciphertextSize',29,GROUP_REPORT_MAX_BYTES),hash=binaryField(body,'ciphertextSHA256',32);
  const consent=asObject(body.reporterConsent);exactKeys(consent,['version','acceptedAt']);
  if(integerField(consent,'version',1,Number.MAX_SAFE_INTEGER)!==1)fail('reporter_consent_required');
  const consentAt=integerField(consent,'acceptedAt',0,Number.MAX_SAFE_INTEGER);
  const prior=await replay(env,actor,windowId,generation,operationId);if(prior)return prior;
  // Historical delivery, not current media access: blocking/leaving must not
  // disable reporting. Never download the group ciphertext or a group key.
  const original=await env.DB.prepare(`SELECT c.participant_id,m.sender_participant_id FROM group_report_credentials c
    JOIN group_moment_deliveries d ON d.device_id=c.device_id AND d.participant_id=c.participant_id
    JOIN group_moments m ON m.id=d.moment_id AND m.space_id=c.space_id
    WHERE c.space_id=? AND c.device_id=? AND m.id=? AND m.committed_at IS NOT NULL AND m.sender_participant_id<>c.participant_id`)
    .bind(windowId,actor.deviceId,momentId).first<{participant_id:string;sender_participant_id:string}>();
  const marker=original?null:await deletedReportDelivery(env.DB,windowId,momentId,actor.personId,actor.deviceId);
  const delivered=original??marker;
  if(!delivered)fail('reportable_moment_not_found',404);
  const dedupe=await sha256Base64url(groupFields(['NW3.REPORT-DEDUPE',windowId,momentId,actor.personId]));
  const previous=await env.DB.prepare(`SELECT * FROM group_reports WHERE moment_id=? AND reporter_person_id=?
    AND (state IN ('reserved','uploaded','committed') OR committed_at IS NOT NULL) ORDER BY created_at DESC LIMIT 1`)
    .bind(momentId,actor.personId).first<Report>();
  if(previous && (previous.committed_at!==null || previous.upload_expires_at>actor.now)) {
    if(previous.reporter_device_id!==actor.deviceId || previous.reason_code!==reason || previous.moderation_key_id!==key
      || previous.ciphertext_size!==size || previous.ciphertext_sha256!==hash)fail('already_reported');
    live(previous);previous.receipt_number=await groupReceiptNumber(env.DB,previous.id);const receipt=response(previous);
    await env.DB.batch([...checks(env,actor,windowId,generation),groupMutationStatement(env,actor,operationId,receipt)]);
    return jsonResponse(receipt);
  }
  // The exact signed retry (or the same already-consented ciphertext) above
  // creates no new evidence or deadline. Only a NEW reservation needs fresh
  // consent; SQL independently enforces that same rule at insertion time.
  if(Math.abs(consentAt-actor.now)>300)fail('reporter_consent_required');
  const id=randomBase64url(16),objectKey=`groups/reports/v3/${id}/${randomBase64url(24)}`;
  const row={id,receipt_number:newGroupReceiptNumber(),space_id:windowId,moment_id:momentId,state:'reserved',moderation_key_id:key,ciphertext_size:size,ciphertext_sha256:hash,
    upload_expires_at:actor.now+GROUP_REPORT_UPLOAD_SECONDS,deleted_delivery_until:marker?.expiresAt??null,committed_at:null,content_expires_at:null} as Report;
  const receipt=response(row),statements=[...checks(env,actor,windowId,generation)];
  if(previous && previous.state!=='expired')statements.push(
    env.DB.prepare("UPDATE group_reports SET state='expired',expired_at=? WHERE id=? AND state IN ('reserved','uploaded') AND upload_expires_at<=?")
      .bind(actor.now,previous.id,actor.now),
    env.DB.prepare("INSERT INTO group_report_object_deletions SELECT id,object_key,0,?,'pending' FROM group_reports WHERE id=? AND state='expired' ON CONFLICT(report_id) DO NOTHING")
      .bind(actor.now,previous.id));
  if(marker)statements.push(marker.authorize(id));
  statements.push(env.DB.prepare(`INSERT INTO group_reports (id,space_id,moment_id,reporter_person_id,reporter_participant_id,reporter_device_id,
    accused_participant_id,reason_code,moderation_key_id,ciphertext_size,ciphertext_sha256,reporter_consent_version,reporter_consented_at,
    object_key,dedupe_key,state,created_at,upload_expires_at${marker?',deleted_delivery_until':''}) VALUES (?,?,?,?,?,?,?,?,?,?,?,1,?,?,?,'reserved',?,?${marker?',?':''})`)
    .bind(id,windowId,momentId,actor.personId,delivered.participant_id,actor.deviceId,delivered.sender_participant_id,reason,key,size,hash,consentAt,
      objectKey,dedupe,actor.now,actor.now+GROUP_REPORT_UPLOAD_SECONDS,...(marker?[marker.expiresAt]:[])),
    env.DB.prepare('INSERT INTO group_report_numbers(report_id,receipt_number) VALUES (?,?)').bind(id,row.receipt_number),
    groupMutationStatement(env,actor,operationId,receipt));
  if(marker)statements.push(env.DB.prepare('DELETE FROM group_deleted_delivery_commands WHERE report_id=?').bind(id));
  try { await env.DB.batch(statements); }
  catch(error) {
    const raced=await replay(env,actor,windowId,generation,operationId);if(raced)return raced;
    if(isReceiptNumberCollision(error)&&numberAttempt<3)return reserve(env,actor,windowId,generation,body,numberAttempt+1);
    throw error;
  }
  return jsonResponse(receipt,201);
}
function matches(object:R2Object|null,row:Report):boolean {
  return object!==null && object.size===row.ciphertext_size && object.checksums.sha256!==undefined
    && base64urlEncode(new Uint8Array(object.checksums.sha256))===row.ciphertext_sha256;
}
async function upload(env:Env,actor:GroupActor,windowId:string,generation:number,id:string,bytes:Uint8Array):Promise<Response> {
  const row=await load(env,actor,windowId,id);live(row);
  if(bytes.length!==row.ciphertext_size || await sha256Base64url(bytes)!==row.ciphertext_sha256)fail('ciphertext_descriptor_mismatch');
  if(!await currentModerationReportKey(env.DB,row.moderation_key_id))fail('moderation_key_required');
  await env.DB.batch([...checks(env,actor,windowId,generation)]);
  const storage=bucket(env);
  if(row.state==='reserved') {
    const object=await putGroupUpload(env,storage,row.object_key,bytes,{sha256:(await sha256(bytes)).slice().buffer,
      httpMetadata:{contentType:'application/octet-stream'}},async()=>{
        await requireCurrentIdentity(env,actor.personId);
        live(await load(env,actor,windowId,id));
        await env.DB.batch(checks(env,actor,windowId,generation));
      });
    if(!matches(object??await storage.head(row.object_key),row))fail('stored_object_unavailable',503);
    try {
      await env.DB.batch([...checks(env,actor,windowId,generation),env.DB.prepare("UPDATE group_reports SET state='uploaded',uploaded_at=unixepoch() WHERE id=? AND state='reserved'").bind(id)]);
    } catch(error) {
      await queueLateGroupReportUpload(env,id,row.object_key);throw error;
    }
  } else if(!matches(await storage.head(row.object_key),row))fail('stored_object_unavailable',503);
  // Recheck even read-only retries after the asynchronous R2 operation.
  await env.DB.batch(checks(env,actor,windowId,generation));
  const current=await load(env,actor,windowId,id);live(current);
  return jsonResponse(response(current));
}
async function commit(env:Env,actor:GroupActor,windowId:string,generation:number,id:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,['operationId']);const operationId=uuidField(body,'operationId');
  const prior=await replay(env,actor,windowId,generation,operationId);if(prior)return prior;
  const row=await load(env,actor,windowId,id);live(row);
  if(!await currentModerationReportKey(env.DB,row.moderation_key_id))fail('moderation_key_required');
  if(row.state==='reserved')fail('report_not_ready');
  if(!matches(await bucket(env).head(row.object_key),row))fail('stored_object_unavailable',503);
  const now=Math.floor(Date.now()/1000);
  const receipt=response(row.state==='committed'?row:{...row,state:'committed',committed_at:now,content_expires_at:now+GROUP_REPORT_CONTENT_SECONDS});
  const statements=[...checks(env,actor,windowId,generation)];
  if(row.state!=='committed')statements.push(env.DB.prepare(`UPDATE group_reports SET state='committed',committed_at=?,content_expires_at=?
    WHERE id=? AND state='uploaded'`).bind(now,now+GROUP_REPORT_CONTENT_SECONDS,id));
  statements.push(groupMutationStatement(env,actor,operationId,receipt));
  try { await env.DB.batch(statements); }
  catch(error) {
    const raced=await replay(env,actor,windowId,generation,operationId);if(raced)return raced;
    throw error;
  }
  // Concurrent commits share the first immutable commit/expiry, never extend it.
  const current=await load(env,actor,windowId,id);live(current);
  return jsonResponse(response(current));
}

/** No report downloads, group-key access, member revocation or moderation
 * decision is exposed here. The client sends ONLY its selected evidence,
 * encrypted separately to moderation-v2 with the NW3.MODERATION-REPORT domain.
 * Operator review must be connected and verified before enabling this gate. */
export async function groupReportAPI(request:Request,env:Env):Promise<Response> {
  if(env.GROUP_REPORT_RUNTIME_ENABLED!=='YES')fail('group_reports_disabled',503);
  if(env.GROUP_MODERATION_RUNTIME_ENABLED!=='YES')fail('group_moderation_disabled',503);
  const path=new URL(request.url).pathname,match=path.match(reportPath);
  if(!match)fail('not_found',404);
  const windowId=match[1]!,action=match[2]!,isUpload=action.endsWith('/ciphertext');
  if(request.method!==(isUpload?'PUT':'POST'))fail('method_not_allowed',405);
  const {actor,body:bytes}=await authenticateGroupRequest(request,env,isUpload?GROUP_REPORT_MAX_BYTES:16*1024,windowId);
  const gate=await loadRuntimeGate(env);
  if(env.REPORT_INGESTION_RUNTIME_ENABLED!=='YES' || !reportIngestionGateOpen(gate)) {
    fail('report_ingestion_runtime_disabled',503);
  }
  const generation=gate!.generation;
  bucket(env);
  try {
    if(isUpload) {
      if(request.headers.get('content-type')!=='application/octet-stream')fail('invalid_content_type',415);
      return await upload(env,actor,windowId,generation,action.split('/')[0]!,bytes);
    }
    const body=parseJsonBody(request,bytes);
    return action==='reserve'?await reserve(env,actor,windowId,generation,body):await commit(env,actor,windowId,generation,action.split('/')[0]!,body);
  } catch(error) {
    // Authentication has already consumed the nonce, including failures.
    throw error;
  }
}

export const GROUP_REPORT_OBJECT_KEY=/^groups\/reports\/v3\/[A-Za-z0-9_-]{22}\/[A-Za-z0-9_-]{32}$/u;
export async function queueLateGroupReportUpload(env:Env,id:string,objectKey:string):Promise<void> {
  if(!GROUP_REPORT_OBJECT_KEY.test(objectKey))return;
  const current=await env.DB.prepare('SELECT state,upload_expires_at FROM group_reports WHERE id=? AND object_key=?')
    .bind(id,objectKey).first<{state:string;upload_expires_at:number}>();
  if(current && current.state!=='expired' && current.upload_expires_at>Math.floor(Date.now()/1000))return;
  if(current?.state==='committed')return;
  await env.DB.prepare(`INSERT INTO group_report_object_deletions VALUES (?,?,0,unixepoch(),'pending')
    ON CONFLICT(report_id) DO UPDATE SET attempts=attempts+1,available_at=unixepoch(),state='pending'`).bind(id,objectKey).run();
}
