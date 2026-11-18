import {authenticateGroupRequest,groupAuthorizationStatements} from './group-auth';
import {familyUUID} from './family-notebook-crypto';
import {currentModerationReportKey} from './moderation-report-key-policy';
import {loadRuntimeGate,reportIngestionGateOpen} from './runtime-gate';
import {base64urlDecode,base64urlEncode,sha256Base64url,randomBase64url} from './encoding';
import {parseJsonBody} from './http';
import {exactKeys,integerField,stringField,uuidField,binaryField} from './validation';
import {ApiError,jsonResponse} from './errors';
import {putGroupUpload} from './group-identity-upload';
import {requireCurrentIdentity} from './group-identity-service';
import type {Env} from './env';

interface Report {
 report_id:string;family_id:string;asset_id:string;reporter_person_id:string;reporter_device_id:string;
 request_hash:string;object_key:string;ciphertext_size:number;ciphertext_sha256:string;
 state:string;upload_expires_at:number;committed_at:number|null;content_expires_at:number|null;
}
function fail(code:string,status=409):never {throw new ApiError(status,code,'The encrypted report could not be accepted.');}
const reply=(r:Report)=>jsonResponse({schemaVersion:1,reportId:r.report_id,familyId:r.family_id,
 assetId:r.asset_id,state:r.state,committedAt:r.committed_at,contentExpiresAt:r.content_expires_at});

export function familyPhotoReportGateEnabled(env: Env): boolean {
 return env.FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED==='YES' && env.GROUP_REPORT_RUNTIME_ENABLED==='YES'
  && env.GROUP_MODERATION_RUNTIME_ENABLED==='YES' && env.REPORT_INGESTION_RUNTIME_ENABLED==='YES';
}
/** One consented encrypted envelope, with an immutable operation ID across retries.
 * Historical delivery authorizes reporting after leaving; it never authorizes
 * retrieving family content or passing a family key to the operator. */
export async function familyPhotoReportAPI(request:Request,env:Env,familyValue:string):Promise<Response>{
 if(request.method!=='POST')fail('method_not_allowed',405);
 if(!familyPhotoReportGateEnabled(env)||!env.MODERATION_MEDIA)fail('family_photo_reports_disabled',503);
 const family=familyUUID(familyValue),{actor,body:bytes}=await authenticateGroupRequest(request,env,1_450_000);
 const runtime=await loadRuntimeGate(env);
 if(!reportIngestionGateOpen(runtime))fail('report_ingestion_runtime_disabled',503);
 const b=parseJsonBody(request,bytes);
 exactKeys(b,['schemaVersion','operationId','assetId','reasonCode','moderationKeyId','ciphertext','ciphertextSHA256','consentedAt']);
 if(b.schemaVersion!==1)fail('invalid_report',400);
 const operation=uuidField(b,'operationId'),asset=uuidField(b,'assetId'),reason=stringField(b,'reasonCode');
 if(!['objectionable','harassment','privacy','other'].includes(reason))fail('invalid_reason',400);
 if(b.moderationKeyId!=='moderation-v2'||!await currentModerationReportKey(env.DB,'moderation-v2'))fail('moderation_key_required');
 const consent=integerField(b,'consentedAt',0,Number.MAX_SAFE_INTEGER),hash=binaryField(b,'ciphertextSHA256',32);
 const cipher=base64urlDecode(stringField(b,'ciphertext'));
 if(cipher.length<29||cipher.length>1048576||await sha256Base64url(cipher)!==hash)fail('invalid_report',400);
 const load=()=>env.DB.prepare('SELECT * FROM family_photo_reports WHERE reporter_device_id=? AND operation_id=?')
  .bind(actor.deviceId,operation).first<Report>();
 const guards=()=>[...groupAuthorizationStatements(env,actor),env.DB.prepare(`SELECT json(CASE WHEN EXISTS(
  SELECT 1 FROM personal_staging_runtime_gate WHERE singleton=1 AND generation=? AND report_ingestion_enabled=1)
  THEN 'true' ELSE 'report_gate_changed' END)`).bind(runtime!.generation)];
 let row=await load();
 if(row&&row.request_hash!==actor.requestHash)fail('idempotency_conflict');
 if(!row){
  if(Math.abs(consent-actor.now)>300)fail('reporter_consent_required');
  const delivery=await env.DB.prepare(`SELECT author_id FROM family_photo_report_deliveries
   WHERE family_id=? AND asset_id=? AND person_id=? AND device_id=? AND author_id<>person_id AND expires_at>unixepoch()`)
   .bind(family,asset,actor.personId,actor.deviceId).first<{author_id:string}>();
  if(!delivery)fail('reportable_photo_not_found',404);
  const id=randomBase64url(16),object=`family/reports/v1/${id}/${randomBase64url(24)}`;
  await env.DB.batch([...guards(),env.DB.prepare(`INSERT INTO family_photo_reports
   (report_id,family_id,asset_id,reporter_person_id,reporter_device_id,author_id,operation_id,request_hash,
   reason_code,moderation_key_id,ciphertext_size,ciphertext_sha256,object_key,state,created_at,upload_expires_at)
   VALUES(?,?,?,?,?,?,?,?,?,'moderation-v2',?,?,?,'reserved',unixepoch(),unixepoch()+3600)`)
   .bind(id,family,asset,actor.personId,actor.deviceId,delivery.author_id,operation,actor.requestHash,reason,cipher.length,hash,object)]);
  row=await load();
 }
 if(!row||row.family_id!==family||row.asset_id!==asset)fail('report_not_found',404);
 if(row.state==='committed'){await env.DB.batch(guards());return reply(row);}
 if(row.state!=='reserved'||row.upload_expires_at<=Math.floor(Date.now()/1000))fail('reservation_expired',410);
 const reserved=row,storage=env.MODERATION_MEDIA;
 const current=async()=>{
  await requireCurrentIdentity(env,actor.personId);
  await env.DB.batch(guards());const r=await load();
  if(!r||r.state!=='reserved'||r.object_key!==reserved.object_key||r.upload_expires_at<=Math.floor(Date.now()/1000))fail('reservation_expired',410);
 };
 try{
 await current();
 const stored=await putGroupUpload(env,storage,row.object_key,cipher,{sha256:base64urlDecode(hash).slice().buffer},current,true)
  ??await storage.head(row.object_key);
 if(!stored||stored.size!==cipher.length||!stored.checksums.sha256
  ||base64urlEncode(new Uint8Array(stored.checksums.sha256))!==hash)fail('stored_object_unavailable',503);
 await env.DB.batch([...guards(),env.DB.prepare(`UPDATE family_photo_reports
  SET state='committed',committed_at=unixepoch(),content_expires_at=unixepoch()+604800
  WHERE report_id=? AND state='reserved' AND upload_expires_at>unixepoch()` ).bind(row.report_id)]);
 row=await load();if(!row||row.state!=='committed')fail('reservation_expired',410);
 return reply(row);
 }catch(error){
  const after=await load();
  if(!after||after.state==='expired'||(after.state!=='committed'&&after.upload_expires_at<=Math.floor(Date.now()/1000)))
   await env.DB.prepare(`INSERT INTO family_photo_report_object_deletions(object_key,report_id)
    VALUES(?,?) ON CONFLICT(object_key) DO NOTHING`).bind(reserved.object_key,reserved.report_id).run();
  throw error;
 }
}
