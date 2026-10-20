import { base64urlDecode,randomBase64url,sha256Base64url,verifyEd25519 } from './encoding';
import { ApiError,jsonResponse } from './errors';
import type { Env } from './env';
import { groupAuthorizationStatements,groupId,groupMutationStatement,groupNonceStatements,requireGroupMember,storedGroupMutation,type GroupActor } from './group-auth';
import { groupFields,loadStoredGroupRoster } from './group-protocol';
import { groupCursor,groupPage } from './group-reads';
import { binaryField,exactKeys,integerField,opaqueId,stringField,uuidField,type JsonRecord } from './validation';

export const GROUP_MAX_CIPHERTEXT=1048576;
export const GROUP_UPLOAD_SECONDS=1800;
export const GROUP_UNRECEIVED_SECONDS=30*86400;
export const GROUP_ACK_SECONDS=7*86400;
export interface GroupMomentRow {
  id:string;space_id:string;client_moment_id:string;sender_participant_id:string;sender_device_id:string;
  key_epoch:number;roster_revision:number;roster_hash:string;ciphertext_size:number;ciphertext_sha256:string;sender_signature:string;
  kind:string;state:string;object_key:string;created_at:number;upload_expires_at:number;committed_at:number|null;unreceived_expires_at:number;expired_at:number|null;
}
function unavailable(code:string,status=409):never { throw new ApiError(status,code,'The group photo is not available.'); }
function bucket(env:Env):R2Bucket { if(!env.MEDIA) unavailable('unavailable',503);return env.MEDIA; }
export async function groupMoment(env:Env,windowId:string,momentId:string):Promise<GroupMomentRow> {
  const row=await env.DB.prepare('SELECT * FROM group_moments WHERE id=? AND space_id=?').bind(opaqueId(momentId,'moment'),groupId(windowId)).first<GroupMomentRow>();
  if(!row) unavailable('not_found',404);return row;
}
export function groupMediaChecks(env:Env,actor:GroupActor,momentId:string,purpose:'read'|'heart'|'upload'|'commit'):D1PreparedStatement[] {
  const id=crypto.randomUUID();
  return [env.DB.prepare('INSERT INTO group_media_access_checks VALUES (?,?,?,?,?)').bind(id,actor.deviceId,momentId,Math.floor(Date.now()/1000),purpose),
    env.DB.prepare('DELETE FROM group_media_access_checks WHERE id=?').bind(id)];
}
export async function requireGroupDelivery(env:Env,actor:GroupActor,row:GroupMomentRow):Promise<{accessExpiresAt:number}> {
  const result=await env.DB.prepare(`SELECT delivery.access_expires_at AS accessExpiresAt FROM group_moment_deliveries delivery
      JOIN group_window_devices d ON d.space_id=? AND d.device_id=delivery.device_id
      JOIN group_members m ON m.participant_id=d.participant_id
      WHERE delivery.moment_id=? AND delivery.device_id=? AND delivery.state IN ('pending','acknowledged')
        AND delivery.access_expires_at>? AND d.state='active' AND m.state='active'
        AND delivery.roster_revision>=d.added_revision AND delivery.roster_revision>=m.joined_revision`)
    .bind(row.space_id,row.id,actor.deviceId,actor.now).first<{accessExpiresAt:number}>();
  if(!result || row.state!=='committed' || row.unreceived_expires_at<=actor.now) unavailable('delivery_expired',410);
  return result;
}
export async function groupPhotoProof(actor:GroupActor,windowId:string,participantId:string,body:JsonRecord,rosterHash:string):Promise<void> {
  const size=integerField(body,'ciphertextSize',29,GROUP_MAX_CIPHERTEXT),clientId=opaqueId(stringField(body,'clientMomentId'),'client moment');
  const hash=binaryField(body,'ciphertextSHA256',32),signature=binaryField(body,'senderSignature',64);
  const epoch=integerField(body,'keyEpoch',1,Number.MAX_SAFE_INTEGER);
  const aad=groupFields(['NW3.PHOTO',windowId,clientId,String(epoch),base64urlDecode(rosterHash,32),participantId,actor.deviceId,String(size)]);
  if(!await verifyEd25519(actor.signingPublicKey,signature,groupFields(['NW3.PHOTO.SIGN',aad,base64urlDecode(hash,32)]))) unavailable('invalid_signature',400);
}
export async function reserveGroupPhoto(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,['operationId','clientMomentId','keyEpoch','rosterRevision','ciphertextSize','ciphertextSHA256','senderSignature','kind']);
  const access=await requireGroupMember(env,actor,windowId),operationId=uuidField(body,'operationId');
  const prior=await storedGroupMutation(env,actor,operationId,{windowId});if(prior!==null)return jsonResponse(prior);
  if(body.kind!=='photo') unavailable('invalid_request',400);
  const revision=integerField(body,'rosterRevision',1,Number.MAX_SAFE_INTEGER),epoch=integerField(body,'keyEpoch',1,Number.MAX_SAFE_INTEGER);
  if(access.rotationRequired) unavailable('rotation_pending');
  if(access.revision!==revision || access.keyEpoch!==epoch) unavailable('stale_epoch');
  const roster=await loadStoredGroupRoster(env.DB,windowId);
  if(roster.packet.roster.revision!==revision || !roster.packet.roster.members.some(m=>m.participantId===access.participantId && m.devices.some(d=>d.id===actor.deviceId))) unavailable('stale_revision');
  await groupPhotoProof(actor,windowId,access.participantId,body,roster.hash);
  const id=randomBase64url(16),hash=binaryField(body,'ciphertextSHA256',32),expires=actor.now+GROUP_UPLOAD_SECONDS;
  const response={operationId,momentId:id,uploadExpiresAt:expires,serverNow:actor.now};
  await env.DB.batch([...groupNonceStatements(env,actor,{windowId,expectedRevision:revision}),
    env.DB.prepare(`INSERT INTO group_moments VALUES (?,?,?,?,?,?,?,?,?,?,?,'photo','reserved',?,?,?,NULL,?,NULL)`)
      .bind(id,windowId,body.clientMomentId,access.participantId,actor.deviceId,epoch,revision,roster.hash,body.ciphertextSize,hash,body.senderSignature,
        `groups/v3/${windowId}/${id}/${hash}`,actor.now,expires,actor.now+GROUP_UNRECEIVED_SECONDS),
    groupMutationStatement(env,actor,operationId,response)]);
  return jsonResponse(response,201);
}

