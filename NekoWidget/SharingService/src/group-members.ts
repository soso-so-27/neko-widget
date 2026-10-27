import { base64urlDecode, verifyEd25519 } from "./encoding";
import { ApiError, jsonResponse } from "./errors";
import type { Env } from "./env";
import { groupId, groupMutationStatement, groupNonceStatements, requireGroupMember, storedGroupMutation, type GroupActor } from "./group-auth";
import { groupInvitation, groupJoinRequest, groupStoredJoinBody } from "./group-joins";
import { groupFields, loadStoredGroupRoster, verifyGroupEnvelopes, verifyGroupRoster,
  type GroupRosterMember, type SignedGroupRoster } from "./group-protocol";
import { groupCipher, groupEnvelopes, groupExpected, groupNames, groupPacketStatements } from "./group-windows";
import { asObject, binaryField, exactKeys, opaqueId, uuidField, type JsonRecord } from "./validation";

type Kind='admit'|'addDevice'|'remove'|'removeDevice'|'rotate';
interface MemberRow {participant_id:string;person_id:string;role:'owner'|'member';state:string;identity_public_key:string}
interface DeviceRow {device_id:string;participant_id:string;signing_public_key:string;hpke_public_key:string;person_id:string;state:string}
function fail(code:string,status=409):never { throw new ApiError(status,code,"The membership change could not be completed."); }
function membershipShape(members:readonly GroupRosterMember[]):string {
  return JSON.stringify([...members].sort((a,b)=>a.participantId<b.participantId?-1:1).map(m=>[m.participantId,m.personId,m.identityPublicKey,m.role,
    [...m.devices].sort((a,b)=>a.id<b.id?-1:1).map(d=>[d.id,d.signingPublicKey,d.hpkePublicKey])]));
}
export async function transitionGroupMembership(env:Env,actor:GroupActor,windowId:string,kind:Kind,targetId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,["operationId","expectedRevision","kind","targetId","packet","envelopes","encryptedName","encryptedMemberNames",
    ...(kind==='addDevice'?["personSponsorSignature"]:[])]);
  if(body.kind!==kind || body.targetId!==targetId) fail('invalid_request',400);
  const operationId=uuidField(body,'operationId'),revision=groupExpected(body),scope={windowId,owner:true,expectedRevision:revision};
  await requireGroupMember(env,actor,windowId,true);
  const prior=await storedGroupMutation(env,actor,operationId,scope);
  if(prior!==null) return jsonResponse(prior);
  const previous=await loadStoredGroupRoster(env.DB,windowId);
  if(previous.packet.roster.revision!==revision) fail('stale_revision');
  const anchor={windowId,ownerPersonId:previous.packet.roster.ownerPersonId,
    ownerIdentityPublicKey:previous.packet.roster.members.find(m=>m.role==='owner')!.identityPublicKey};
  const next=await verifyGroupRoster(asObject(body.packet) as unknown as SignedGroupRoster,anchor,previous);
  const r=next.packet.roster;
  if(r.keyEpoch!==previous.packet.roster.keyEpoch+1 || next.packet.signerDeviceId!==actor.deviceId) fail('invalid_roster',400);
  const members=await env.DB.prepare(`SELECT m.participant_id,m.person_id,m.role,m.state,p.identity_public_key FROM group_members m
    JOIN group_people p ON p.id=m.person_id WHERE m.space_id=?`).bind(windowId).all<MemberRow>();
  const devices=await env.DB.prepare(`SELECT wd.device_id,wd.participant_id,d.signing_public_key,d.hpke_public_key,d.person_id,d.state
    FROM group_window_devices wd JOIN group_person_devices d ON d.id=wd.device_id
    WHERE wd.space_id=? AND wd.state='active'`).bind(windowId).all<DeviceRow>();
  let expected=members.results.filter(m=>m.state==='active').map(m=>({participantId:m.participant_id,personId:m.person_id,
    identityPublicKey:m.identity_public_key,role:m.role,devices:devices.results.filter(d=>d.participant_id===m.participant_id)
      .map(d=>({id:d.device_id,signingPublicKey:d.signing_public_key,hpkePublicKey:d.hpke_public_key,personAuthorization:''}))}));
  const statements:D1PreparedStatement[]=[];
  let admittedParticipantId:string|undefined;
  if(kind==='admit' || kind==='addDevice') {
    let personId:string,deviceId:string,authorization:string;
    if(kind==='admit') {
      const request=await groupJoinRequest(env,windowId,targetId);
      if(request.state!=='pending') fail('request_not_pending');
      await groupInvitation(env,windowId,request.invitation_id,actor.now);
      if(request.expires_at<=actor.now) fail('invitation_expired',410);
      const signed=groupStoredJoinBody(request);
      personId=request.person_id; deviceId=request.candidate_device_id;
      authorization=binaryField(signed,'personAuthorization',64);
      statements.push(env.DB.prepare("UPDATE group_join_requests SET state='approved',result_revision=? WHERE id=?").bind(r.revision,targetId));
    } else {
      deviceId=groupId(targetId);
      const registered=await env.DB.prepare("SELECT person_id FROM group_person_devices WHERE id=? AND state='active'").bind(deviceId).first<{person_id:string}>();
      if(!registered) fail('not_found',404);
      personId=registered.person_id; authorization=binaryField(body,'personSponsorSignature',64);
      if(!expected.some(m=>m.personId===personId)) fail('wrong_person',403);
    }
    const registered=await env.DB.prepare(`SELECT d.signing_public_key,d.hpke_public_key,p.identity_public_key FROM group_person_devices d
      JOIN group_people p ON p.id=d.person_id WHERE d.id=? AND d.person_id=? AND d.state='active' AND p.state='active'`)
      .bind(deviceId,personId).first<{signing_public_key:string;hpke_public_key:string;identity_public_key:string}>();
    if(!registered) fail('invalid_proof',401);
    if(expected.some(m=>m.devices.some(d=>d.id===deviceId))) fail('already_member');
    const proposed=r.members.find(m=>m.personId===personId),candidate=proposed?.devices.find(d=>d.id===deviceId);
    if(!proposed || !candidate || candidate.personAuthorization!==authorization) fail('invalid_roster',400);
    const history=members.results.find(m=>m.person_id===personId);
    let current=expected.find(m=>m.personId===personId);
    if(!current) {
      opaqueId(proposed.participantId,'participant');
      if(history && history.participant_id!==proposed.participantId) fail('invalid_roster',400);
      current={participantId:proposed.participantId,personId,identityPublicKey:registered.identity_public_key,role:'member',devices:[]};
      expected.push(current);
      if(history) statements.push(env.DB.prepare("UPDATE group_members SET state='active',joined_revision=?,left_revision=NULL WHERE participant_id=?")
        .bind(r.revision,history.participant_id));
      else statements.push(env.DB.prepare("INSERT INTO group_members VALUES (?,?,?,'member','active',?,NULL,?)")
        .bind(proposed.participantId,windowId,personId,r.revision,groupCipher(asObject(body.encryptedMemberNames),proposed.participantId,2048)));
    }
    admittedParticipantId=current.participantId;
    current.devices.push({id:deviceId,signingPublicKey:registered.signing_public_key,hpkePublicKey:registered.hpke_public_key,personAuthorization:authorization});
    statements.push(env.DB.prepare(`INSERT INTO group_window_devices VALUES (?,?,?,'active',?,NULL)
      ON CONFLICT(space_id,device_id) DO UPDATE SET state='active',added_revision=excluded.added_revision,removed_revision=NULL`)
      .bind(windowId,deviceId,current.participantId,r.revision));
  } else if(kind==='remove') {
    const member=expected.find(m=>m.participantId===targetId);
    if(!member) fail('not_found',404);
    if(member.role==='owner') fail('cannot_remove_owner');
    expected=expected.filter(m=>m.participantId!==targetId);
    statements.push(env.DB.prepare("UPDATE group_members SET state='removed',left_revision=? WHERE participant_id=?").bind(r.revision,targetId),
      env.DB.prepare("UPDATE group_window_devices SET state='revoked',removed_revision=? WHERE space_id=? AND participant_id=? AND state='active'")
        .bind(r.revision,windowId,targetId));
  } else if(kind==='removeDevice') {
    const member=expected.find(m=>m.devices.some(d=>d.id===targetId));
    if(!member) fail('not_found',404);
    if(member.devices.length<=1 || targetId===actor.deviceId) fail(member.role==='owner'?'cannot_remove_last_owner_device':'cannot_remove_last_device');
    member.devices=member.devices.filter(d=>d.id!==targetId);
    statements.push(env.DB.prepare("UPDATE group_window_devices SET state='revoked',removed_revision=? WHERE space_id=? AND device_id=?")
      .bind(r.revision,windowId,targetId));
  } else if(targetId!==windowId) fail('invalid_request',400);
  if(membershipShape(expected)!==membershipShape(r.members)) fail('invalid_roster',400);
  const envelopes=groupEnvelopes(body); await verifyGroupEnvelopes(envelopes,next);
  const encryptedName=groupCipher(body,'encryptedName'),encryptedNames=groupNames(body,next);
  for(const m of r.members) statements.push(env.DB.prepare("UPDATE group_members SET display_name_ciphertext=? WHERE participant_id=? AND space_id=?")
    .bind(encryptedNames[m.participantId],m.participantId,windowId));
  statements.push(...groupPacketStatements(env,next,envelopes,actor,operationId,kind,revision),
    env.DB.prepare("UPDATE group_window_metadata SET encrypted_name=?,key_epoch=?,roster_revision=? WHERE space_id=?")
      .bind(encryptedName,r.keyEpoch,r.revision,windowId));
  const response={operationId,windowId,revision:r.revision,keyEpoch:r.keyEpoch,rotationRequired:false,
    ...(kind==='admit'?{requestState:'approved',participantId:admittedParticipantId}:{}),serverNow:actor.now};
  await env.DB.batch([...groupNonceStatements(env,actor,scope),...statements,groupMutationStatement(env,actor,operationId,response)]);
  return jsonResponse(response);
}

