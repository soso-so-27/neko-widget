import { base64urlDecode, randomBase64url } from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import { groupId,groupAuthorizationStatements,groupMutationStatement,groupNonceStatements,requireGroupMember,storedGroupMutation,
  type GroupActor,type GroupScope } from "./group-auth";
import { loadStoredGroupRoster,verifyGroupEnvelopes,verifyGroupRoster,
  type GroupKeyEnvelope,type SignedGroupRoster,type VerifiedGroupRoster } from "./group-protocol";
import { asObject,binaryField,exactKeys,integerField,opaqueId,stringField,uuidField,type JsonRecord } from "./validation";
import { groupCursor,groupPage } from './group-reads';
import { groupCreationPolicyStatements,groupDeliveryPolicies } from './group-owner-plus';

export function groupCipher(body:JsonRecord,key:string,maximum=8192):string {
  const value=stringField(body,key),bytes=base64urlDecode(value);
  if(bytes.length<29 || bytes.length>maximum) throw new ApiError(400,"invalid_ciphertext","The encrypted field is invalid.");
  return value;
}
export function groupNames(body:JsonRecord,roster:VerifiedGroupRoster):Record<string,string> {
  const values=asObject(body.encryptedMemberNames);
  exactKeys(values,roster.packet.roster.members.map(m=>m.participantId));
  return Object.fromEntries(Object.keys(values).map(k=>[k,groupCipher(values,k,2048)]));
}
export function groupPacketStatements(env:Env,roster:VerifiedGroupRoster,envelopes:readonly GroupKeyEnvelope[],actor:GroupActor,
  operationId:string,kind:string,expectedRevision:number):D1PreparedStatement[] {
  const r=roster.packet.roster;
  const result=[env.DB.prepare("INSERT INTO group_rosters VALUES (?,?,?,?,?,?,?,?,?)")
    .bind(r.windowId,r.revision,r.previousHash,r.keyEpoch,roster.bytes,roster.hash,roster.packet.signerDeviceId,roster.packet.signature,actor.now),
    env.DB.prepare("INSERT INTO group_roster_packets VALUES (?,?,?)").bind(r.windowId,r.revision,JSON.stringify(roster.packet))];
  for(const e of envelopes) result.push(env.DB.prepare("INSERT INTO group_key_envelopes VALUES (?,?,?,?,?,?,?,?,?)")
    .bind(e.windowId,e.keyEpoch,e.deviceId,r.revision,e.rosterHash,e.encapsulatedKey,e.ciphertext,e.signerDeviceId,e.signature));
  result.push(env.DB.prepare("INSERT INTO group_epoch_transitions VALUES (?,?,?,?,?,?,?,?,?)")
    .bind(operationId,r.windowId,actor.deviceId,expectedRevision,r.revision,r.keyEpoch,actor.requestHash,kind,actor.now));
  return result;
}
export function groupEnvelopes(body:JsonRecord):GroupKeyEnvelope[] {
  if(!Array.isArray(body.envelopes) || body.envelopes.length>18) throw new ApiError(400,"invalid_envelope","The key envelope set is invalid.");
  return body.envelopes as GroupKeyEnvelope[];
}
export function groupExpected(body:JsonRecord):number { return integerField(body,"expectedRevision",1,Number.MAX_SAFE_INTEGER); }