export async function uploadGroupPhoto(env:Env,actor:GroupActor,windowId:string,momentId:string,bytes:Uint8Array):Promise<Response> {
  await requireGroupMember(env,actor,windowId);
  const row=await groupMoment(env,windowId,momentId);
  if(row.sender_device_id!==actor.deviceId) unavailable('not_found',404);
  if(bytes.length!==row.ciphertext_size || await sha256Base64url(bytes)!==row.ciphertext_sha256) unavailable('hash_mismatch',400);
  // Recovering a lost commit response must not rewrite a committed object or
  // republish its deliveries, including after a later roster/key transition.
  if(row.state==='committed') {
    await env.DB.batch(groupNonceStatements(env,actor,{windowId}));
    return jsonResponse({momentId,state:'committed',serverNow:actor.now});
  }
  await env.DB.batch([...groupNonceStatements(env,actor,{windowId,expectedRevision:row.roster_revision}),...groupMediaChecks(env,actor,momentId,'upload')]);
  const storage=bucket(env);
  const written=await storage.put(row.object_key,bytes,{onlyIf:{etagDoesNotMatch:'*'},httpMetadata:{contentType:'application/octet-stream'},
    customMetadata:{digest:row.ciphertext_sha256,scope:'group-v3'}});
  if(written===null) {
    const existing=await storage.get(row.object_key);
    if(!existing || existing.size!==row.ciphertext_size || await sha256Base64url(new Uint8Array(await existing.arrayBuffer()))!==row.ciphertext_sha256) unavailable('hash_mismatch',400);
  }
  await env.DB.batch([...groupAuthorizationStatements(env,actor,{windowId,expectedRevision:row.roster_revision}),...groupMediaChecks(env,actor,momentId,'upload'),
    env.DB.prepare("UPDATE group_moments SET state='uploaded' WHERE id=? AND state='reserved'").bind(momentId)]);
  return jsonResponse({momentId,state:'uploaded',serverNow:Math.floor(Date.now()/1000)});
}

