import { base64urlDecode,randomBase64url,verifyEd25519 } from './encoding';
import { ApiError,jsonResponse } from './errors';
import type { Env } from './env';
import { groupId,groupMutationStatement,groupNonceStatements,requireGroupMember,storedGroupMutation,type GroupActor } from './group-auth';
import { groupFields,loadStoredGroupRoster } from './group-protocol';
import { groupMediaChecks,groupMoment,groupNotificationStatements,groupPhotoMetadata,requireGroupDelivery } from './group-media';
import { groupCursor,groupPage } from './group-reads';
import { binaryField,exactKeys,integerField,uuidField,type JsonRecord } from './validation';

export function groupHeartTranscript(input:{windowId:string;momentId:string;participantId:string;deviceId:string;active:boolean;operationId:string;keyEpoch:number;rosterHash:string}):Uint8Array {
  return groupFields(['NW3.HEART',input.windowId,input.momentId,input.participantId,input.deviceId,input.active?'1':'0',input.operationId,String(input.keyEpoch),base64urlDecode(input.rosterHash,32)]);
}
export async function recordGroupHeart(env:Env,actor:GroupActor,windowId:string,momentId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,['operationId','active','keyEpoch','rosterRevision','reactorSignature']);
  const access=await requireGroupMember(env,actor,windowId),operationId=uuidField(body,'operationId');
  const prior=await storedGroupMutation(env,actor,operationId,{windowId});if(prior!==null)return jsonResponse(prior);
  if(typeof body.active!=='boolean')throw new ApiError(400,'invalid_request','The heart state is invalid.');
  const epoch=integerField(body,'keyEpoch',1,Number.MAX_SAFE_INTEGER),revision=integerField(body,'rosterRevision',1,Number.MAX_SAFE_INTEGER);
  if(access.rotationRequired)throw new ApiError(409,'rotation_pending','The window key must be updated first.');
  if(access.keyEpoch!==epoch || access.revision!==revision)throw new ApiError(409,'stale_epoch','The window state has changed.');
  const row=await groupMoment(env,windowId,momentId);await requireGroupDelivery(env,actor,row);
  const roster=await loadStoredGroupRoster(env.DB,windowId),signature=binaryField(body,'reactorSignature',64);
  if(roster.packet.roster.revision!==revision || !await verifyEd25519(actor.signingPublicKey,signature,groupHeartTranscript({windowId,momentId,
    participantId:access.participantId,deviceId:actor.deviceId,active:body.active,operationId,keyEpoch:epoch,rosterHash:roster.hash})))
    throw new ApiError(400,'invalid_signature','The heart signature could not be verified.');
  const old=await env.DB.prepare('SELECT active FROM group_moment_hearts WHERE moment_id=? AND participant_id=?')
    .bind(momentId,access.participantId).first<{active:number}>();
  const response={operationId,momentId,reactorParticipantId:access.participantId,active:body.active,updatedAt:actor.now,serverNow:actor.now};
  const statements=[...groupNonceStatements(env,actor,{windowId,expectedRevision:revision}),...groupMediaChecks(env,actor,momentId,'heart')];
  // New operation IDs with the same desired state do not generate another
  // heart, quota charge or notification. Signature still authenticates intent.
  if((old?.active===1)!==body.active) {
    if(body.active)statements.push(env.DB.prepare(`INSERT INTO group_heart_usage VALUES (?,?,?,1)
      ON CONFLICT(space_id,participant_id,day_key) DO UPDATE SET used=used+1`).bind(windowId,access.participantId,Math.floor(actor.now/86400)));
    statements.push(env.DB.prepare(`INSERT INTO group_moment_hearts VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(moment_id,participant_id)
      DO UPDATE SET device_id=excluded.device_id,active=excluded.active,key_epoch=excluded.key_epoch,roster_revision=excluded.roster_revision,
      roster_hash=excluded.roster_hash,operation_id=excluded.operation_id,signature=excluded.signature,updated_at=excluded.updated_at`)
      .bind(momentId,access.participantId,actor.deviceId,body.active?1:0,epoch,revision,roster.hash,operationId,signature,actor.now));
    if(body.active && access.participantId!==row.sender_participant_id) {
      const eventId=randomBase64url(16);
      statements.push(...groupNotificationStatements(env,actor,row,'heart',eventId,access.participantId),
        env.DB.prepare(`INSERT INTO group_notification_deliveries SELECT ?,d.device_id,s.token_digest,s.generation,'pending',0,?,NULL,NULL
          FROM group_moment_deliveries d JOIN group_push_subscriptions s ON s.space_id=? AND s.device_id=d.device_id
          WHERE d.moment_id=? AND d.participant_id=? AND d.device_id<>? AND d.state IN ('pending','acknowledged')
            AND d.access_expires_at>? AND s.expires_at>? ON CONFLICT(event_id,device_id) DO NOTHING`)
          .bind(eventId,actor.now,windowId,momentId,row.sender_participant_id,actor.deviceId,actor.now,actor.now));
    }
  }
  statements.push(groupMutationStatement(env,actor,operationId,response));
  await env.DB.batch(statements);return jsonResponse(response);
}
export async function listGroupHearts(env:Env,actor:GroupActor,windowId:string,momentId:string,body:JsonRecord):Promise<Response> {
  const access=await requireGroupMember(env,actor,windowId),row=await groupMoment(env,windowId,momentId);await requireGroupDelivery(env,actor,row);
  const scope=`hearts:${windowId}:${momentId}:${actor.deviceId}`,page=groupPage(body,scope);
  const metadata=(await groupPhotoMetadata(env,[row],actor.deviceId))[0];
  const all=(metadata?.hearts as {reactorParticipantId:string}[]??[]).filter(h=>h.reactorParticipantId>page.after)
    .sort((a,b)=>a.reactorParticipantId<b.reactorParticipantId?-1:1),items=all.slice(0,page.limit);
  await env.DB.batch([...groupNonceStatements(env,actor,{windowId,expectedRevision:access.revision}),...groupMediaChecks(env,actor,momentId,'read')]);
  return jsonResponse({items,next:all.length>page.limit?groupCursor(scope,items.at(-1)!.reactorParticipantId):null,serverNow:actor.now});
}
export async function setGroupBlock(env:Env,actor:GroupActor,windowId:string,participantId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,['operationId','active']);
  const access=await requireGroupMember(env,actor,windowId),operationId=uuidField(body,'operationId');
  const prior=await storedGroupMutation(env,actor,operationId,{windowId});if(prior!==null)return jsonResponse(prior);
  if(typeof body.active!=='boolean' || participantId===access.participantId)throw new ApiError(400,'invalid_request','The block state is invalid.');
  const target=await env.DB.prepare('SELECT 1 AS present FROM group_members WHERE space_id=? AND participant_id=?').bind(windowId,groupId(participantId)).first();
  if(!target)throw new ApiError(404,'not_found','The participant was not found.');
  const response={operationId,participantId,active:body.active,serverNow:actor.now};
  await env.DB.batch([...groupNonceStatements(env,actor,{windowId,expectedRevision:access.revision}),
    env.DB.prepare(`INSERT INTO group_participant_blocks VALUES (?,?,?,?,?) ON CONFLICT(space_id,blocker_id,blocked_id)
      DO UPDATE SET active=excluded.active,updated_at=excluded.updated_at`).bind(windowId,access.participantId,participantId,body.active?1:0,actor.now),
    groupMutationStatement(env,actor,operationId,response)]);
  return jsonResponse(response);
}
