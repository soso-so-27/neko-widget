import {authenticateGroupRequest,groupAuthorizationStatements} from './group-auth';
import {familyUUID,verifyFamilyOperation} from './family-notebook-crypto';
import {state,checks,roster} from './family-notebook-history';
import {gate,safeFailure} from './family-notebook-payer';
import {sha256Base64url} from './encoding';
import {asObject,exactKeys,integerField,uuidField,binaryField} from './validation';
import {parseJsonBody,requireEmptyBody} from './http';
import {ApiError,jsonResponse} from './errors';
import type {Env} from './env';

interface Asset {asset_id:string;family_id:string;slot_id:string;operation_id:string;person_id:string;device_id:string;
 revision:number;key_epoch:number;roster_hash:string;object_key:string;bytes:number;hash:string;state:string;expires_at:number;request_hash:string}
function fail(code:string,status=409):never{throw new ApiError(status,code,'Representative photo is unavailable.');}
async function asset(env:Env,family:string,id:string):Promise<Asset>{
 const row=await env.DB.prepare('SELECT * FROM family_representative_assets WHERE family_id=? AND asset_id=?').bind(family,id).first<Asset>();
 if(!row) fail('access_unavailable',404);return row;
}
const receipt=(a:Asset)=>({schemaVersion:1,assetId:a.asset_id,uploadId:a.asset_id,expiresAt:a.expires_at,reservedRevision:a.revision,state:a.state});
function photoChecks(env:Env,a:Asset,mode:'upload'|'commit'):D1PreparedStatement[]{
 const id=crypto.randomUUID();return [env.DB.prepare('INSERT INTO family_representative_commit_checks VALUES (?,?,?,?,?,?)').bind(id,a.family_id,a.slot_id,a.asset_id,a.revision-1,mode),env.DB.prepare('DELETE FROM family_representative_commit_checks WHERE id=?').bind(id)];
}
export async function familyRepresentativePhoto(request:Request,env:Env):Promise<Response>{
 try{
  await gate(env);
  if(env.FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED!=='YES'||!env.MEDIA) fail('photo_feature_disabled',503);
  const match=/^\/v3\/family-notebooks\/([0-9a-f-]+)\/representative-photos\/(slots|uploads|assets)(?:\/([0-9a-f-]+))?(?:\/(commit))?$/.exec(new URL(request.url).pathname);
  if(!match) fail('access_unavailable',404);
  const family=familyUUID(match[1]),route=match[2],id=match[3]===undefined?undefined:familyUUID(match[3]),commit=match[4]!==undefined;
  const {actor,body:bytes}=await authenticateGroupRequest(request,env,1_500_000);
  const current=await state(env,actor,family);
  const guards=(mode:'read'|'operation')=>[...groupAuthorizationStatements(env,actor),...checks(env,actor,family,current.generation,current.epoch,mode)];
  if(request.method==='GET'){
   requireEmptyBody(bytes);
   await env.DB.batch(guards('read'));
   if(route==='slots'&&!id){
    const rows=await env.DB.prepare(`SELECT s.slot_id AS slotId,s.revision,s.asset_id AS assetId,a.hash AS ciphertextSHA256,a.bytes AS ciphertextBytes,a.key_epoch AS keyEpoch,a.person_id AS authorId FROM family_representative_slots s LEFT JOIN family_representative_assets a ON a.asset_id=s.asset_id WHERE s.family_id=? AND s.state='active' ORDER BY s.slot_id LIMIT 10`).bind(family).all();
    return jsonResponse({schemaVersion:1,slots:rows.results});
   }
   if(route==='assets'&&id){
    const a=await asset(env,family,id);if(a.state!=='active')fail('photo_retired',410);
    const object=await env.MEDIA.get(a.object_key);if(!object)fail('temporarily_unavailable',503);
    // Fetch first, then recheck membership, epoch and current pointer before returning bytes.
    const batch=await env.DB.batch([...guards('read'),env.DB.prepare(`SELECT 1 ok FROM family_representative_slots s JOIN family_representative_assets a ON a.asset_id=s.asset_id WHERE s.family_id=? AND s.asset_id=? AND s.state='active' AND a.state='active'`).bind(family,id)]);
    if(batch.at(-1)!.results.length!==1)fail('photo_retired',410);
    return new Response(object.body,{headers:{'content-type':'application/octet-stream','cache-control':'private, no-store'}});
   }
   fail('access_unavailable',404);
  }
  if(request.method==='POST'&&route==='uploads'&&!id){
   const b=parseJsonBody(request,bytes);exactKeys(b,['schemaVersion','operationId','slotId','assetId','expectedRevision','expectedGeneration','keyEpoch','rosterHash','ciphertextBytes','ciphertextSHA256']);
   if(b.schemaVersion!==1)fail('photo_protocol_upgrade_required');
   const operation=uuidField(b,'operationId'),slot=uuidField(b,'slotId'),assetId=uuidField(b,'assetId');
   const revision=integerField(b,'expectedRevision',0,1_000_000_000),epoch=integerField(b,'keyEpoch',1,1_000_000_000),generation=integerField(b,'expectedGeneration',1,1_000_000_000);
   binaryField(b,'rosterHash',32);binaryField(b,'ciphertextSHA256',32);const size=integerField(b,'ciphertextBytes',29,200028);
   const old=await env.DB.prepare('SELECT * FROM family_representative_assets WHERE family_id=? AND operation_id=?').bind(family,operation).first<Asset>();
   if(old){if(old.person_id!==actor.personId||old.device_id!==actor.deviceId||old.request_hash!==actor.requestHash)fail('idempotency_conflict');await env.DB.batch(guards('read'));return jsonResponse(receipt(old));}
   if(generation!==current.generation||epoch!==current.epoch||b.rosterHash!==current.roster_hash)fail('key_epoch_pending');
   const expires=actor.now+86400,key=`family-representative/v1/${family}/${assetId}`;
   await env.DB.batch([...guards('operation'),
    env.DB.prepare(`INSERT INTO family_representative_slots VALUES (?,?,0,NULL,'active') ON CONFLICT(family_id,slot_id) DO NOTHING`).bind(family,slot),
    env.DB.prepare(`INSERT INTO family_representative_assets VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'reserved',?,?,?)`).bind(assetId,family,slot,operation,actor.personId,actor.deviceId,revision+1,epoch,b.rosterHash,key,size,b.ciphertextSHA256,actor.now,expires,actor.requestHash)]);
   return jsonResponse(receipt(await asset(env,family,assetId)),201);
  }
  if(route==='uploads'&&id){
   const a=await asset(env,family,id);
   if(a.person_id!==actor.personId||a.device_id!==actor.deviceId)fail('access_unavailable',404);
   // A committed retry remains a receipt read even after its upload lease or epoch ended.
   if(request.method==='POST'&&commit){
    const b=parseJsonBody(request,bytes);exactKeys(b,['operationId','expectedGeneration','expectedRevision','payload']);
    const operationId=uuidField(b,'operationId');
    const old=await env.DB.prepare('SELECT request_hash,result FROM family_notebook_crypto_receipts WHERE actor_device_id=? AND operation_id=?').bind(actor.deviceId,operationId).first<{request_hash:string;result:string}>();
    if(old){if(old.request_hash!==actor.requestHash)fail('idempotency_conflict');await env.DB.batch(guards('read'));return jsonResponse(JSON.parse(old.result));}
   }
   if(a.expires_at<=actor.now||['retired','deleted'].includes(a.state))fail('photo_retired',410);
   if(a.key_epoch!==current.epoch||a.roster_hash!==current.roster_hash)fail('key_epoch_pending');
   if(request.method==='PUT'&&!commit){
    if(bytes.length!==a.bytes||await sha256Base64url(bytes)!==a.hash)fail('invalid_photo_payload',422);
    await env.DB.batch(guards('operation'));
    await env.MEDIA.put(a.object_key,bytes);
    // A late PUT must not resurrect a retired object: cleanup remains pending until checked.
    try { await env.DB.batch([...checks(env,actor,family,current.generation,current.epoch,'operation'),...photoChecks(env,a,'upload'),env.DB.prepare(`UPDATE family_representative_assets SET state='uploaded' WHERE asset_id=? AND state IN ('reserved','uploaded')`).bind(id)]); }
    catch(error) {
     const after=await asset(env,family,id);
     if(after.state==='retired'||after.state==='deleted') {
      // Cleanup may have completed while this PUT was still writing. Reopen
      // its cleanup claim before deleting, so a failed R2 delete is retried.
      await env.DB.prepare("UPDATE family_representative_assets SET state='retired' WHERE asset_id=? AND state IN ('retired','deleted')").bind(id).run();
      await env.MEDIA.delete(after.object_key);
      await env.DB.prepare("UPDATE family_representative_assets SET state='deleted' WHERE asset_id=? AND state='retired'").bind(id).run();
     }
     throw error;
    }
    return jsonResponse({schemaVersion:1,assetId:id,uploaded:true});
   }
   if(request.method==='POST'&&commit){
    const b=parseJsonBody(request,bytes);exactKeys(b,['operationId','expectedGeneration','expectedRevision','payload']);
    const operationId=uuidField(b,'operationId'),generation=integerField(b,'expectedGeneration',1,1_000_000_000),prior=integerField(b,'expectedRevision',0,1_000_000_000);
    if(generation!==current.generation||prior!==a.revision-1)fail('revision_conflict');
    const r=await roster(env,family,current.epoch),packet=await verifyFamilyOperation(asObject(b.payload),r);
    if(packet.operationId.toLowerCase()!==operationId||packet.deviceId!==actor.deviceId||packet.personId!==actor.personId)fail('invalid_photo_payload',422);
    const old=await env.DB.prepare('SELECT request_hash,result FROM family_notebook_crypto_receipts WHERE actor_device_id=? AND operation_id=?').bind(actor.deviceId,operationId).first<{request_hash:string;result:string}>();
    if(old){if(old.request_hash!==actor.requestHash)fail('idempotency_conflict');await env.DB.batch(guards('read'));return jsonResponse(JSON.parse(old.result));}
    if(a.state!=='uploaded')fail('invalid_photo_payload',422);
    const response={schemaVersion:1,assetId:id,revision:a.revision,operationId};
    await env.DB.batch([...guards('operation'),...photoChecks(env,a,'commit'),
     env.DB.prepare(`INSERT INTO family_notebook_write_policy VALUES (?,1) ON CONFLICT(family_id) DO NOTHING`).bind(family),
     env.DB.prepare(`UPDATE family_representative_assets SET state='retired',expires_at=? WHERE asset_id=(SELECT asset_id FROM family_representative_slots WHERE family_id=? AND slot_id=?) AND state='active'`).bind(actor.now,family,a.slot_id),
     env.DB.prepare(`UPDATE family_representative_slots SET asset_id=?,revision=? WHERE family_id=? AND slot_id=? AND state='active' AND revision=?`).bind(id,a.revision,family,a.slot_id,prior),
     env.DB.prepare(`UPDATE family_representative_assets SET state='active' WHERE asset_id=? AND state='uploaded'`).bind(id),
     env.DB.prepare(`INSERT INTO family_notebook_crypto_operations SELECT ?,COALESCE(MAX(sequence),0)+1,?,?,?,?,? FROM family_notebook_crypto_operations WHERE family_id=?`).bind(family,operationId,current.epoch,actor.personId,actor.deviceId,JSON.stringify(packet),family),
     env.DB.prepare(`INSERT INTO family_notebook_crypto_receipts VALUES (?,?,?,?,'operation',?,?)`).bind(actor.deviceId,operationId,actor.personId,family,actor.requestHash,JSON.stringify(response))]);
    return jsonResponse(response);
   }
  }
  fail('access_unavailable',404);
 }catch(error){
  if(error instanceof ApiError)throw error;
  const text=error instanceof Error?error.message:'';
  for(const code of ['photo_slots_full','photo_daily_limit','photo_cleanup_pending','revision_conflict'])if(text.includes(code))fail(code);
  return safeFailure(error);
 }
}


/** Only this feature's recorded objects; never enumerate/delete unrelated R2 keys. */
export async function cleanupFamilyRepresentativePhotos(env:Env,now=Math.floor(Date.now()/1000)):Promise<number>{
 if(env.FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED!=='YES'||!env.MEDIA)return 0;
 const rows=await env.DB.prepare(`SELECT * FROM family_representative_assets WHERE state='retired' OR (state IN ('reserved','uploaded') AND expires_at<=?) ORDER BY expires_at LIMIT 20`).bind(now).all<Asset>();
 let removed=0;
 for(const a of rows.results){
  // Expired reservations cannot commit. Keep quota charged until deletion succeeds.
  await env.DB.prepare(`UPDATE family_representative_assets SET state='retired' WHERE asset_id=? AND (state='retired' OR (state IN ('reserved','uploaded') AND expires_at<=?))`).bind(a.asset_id,now).run();
  const current=await asset(env,a.family_id,a.asset_id);if(current.state!=='retired')continue;
  try {await env.MEDIA.delete(a.object_key);}catch{continue;}
  await env.DB.prepare("UPDATE family_representative_assets SET state='deleted' WHERE asset_id=? AND state='retired'").bind(a.asset_id).run();removed++;
 }
 return removed;
}