export function groupNotificationStatements(env:Env,actor:GroupActor,row:GroupMomentRow,kind:'new_moment'|'heart',eventId:string,actorParticipantId=row.sender_participant_id):D1PreparedStatement[] {
  return [env.DB.prepare('INSERT INTO group_notification_events VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING')
    .bind(eventId,row.space_id,row.id,kind,actorParticipantId,actor.deviceId,actor.now,actor.now+86400)];
}
export async function commitGroupPhoto(env:Env,actor:GroupActor,windowId:string,momentId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,['operationId','expectedRevision','keyEpoch','ciphertextSHA256']);
  await requireGroupMember(env,actor,windowId);
  const operationId=uuidField(body,'operationId'),prior=await storedGroupMutation(env,actor,operationId,{windowId});if(prior!==null)return jsonResponse(prior);
  const row=await groupMoment(env,windowId,momentId);
  if(row.sender_device_id!==actor.deviceId) unavailable('not_found',404);
  if(binaryField(body,'ciphertextSHA256',32)!==row.ciphertext_sha256 || body.expectedRevision!==row.roster_revision || body.keyEpoch!==row.key_epoch) unavailable('hash_mismatch',400);
  const response={operationId,momentId,windowId,revision:row.roster_revision,keyEpoch:row.key_epoch,state:'committed',
    senderParticipantId:row.sender_participant_id,senderDeviceId:row.sender_device_id,createdAt:row.committed_at??actor.now,serverNow:actor.now};
  if(row.state==='committed') {
    await env.DB.batch([...groupNonceStatements(env,actor,{windowId}),groupMutationStatement(env,actor,operationId,response)]);return jsonResponse(response);
  }
  const object=await bucket(env).head(row.object_key);
  if(!object || object.size!==row.ciphertext_size || object.customMetadata?.digest!==row.ciphertext_sha256) unavailable('upload_required');
  await env.DB.batch([...groupNonceStatements(env,actor,{windowId,expectedRevision:row.roster_revision}),...groupMediaChecks(env,actor,momentId,'commit'),
    env.DB.prepare("UPDATE group_moments SET state='committed',committed_at=? WHERE id=? AND state='uploaded'").bind(actor.now,momentId),
    env.DB.prepare(`INSERT INTO group_moment_deliveries SELECT ?,d.device_id,m.participant_id,?,'pending',?,NULL
      FROM group_window_devices d JOIN group_members m ON m.participant_id=d.participant_id
      JOIN group_person_devices p ON p.id=d.device_id JOIN group_people person ON person.id=p.person_id
      WHERE d.space_id=? AND d.state='active' AND m.state='active' AND p.state='active' AND person.state='active'
        AND NOT EXISTS (SELECT 1 FROM group_participant_blocks b WHERE b.space_id=d.space_id AND b.active=1
          AND ((b.blocker_id=m.participant_id AND b.blocked_id=?) OR (b.blocked_id=m.participant_id AND b.blocker_id=?)))
      ON CONFLICT(moment_id,device_id) DO NOTHING`).bind(momentId,row.roster_revision,row.unreceived_expires_at,windowId,row.sender_participant_id,row.sender_participant_id),
    ...groupNotificationStatements(env,actor,row,'new_moment',momentId),
    env.DB.prepare(`INSERT INTO group_notification_deliveries SELECT ?,d.device_id,s.token_digest,s.generation,'pending',0,?,NULL,NULL
      FROM group_moment_deliveries d JOIN group_push_subscriptions s ON s.space_id=? AND s.device_id=d.device_id
      WHERE d.moment_id=? AND d.device_id<>? AND s.expires_at>? ON CONFLICT(event_id,device_id) DO NOTHING`)
      .bind(momentId,actor.now,windowId,momentId,actor.deviceId,actor.now),
    groupMutationStatement(env,actor,operationId,response)]);
  return jsonResponse(response);
}

