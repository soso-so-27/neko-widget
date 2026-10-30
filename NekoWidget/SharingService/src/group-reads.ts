import { base64urlDecode, base64urlEncode } from './encoding';
import { ApiError,jsonResponse } from './errors';
import type { Env } from './env';
import { groupNonceStatements,requireGroupMember,type GroupActor } from './group-auth';
import { groupStoredJoinBody,groupAdmissionPause,type GroupJoinRow } from './group-joins';
import { loadStoredGroupRoster } from './group-protocol';
import { exactKeys,integerField,type JsonRecord } from './validation';

export function groupPage(body:JsonRecord,scope:string):{after:string;limit:number} {
  exactKeys(body,['after','limit']);
  const limit=integerField(body,'limit',1,50);
  if(body.after===null) return {after:'',limit};
  try {
    if(typeof body.after!=='string' || body.after.length>1024) throw new Error();
    const value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(base64urlDecode(body.after))) as unknown;
    if(!Array.isArray(value) || value.length!==3 || value[0]!==1 || value[1]!==scope || typeof value[2]!=='string' || !/^[A-Za-z0-9_-]{1,128}$/u.test(value[2])) throw new Error();
    return {after:value[2],limit};
  } catch { throw new ApiError(400,'invalid_cursor','The page cursor is invalid.'); }
}
// The cursor is opaque pagination state, not authority. Every page separately
// authenticates its device and rechecks current membership in the DB batch.
export function groupCursor(scope:string,last:string):string {
  return base64urlEncode(new TextEncoder().encode(JSON.stringify([1,scope,last])));
}
export async function listGroupMembers(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  const access=await requireGroupMember(env,actor,windowId),scope=`members:${windowId}:${actor.deviceId}:${access.revision}`;
  const page=groupPage(body,scope),head=await loadStoredGroupRoster(env.DB,windowId);
  const result=await env.DB.prepare(`SELECT participant_id AS id,person_id AS personId,role,state,joined_revision AS joinedRevision,
    display_name_ciphertext AS encryptedDisplayName FROM group_members WHERE space_id=? AND participant_id>? ORDER BY participant_id LIMIT ?`)
    .bind(windowId,page.after,page.limit+1).all<{id:string}>();
  const items=result.results.slice(0,page.limit);
  await env.DB.batch(groupNonceStatements(env,actor,{windowId,expectedRevision:access.revision}));
  return jsonResponse({items,next:result.results.length>page.limit?groupCursor(scope,items.at(-1)!.id):null,
    roster:head.packet,revision:access.revision,serverNow:actor.now});
}
export async function listGroupJoinRequests(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  const access=await requireGroupMember(env,actor,windowId,true),scope=`requests:${windowId}:${actor.deviceId}:${access.revision}`;
  const page=groupPage(body,scope);
  const result=await env.DB.prepare(`SELECT j.*,proof.proof_json,d.signing_public_key,d.hpke_public_key,p.identity_public_key FROM group_join_requests j
    LEFT JOIN group_join_admission_proofs proof ON proof.request_id=j.id
    JOIN group_person_devices d ON d.id=j.candidate_device_id JOIN group_people p ON p.id=j.person_id
    JOIN group_invitations i ON i.id=j.invitation_id WHERE j.space_id=? AND j.state='pending'
    AND j.expires_at>? AND i.revoked_at IS NULL AND d.state='active' AND p.state='active' AND j.id>? ORDER BY j.id LIMIT ?`)
    .bind(windowId,actor.now,page.after,page.limit+1).all<GroupJoinRow & {proof_json:string|null;signing_public_key:string;hpke_public_key:string;identity_public_key:string}>();
  const active=await groupAdmissionPause(env,windowId);
  const items=result.results.slice(0,page.limit).map(row=>({admissionPaused:active!==null&&!active.has(row.person_id),id:row.id,invitationId:row.invitation_id,personId:row.person_id,
    candidateDeviceId:row.candidate_device_id,state:row.state,expiresAt:row.expires_at,
    admissionProof:row.proof_json?JSON.parse(row.proof_json):null,
    encryptedDisplayName:groupStoredJoinBody(row).encryptedDisplayName,personAuthorization:groupStoredJoinBody(row).personAuthorization,
    signingPublicKey:row.signing_public_key,hpkePublicKey:row.hpke_public_key,identityPublicKey:row.identity_public_key}));
  await env.DB.batch(groupNonceStatements(env,actor,{windowId,owner:true,expectedRevision:access.revision}));
  return jsonResponse({items,next:result.results.length>page.limit?groupCursor(scope,items.at(-1)!.id):null,
    revision:access.revision,serverNow:actor.now});
}
export async function getGroupKey(env:Env,actor:GroupActor,windowId:string,epoch:number):Promise<Response> {
  const access=await requireGroupMember(env,actor,windowId);
  const row=await env.DB.prepare(`SELECT e.*,r.packet_json FROM group_key_envelopes e
    JOIN group_roster_packets r ON r.space_id=e.space_id AND r.revision=e.roster_revision
    JOIN group_window_devices d ON d.space_id=e.space_id AND d.device_id=e.device_id
    JOIN group_members m ON m.participant_id=d.participant_id
    WHERE e.space_id=? AND e.epoch=? AND e.device_id=? AND e.roster_revision>=d.added_revision
      AND e.roster_revision>=m.joined_revision AND d.state='active' AND m.state='active'`)
    .bind(windowId,epoch,actor.deviceId).first<{space_id:string;epoch:number;device_id:string;roster_hash:string;
      encapsulated_key:string;sealed_key:string;signer_device_id:string;signature:string;packet_json:string}>();
  if(!row) throw new ApiError(403,'epoch_not_authorized','This device is not authorized for that key epoch.');
  await env.DB.batch(groupNonceStatements(env,actor,{windowId,expectedRevision:access.revision}));
  return jsonResponse({roster:JSON.parse(row.packet_json) as unknown,envelopeForThisDevice:{windowId:row.space_id,keyEpoch:row.epoch,
    rosterHash:row.roster_hash,deviceId:row.device_id,encapsulatedKey:row.encapsulated_key,ciphertext:row.sealed_key,
    signerDeviceId:row.signer_device_id,signature:row.signature},serverNow:actor.now});
}
export async function listGroupRosters(env:Env,actor:GroupActor,windowId:string,body:JsonRecord):Promise<Response> {
  exactKeys(body,['afterRevision','limit']);
  const after=integerField(body,'afterRevision',0,Number.MAX_SAFE_INTEGER),limit=integerField(body,'limit',1,50);
  const access=await requireGroupMember(env,actor,windowId);
  const rows=await env.DB.prepare('SELECT revision,packet_json FROM group_roster_packets WHERE space_id=? AND revision>? AND revision<=? ORDER BY revision LIMIT ?')
    .bind(windowId,after,access.revision,limit+1).all<{revision:number;packet_json:string}>();
  const items=rows.results.slice(0,limit);
  await env.DB.batch(groupNonceStatements(env,actor,{windowId,expectedRevision:access.revision}));
  return jsonResponse({items:items.map(r=>JSON.parse(r.packet_json) as unknown),nextRevision:rows.results.length>limit?items.at(-1)!.revision:null,
    revision:access.revision,serverNow:actor.now});
}