export async function leaveGroupWindow(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,['operationId','expectedRevision','selfSignature']);
  const operationId=uuidField(body,'operationId'),revision=groupExpected(body);
  // A successful leaver is no longer a member. Its idempotent result contains
  // only its own action, and is bound to the signed method/path/body.
  const prior=await storedGroupMutation(env,actor,operationId);
  if(prior!==null) return jsonResponse(prior);
  const member=await requireGroupMember(env,actor,windowId);
  const role=await env.DB.prepare("SELECT role FROM group_members WHERE participant_id=?").bind(member.participantId).first<{role:string}>();
  if(role?.role==='owner') fail('owner_cannot_leave');
  const transcript=groupFields(['NW3.LEAVE',windowId,member.participantId,String(revision),operationId]);
  if(!await verifyEd25519(actor.signingPublicKey,binaryField(body,'selfSignature',64),transcript)) fail('invalid_proof',401);
  const response={operationId,windowId,revision,state:'left',rotationRequired:true,serverNow:actor.now};
  await env.DB.batch([...groupNonceStatements(env,actor,{windowId,expectedRevision:revision}),
    env.DB.prepare("UPDATE group_members SET state='left',left_revision=? WHERE participant_id=?").bind(revision+1,member.participantId),
    env.DB.prepare("UPDATE group_window_devices SET state='revoked',removed_revision=? WHERE space_id=? AND participant_id=? AND state='active'")
      .bind(revision+1,windowId,member.participantId),
    env.DB.prepare("UPDATE group_windows SET rotation_required=1,updated_at=? WHERE space_id=?").bind(actor.now,windowId),
    groupMutationStatement(env,actor,operationId,response)]);
  return jsonResponse(response);
}