export async function groupPhotoMetadata(env:Env,rows:readonly GroupMomentRow[],deviceId:string):Promise<Record<string,unknown>[]> {
  if(rows.length===0)return [];
  const hearts=await env.DB.prepare(`SELECT h.moment_id,h.participant_id AS reactorParticipantId,h.device_id AS reactorDeviceId,
      h.active,h.key_epoch AS keyEpoch,h.roster_revision AS rosterRevision,h.roster_hash AS rosterHash,h.operation_id AS operationId,
      h.signature AS reactorSignature,h.updated_at AS updatedAt FROM group_moment_hearts h WHERE h.moment_id IN (${rows.map(()=>'?').join(',')})`)
    .bind(...rows.map(r=>r.id)).all<{moment_id:string;active:number}>();
  const deliveries=await env.DB.prepare(`SELECT moment_id,access_expires_at FROM group_moment_deliveries WHERE device_id=? AND moment_id IN (${rows.map(()=>'?').join(',')})`)
    .bind(deviceId,...rows.map(r=>r.id)).all<{moment_id:string;access_expires_at:number}>();
  return rows.map(r=>({id:r.id,clientMomentId:r.client_moment_id,senderParticipantId:r.sender_participant_id,senderDeviceId:r.sender_device_id,
    keyEpoch:r.key_epoch,rosterRevision:r.roster_revision,rosterHash:r.roster_hash,ciphertextSize:r.ciphertext_size,ciphertextSHA256:r.ciphertext_sha256,
    senderSignature:r.sender_signature,createdAt:r.committed_at,accessExpiresAt:deliveries.results.find(d=>d.moment_id===r.id)?.access_expires_at,
    kind:r.kind,hearts:hearts.results.filter(h=>h.moment_id===r.id).map(({moment_id,...h})=>({...h,active:h.active===1}))}));
}
export async function listGroupPhotos(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  const access=await requireGroupMember(env,actor,windowId),scope=`photos:${windowId}:${actor.deviceId}`,page=groupPage(body,scope);
  const result=await env.DB.prepare(`SELECT p.* FROM group_moments p JOIN group_moment_deliveries d ON d.moment_id=p.id
      JOIN group_window_devices wd ON wd.space_id=p.space_id AND wd.device_id=d.device_id JOIN group_members m ON m.participant_id=wd.participant_id
      WHERE p.space_id=? AND d.device_id=? AND p.state='committed' AND p.unreceived_expires_at>? AND d.access_expires_at>?
        AND d.state IN ('pending','acknowledged') AND wd.state='active' AND m.state='active'
        AND d.roster_revision>=wd.added_revision AND d.roster_revision>=m.joined_revision
        AND p.id>? AND NOT EXISTS (SELECT 1 FROM group_participant_blocks b WHERE b.space_id=p.space_id AND b.active=1
          AND ((b.blocker_id=m.participant_id AND b.blocked_id=p.sender_participant_id) OR (b.blocked_id=m.participant_id AND b.blocker_id=p.sender_participant_id)))
      ORDER BY p.id LIMIT ?`).bind(windowId,actor.deviceId,actor.now,actor.now,page.after,page.limit+1).all<GroupMomentRow>();
  const rows=result.results.slice(0,page.limit),items=await groupPhotoMetadata(env,rows,actor.deviceId);
  // The scoped inventory query is the metadata read's linearization point.
  // Recheck the caller at response time; actual ciphertext downloads separately
  // recheck their individual delivery after reading R2. No per-photo writes
  // or full-history scans are needed for a metadata page.
  await env.DB.batch(groupNonceStatements(env,actor,{windowId,expectedRevision:access.revision}));
  return jsonResponse({items,next:result.results.length>page.limit?groupCursor(scope,rows.at(-1)!.id):null,revision:access.revision,serverNow:actor.now});
}
export async function getGroupPhoto(env:Env,actor:GroupActor,windowId:string,momentId:string,download:boolean):Promise<Response> {
  const access=await requireGroupMember(env,actor,windowId),row=await groupMoment(env,windowId,momentId);await requireGroupDelivery(env,actor,row);
  let bytes:Uint8Array|undefined;
  if(download) {
    const object=await bucket(env).get(row.object_key);
    if(!object || object.size!==row.ciphertext_size) unavailable('unavailable',503);
    bytes=new Uint8Array(await object.arrayBuffer());if(await sha256Base64url(bytes)!==row.ciphertext_sha256) unavailable('unavailable',503);
  }
  const items=download?[]:await groupPhotoMetadata(env,[row],actor.deviceId);
  await env.DB.batch([...groupNonceStatements(env,actor,{windowId,expectedRevision:access.revision}),...groupMediaChecks(env,actor,momentId,'read')]);
  if(bytes) return new Response(bytes.slice().buffer,{headers:{'Content-Type':'application/octet-stream','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
  return jsonResponse({moment:items[0],serverNow:actor.now});
}
export async function acknowledgeGroupPhoto(env:Env,actor:GroupActor,windowId:string,momentId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,['operationId','ciphertextSHA256']);
  const access=await requireGroupMember(env,actor,windowId),operationId=uuidField(body,'operationId');
  const prior=await storedGroupMutation(env,actor,operationId,{windowId});if(prior!==null)return jsonResponse(prior);
  const row=await groupMoment(env,windowId,momentId);await requireGroupDelivery(env,actor,row);
  if(binaryField(body,'ciphertextSHA256',32)!==row.ciphertext_sha256)unavailable('hash_mismatch',400);
  const response={operationId,momentId,state:'acknowledged',serverNow:actor.now};
  await env.DB.batch([...groupNonceStatements(env,actor,{windowId,expectedRevision:access.revision}),...groupMediaChecks(env,actor,momentId,'read'),
    env.DB.prepare(`UPDATE group_moment_deliveries SET state='acknowledged',acknowledged_at=?,access_expires_at=MIN(access_expires_at,?)
      WHERE moment_id=? AND device_id=? AND state='pending'`).bind(actor.now,actor.now+GROUP_ACK_SECONDS,momentId,actor.deviceId),
    groupMutationStatement(env,actor,operationId,response)]);
  return jsonResponse(response);
}
