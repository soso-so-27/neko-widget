import { base64urlDecode, randomBase64url, sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import { groupId, groupMutationStatement, groupNonceStatements, requireGroupMember, storedGroupMutation, type GroupActor } from "./group-auth";
import { groupDeviceKeyHash } from "./group-identities";
import { groupDeviceAuthorization, groupFields, type GroupRosterDevice } from "./group-protocol";
import { groupCipher, groupExpected } from "./group-windows";
import { asObject, binaryField, exactKeys, stringField, uuidField, type JsonRecord } from "./validation";
import { enforceRateLimit } from './http';
import { loadStoredGroupRoster } from './group-protocol';

export interface GroupJoinRow {
  id:string; space_id:string; invitation_id:string; person_id:string; candidate_device_id:string;
  signed_request:string; state:string; expires_at:number; result_revision:number|null;
}
// The additive migration is optional for older databases; once installed the
// DB triggers, not this informational response, enforce final admission.
export async function groupAdmissionPause(env:Env,windowId:string):Promise<Set<string>|null> {
  if(!await env.DB.prepare("SELECT 1 FROM sqlite_master WHERE type='view' AND name='group_invitation_state'").first())return null;
  if((await env.DB.prepare('SELECT paused FROM group_invitation_state').first<{paused:number}>())?.paused!==1)return null;
  const active=await env.DB.prepare("SELECT person_id FROM group_members WHERE space_id=? AND state='active'").bind(windowId).all<{person_id:string}>();
  return new Set(active.results.map(row=>row.person_id));
}
async function joinRequestResponse(env:Env,actor:GroupActor,windowId:string,value:unknown,status=200):Promise<Response> {
  const response=asObject(value);
  // Keep the original receipt/operation unchanged on a response-loss retry.
  // Only the informational flag is fresh; a resolved, expired or cleaned-up
  // request must not acquire a pause warning from its original pending receipt.
  const row=await env.DB.prepare(`SELECT state,expires_at FROM group_join_requests
    WHERE id=? AND space_id=? AND person_id=? AND candidate_device_id=?`)
    .bind(stringField(response,'requestId'),windowId,actor.personId,actor.deviceId).first<{state:string;expires_at:number}>();
  const active=row?.state==='pending'&&row.expires_at>actor.now?await groupAdmissionPause(env,windowId):null;
  return jsonResponse({...response,admissionPaused:active!==null&&!active.has(actor.personId)},status);
}
export async function groupInvitation(env:Env,windowId:string,invitationId:string,now:number) {
  const value=await env.DB.prepare(`SELECT i.id,i.proof_public_key,i.expires_at,i.revoked_at,w.owner_person_id,
      p.identity_public_key AS ownerIdentityPublicKey FROM group_invitations i
      JOIN group_windows w ON w.space_id=i.space_id JOIN group_people p ON p.id=w.owner_person_id
      WHERE i.id=? AND i.space_id=? AND w.mode='active'`).bind(groupId(invitationId),groupId(windowId))
    .first<{id:string;proof_public_key:string;expires_at:number;revoked_at:number|null;owner_person_id:string;ownerIdentityPublicKey:string}>();
  if(!value) throw new ApiError(404,"not_found","The invitation was not found.");
  if(value.revoked_at!==null) throw new ApiError(410,"invitation_revoked","The invitation is no longer available.");
  if(value.expires_at<=now) throw new ApiError(410,"invitation_expired","The invitation has expired.");
  return value;
}
export function groupJoinTranscript(input:{windowId:string;invitationId:string;challengeId:string;challenge:string;expiresAt:number;
  operationId:string;personId:string;deviceId:string;encryptedNameHash:string;personAuthorization:string}):Uint8Array {
  return groupFields(["NW3.JOIN","3",input.windowId,input.invitationId,input.challengeId,input.challenge,String(input.expiresAt),
    input.operationId,input.personId,input.deviceId,base64urlDecode(input.encryptedNameHash,32),base64urlDecode(input.personAuthorization,64)]);
}
export async function createGroupJoinChallenge(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,["invitationId"]);
  const invitation=await groupInvitation(env,windowId,stringField(body,"invitationId"),actor.now);
  await enforceRateLimit(env,env.MEMBER_RATE_LIMITER,`group-invite:${invitation.id}`);
  const challengeId=crypto.randomUUID(),challenge=randomBase64url(32),expiresAt=Math.min(actor.now+300,invitation.expires_at);
  const head=await loadStoredGroupRoster(env.DB,windowId);
  const ownerDevices=head.packet.roster.members.find(m=>m.role==='owner')!.devices;
  await env.DB.batch([...groupNonceStatements(env,actor),env.DB.prepare("INSERT INTO group_challenges VALUES (?,'join',?,?,?,?,NULL)")
    .bind(challengeId,invitation.id,await groupDeviceKeyHash(actor.signingPublicKey,actor.hpkePublicKey),challenge,expiresAt)]);
  return jsonResponse({challengeId,challenge,expiresAt,ownerPersonId:invitation.owner_person_id,
    ownerIdentityPublicKey:invitation.ownerIdentityPublicKey,ownerDevices,serverNow:actor.now},201);
}
export async function createGroupJoinRequest(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,["operationId","invitationId","challengeId","personId","candidateDeviceId","encryptedDisplayName","personAuthorization","inviteProof","deviceSignature"]);
  const operationId=uuidField(body,"operationId"),prior=await storedGroupMutation(env,actor,operationId);
  if(prior!==null) return joinRequestResponse(env,actor,windowId,prior);
  if(body.personId!==actor.personId || body.candidateDeviceId!==actor.deviceId) throw new ApiError(401,"invalid_proof","The candidate proof is invalid.");
  const invitation=await groupInvitation(env,windowId,stringField(body,"invitationId"),actor.now),challengeId=uuidField(body,"challengeId");
  const challenge=await env.DB.prepare("SELECT random_challenge,device_key_hash,expires_at,consumed_at FROM group_challenges WHERE id=? AND invitation_id=? AND purpose='join'")
    .bind(challengeId,invitation.id).first<{random_challenge:string;device_key_hash:string;expires_at:number;consumed_at:number|null}>();
  if(!challenge || challenge.consumed_at!==null || challenge.expires_at<=actor.now
      || challenge.device_key_hash!==await groupDeviceKeyHash(actor.signingPublicKey,actor.hpkePublicKey))
    throw new ApiError(410,"challenge_expired","The join challenge has expired.");
  const encryptedDisplayName=groupCipher(body,"encryptedDisplayName",4096),personAuthorization=binaryField(body,"personAuthorization",64);
  const device:GroupRosterDevice={id:actor.deviceId,signingPublicKey:actor.signingPublicKey,hpkePublicKey:actor.hpkePublicKey,personAuthorization};
  const transcript=groupJoinTranscript({windowId,invitationId:invitation.id,challengeId,challenge:challenge.random_challenge,
    expiresAt:challenge.expires_at,operationId,personId:actor.personId,deviceId:actor.deviceId,
    encryptedNameHash:await sha256Base64url(base64urlDecode(encryptedDisplayName)),personAuthorization});
  if(!await verifyEd25519(actor.identityPublicKey,personAuthorization,groupDeviceAuthorization(windowId,actor.personId,device))
      || !await verifyEd25519(invitation.proof_public_key,binaryField(body,"inviteProof",64),transcript)
      || !await verifyEd25519(actor.signingPublicKey,binaryField(body,"deviceSignature",64),transcript))
    throw new ApiError(401,"invalid_proof","The join proof is invalid.");
  const member=await env.DB.prepare("SELECT participant_id FROM group_window_devices WHERE space_id=? AND device_id=? AND state='active'")
    .bind(windowId,actor.deviceId).first();
  if(member) throw new ApiError(409,"already_member","This device already participates in this window.");
  const requestId=randomBase64url(16),response={operationId,requestId,windowId,invitationId:invitation.id,personId:actor.personId,
    candidateDeviceId:actor.deviceId,state:"pending",expiresAt:invitation.expires_at,serverNow:actor.now};
  await env.DB.batch([...groupNonceStatements(env,actor),
    env.DB.prepare("UPDATE group_challenges SET consumed_at=? WHERE id=?").bind(actor.now,challengeId),
    env.DB.prepare("INSERT INTO group_join_requests VALUES (?,?,?,?,?,?,'pending',?,NULL)")
      .bind(requestId,windowId,invitation.id,actor.personId,actor.deviceId,JSON.stringify(body),invitation.expires_at),
    env.DB.prepare("INSERT INTO group_join_admission_proofs VALUES (?,?)").bind(requestId,JSON.stringify({operationId,challengeId,challenge:challenge.random_challenge,
      challengeExpiresAt:challenge.expires_at,inviteProof:body.inviteProof,deviceSignature:body.deviceSignature})),
    groupMutationStatement(env,actor,operationId,response)]);
  return joinRequestResponse(env,actor,windowId,response,201);
}
export async function groupJoinRequest(env:Env,windowId:string,requestId:string):Promise<GroupJoinRow> {
  const row=await env.DB.prepare("SELECT * FROM group_join_requests WHERE id=? AND space_id=?")
    .bind(groupId(requestId),groupId(windowId)).first<GroupJoinRow>();
  if(!row) throw new ApiError(404,"not_found","The join request was not found.");
  return row;
}
export async function getGroupJoinStatus(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,["requestId"]);
  const row=await groupJoinRequest(env,windowId,stringField(body,"requestId"));
  if(row.candidate_device_id!==actor.deviceId || row.person_id!==actor.personId) throw new ApiError(404,"not_found","The join request was not found.");
  await env.DB.batch(groupNonceStatements(env,actor));
  const active=await groupAdmissionPause(env,windowId);
  return jsonResponse({requestId:row.id,windowId,state:row.state==='pending' && row.expires_at<=actor.now?'expired':row.state,
    admissionPaused:row.state==='pending'&&row.expires_at>actor.now&&active!==null&&!active.has(row.person_id),
    resultRevision:row.result_revision,expiresAt:row.expires_at,invitationId:row.invitation_id,personId:row.person_id,
    candidateDeviceId:row.candidate_device_id,serverNow:actor.now});
}
export async function resolveGroupJoinRequest(env:Env,actor:GroupActor,windowId:string,requestId:string,body:JsonRecord,state:"rejected"|"cancelled"):Promise<Response> {
  exactKeys(body,state==='rejected'?["operationId","expectedRevision"]:["operationId"]);
  if(state==='rejected') await requireGroupMember(env,actor,windowId,true);
  const operationId=uuidField(body,"operationId"),scope=state==='rejected'?{windowId,owner:true,expectedRevision:groupExpected(body)}:undefined;
  const prior=await storedGroupMutation(env,actor,operationId,scope);
  if(prior!==null) return jsonResponse(prior);
  const row=await groupJoinRequest(env,windowId,requestId);
  if(state==='cancelled' && (row.candidate_device_id!==actor.deviceId || row.person_id!==actor.personId))
    throw new ApiError(404,"not_found","The join request was not found.");
  if(row.state!=='pending') throw new ApiError(409,"request_not_pending","The join request is already resolved.");
  const response={operationId,requestId,requestState:state,revision:scope?.expectedRevision ?? null,serverNow:actor.now};
  await env.DB.batch([...groupNonceStatements(env,actor,scope),
    env.DB.prepare("UPDATE group_join_requests SET state=? WHERE id=?").bind(state,requestId),
    groupMutationStatement(env,actor,operationId,response)]);
  return jsonResponse(response);
}
export function groupStoredJoinBody(row:GroupJoinRow):JsonRecord {
  return asObject(JSON.parse(row.signed_request) as unknown);
}