export async function createGroupWindow(env:Env,actor:GroupActor,body:JsonRecord):Promise<Response> {
  exactKeys(body,["operationId","packet","envelopes","encryptedName","encryptedMemberNames"]);
  const operationId=uuidField(body,"operationId");
  const prior=await storedGroupMutation(env,actor,operationId);
  if(prior!==null) return jsonResponse(prior);
  const signed=asObject(body.packet) as unknown as SignedGroupRoster;
  const windowId=stringField(asObject(signed.roster),"windowId");
  const roster=await verifyGroupRoster(signed,{windowId,ownerPersonId:actor.personId,ownerIdentityPublicKey:actor.identityPublicKey});
  const r=roster.packet.roster,member=r.members[0];
  opaqueId(r.windowId,"window");
  if(r.members.length!==1 || !member || member.personId!==actor.personId || member.role!=="owner" || member.devices.length!==1
      || member.devices[0]?.id!==actor.deviceId || member.devices[0].signingPublicKey!==actor.signingPublicKey
      || member.devices[0].hpkePublicKey!==actor.hpkePublicKey || signed.signerDeviceId!==actor.deviceId)
    throw new ApiError(400,"invalid_roster","A new window must start with its creating device.");
  opaqueId(member.participantId,"participant");
  const envelopes=groupEnvelopes(body); await verifyGroupEnvelopes(envelopes,roster);
  const encryptedName=groupCipher(body,"encryptedName"),memberNames=groupNames(body,roster);
  const response={operationId,windowId:r.windowId,participantId:member.participantId,revision:1,keyEpoch:1,serverNow:actor.now};
  // The first window already needs verified Plus, including Apple's active
  // introductory offer. Owned five and total ten are independent limits.
  const ownedLimit=5;
  await env.DB.batch([...groupNonceStatements(env,actor),
    env.DB.prepare("INSERT INTO group_windows(space_id,owner_person_id,mode,created_at,updated_at) VALUES (?,?,'preparing',?,?)")
      .bind(r.windowId,actor.personId,actor.now,actor.now),
    env.DB.prepare("INSERT INTO group_members VALUES (?,?,?,'owner','active',1,NULL,?)")
      .bind(member.participantId,r.windowId,actor.personId,memberNames[member.participantId]),
    env.DB.prepare("INSERT INTO group_window_devices VALUES (?,?,?,'active',1,NULL)").bind(r.windowId,actor.deviceId,member.participantId),
    ...groupPacketStatements(env,roster,envelopes,actor,operationId,"create",0),
    env.DB.prepare("INSERT INTO group_window_metadata VALUES (?,?,1,1)").bind(r.windowId,encryptedName),
    env.DB.prepare("INSERT INTO group_window_creation_checks VALUES (?,?,?,?,?)").bind(operationId,r.windowId,actor.personId,ownedLimit,actor.now),
    ...groupCreationPolicyStatements(env,r.windowId,actor.personId,operationId),
    groupMutationStatement(env,actor,operationId,response)]);
  return jsonResponse(response,201);
}

export async function listGroupWindows(env:Env,actor:GroupActor,body:JsonRecord):Promise<Response> {
  const cursorScope=`windows:${actor.deviceId}`,page=groupPage(body,cursorScope);
  const result=await env.DB.prepare(`SELECT w.space_id AS windowId,w.revision,w.key_epoch AS keyEpoch,w.rotation_required AS rotationRequired,
      m.participant_id AS myParticipantId,m.role AS myRole,n.encrypted_name AS encryptedName
      FROM group_windows w JOIN group_members m ON m.space_id=w.space_id
      JOIN group_window_devices d ON d.space_id=w.space_id AND d.participant_id=m.participant_id
      JOIN group_window_metadata n ON n.space_id=w.space_id
      WHERE m.person_id=? AND m.state='active' AND d.device_id=? AND d.state='active' AND w.mode='active' AND w.space_id>?
      ORDER BY w.space_id LIMIT ?`).bind(actor.personId,actor.deviceId,page.after,page.limit+1)
    .all<{windowId:string;revision:number;rotationRequired:number}>();
  const items=result.results.slice(0,page.limit),checks=groupNonceStatements(env,actor);
  for(const item of items) checks.push(...groupAuthorizationStatements(env,actor,
    {windowId:item.windowId,expectedRevision:item.revision}));
  await env.DB.batch(checks);
  const policies=await groupDeliveryPolicies(env,items.map(i=>i.windowId));
  return jsonResponse({items:items.map(i=>({...i,rotationRequired:i.rotationRequired===1,...policies.get(i.windowId)})),
    next:result.results.length>page.limit?groupCursor(cursorScope,items.at(-1)!.windowId):null,serverNow:actor.now});
}

export async function getGroupWindow(env:Env,actor:GroupActor,windowId:string):Promise<Response> {
  const access=await requireGroupMember(env,actor,windowId);
  const roster=await loadStoredGroupRoster(env.DB,windowId);
  const metadata=await env.DB.prepare("SELECT encrypted_name AS encryptedName,key_epoch AS nameKeyEpoch,roster_revision AS nameRosterRevision FROM group_window_metadata WHERE space_id=?")
    .bind(windowId).first();
  // Gate OFF candidates retain the old query path and do not need migration
  // 0047. A roster rotation replaces the name and starts a new name counter.
  const nameProof=env.GROUP_WINDOW_MANAGEMENT_RUNTIME_ENABLED==='YES'?await env.DB.prepare(`SELECT n.name_revision AS nameRevision,
    n.signer_device_id AS signerDeviceId,n.operation_id AS operationId,n.signature FROM group_window_names n
    JOIN group_window_metadata m ON m.space_id=n.space_id AND m.encrypted_name=n.encrypted_name
      AND m.key_epoch=n.key_epoch AND m.roster_revision=n.roster_revision
    WHERE n.space_id=? AND n.roster_hash=?`).bind(windowId,roster.hash).first():null;
  await env.DB.batch(groupNonceStatements(env,actor,{windowId,expectedRevision:access.revision}));
  const policy=(await groupDeliveryPolicies(env,[windowId])).get(windowId);
  return jsonResponse({window:{windowId,revision:access.revision,keyEpoch:access.keyEpoch,rotationRequired:access.rotationRequired===1,...metadata,...policy,
    ...(env.GROUP_WINDOW_MANAGEMENT_RUNTIME_ENABLED==='YES'?{nameRevision:nameProof?.nameRevision??0,nameProof}: {})},
    roster:roster.packet,rosterHash:roster.hash,serverNow:actor.now});
}

export async function createGroupInvitation(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,["operationId","expectedRevision","proofPublicKey"]);
  await requireGroupMember(env,actor,windowId,true);
  const operationId=uuidField(body,"operationId"),revision=groupExpected(body);
  const scope:GroupScope={windowId,owner:true,expectedRevision:revision};
  const prior=await storedGroupMutation(env,actor,operationId,scope);
  if(prior!==null) return jsonResponse(prior);
  const proofPublicKey=binaryField(body,"proofPublicKey",32),invitationId=randomBase64url(16),expiresAt=actor.now+86400;
  const response={operationId,invitationId,expiresAt,revision,serverNow:actor.now};
  await env.DB.batch([...groupNonceStatements(env,actor,scope),
    env.DB.prepare("INSERT INTO group_invitations VALUES (?,?,?,?,?,?,NULL)").bind(invitationId,windowId,proofPublicKey,actor.deviceId,actor.now,expiresAt),
    groupMutationStatement(env,actor,operationId,response)]);
  return jsonResponse(response,201);
}

export async function revokeGroupInvitation(env:Env,actor:GroupActor,windowId:string,invitationId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,["operationId","expectedRevision"]);
  await requireGroupMember(env,actor,windowId,true);
  const operationId=uuidField(body,"operationId"),revision=groupExpected(body),scope={windowId,owner:true,expectedRevision:revision};
  const prior=await storedGroupMutation(env,actor,operationId,scope);
  if(prior!==null) return jsonResponse(prior);
  const invitation=await env.DB.prepare("SELECT id FROM group_invitations WHERE id=? AND space_id=?").bind(invitationId,windowId).first();
  if(!invitation) throw new ApiError(404,"not_found","The invitation was not found.");
  const response={operationId,revision,state:"revoked",serverNow:actor.now};
  await env.DB.batch([...groupNonceStatements(env,actor,scope),
    env.DB.prepare("UPDATE group_invitations SET revoked_at=COALESCE(revoked_at,?) WHERE id=? AND space_id=?").bind(actor.now,invitationId,windowId),
    env.DB.prepare("UPDATE group_join_requests SET state='cancelled' WHERE invitation_id=? AND state='pending'").bind(invitationId),
    groupMutationStatement(env,actor,operationId,response)]);
  return jsonResponse(response);
}

// Read-only, authenticated owner lookup. Re-sharing never extends the original expiry.
export async function groupInvitationStatus(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,['invitationId']);
  const access=await requireGroupMember(env,actor,windowId,true);
  const invitationId=groupId(stringField(body,'invitationId'));
  const row=await env.DB.prepare('SELECT proof_public_key AS proofPublicKey,expires_at AS expiresAt,revoked_at AS revokedAt FROM group_invitations WHERE id=? AND space_id=?')
    .bind(invitationId,windowId).first();
  if(!row)throw new ApiError(404,'not_found','The invitation was not found.');
  await env.DB.batch(groupNonceStatements(env,actor,{windowId,owner:true,expectedRevision:access.revision}));
  return jsonResponse({...row,invitationId,serverNow:actor.now});
}
