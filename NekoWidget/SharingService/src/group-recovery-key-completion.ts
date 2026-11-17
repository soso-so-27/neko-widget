import type {Env} from './env';
import {ApiError,jsonResponse} from './errors';
import {requireGroupMember,groupAuthorizationStatements,storedGroupMutation,groupMutationStatement,type GroupActor} from './group-auth';
import {asObject,exactKeys,uuidField,type JsonRecord} from './validation';
import {loadStoredGroupRoster,verifyGroupRoster,verifyGroupEnvelopes,groupDeviceAuthorization,type SignedGroupRoster,type GroupRosterMember} from './group-protocol';
import {groupCipher,groupNames,groupEnvelopes,groupPacketStatements,groupExpected} from './group-windows';
import {recoveryDeliveryState,recoveryKeyChecks,recoveryEpoch,requireRecoveryGate,type RecoveryPendingRow} from './group-recovery-key-delivery';
import {verifyRecoveryOffer,recoveryReceiptBytes,type RecoveryKeyOffer} from './group-recovery-key-protocol';
import {verifyEd25519} from './encoding';
import {participationStatements} from './group-recovery-participation-store';

const shape=(members:readonly GroupRosterMember[])=>JSON.stringify([...members].sort((a,b)=>a.participantId.localeCompare(b.participantId)).map(m=>
 [m.participantId,m.personId,m.identityPublicKey,m.role,[...m.devices].sort((a,b)=>a.id.localeCompare(b.id)).map(d=>[d.id,d.signingPublicKey,d.hpkePublicKey])]));
export async function completeRecoveryKeys(env:Env,actor:GroupActor,windowId:string,operation:string,body:JsonRecord):Promise<Response>{
 requireRecoveryGate(env);
 exactKeys(body,['operationId','expectedRevision','packet','envelopes','encryptedName','encryptedMemberNames',...(body.participationProofs!==undefined?['participationProofs']:[])]);
 if(uuidField(body,'operationId')!==operation)throw new ApiError(400,'invalid_request','Invalid recovery operation.');
 const revision=groupExpected(body),scope={windowId,owner:true,expectedRevision:revision};
 await requireGroupMember(env,actor,windowId,true);
 const prior=await storedGroupMutation(env,actor,operation,scope);if(prior)return jsonResponse(prior);
 const fail=()=>new ApiError(409,'recovery_receipt_required','Recovery keys must be received first.');
 const candidates=await env.DB.prepare('SELECT * FROM group_recovery_pending WHERE window_id=? AND operation_id=? LIMIT 2').bind(windowId,operation).all<RecoveryPendingRow>();
 if(candidates.results.length>1)throw fail();
 const row=candidates.results[0];
 if(!row)throw fail();
 const previous=await loadStoredGroupRoster(env.DB,windowId),{recipient,boundary}=await recoveryDeliveryState(env,row,previous);
 if(!boundary||previous.packet.roster.revision!==revision)throw fail();
 const receipts=await env.DB.prepare(`SELECT offer_hash,offer_json,receipt_signature,person_authorization,received_at,expires_at FROM group_recovery_key_offers
  WHERE person_id=? AND operation_id=? AND roster_hash=? ORDER BY key_epoch`)
  .bind(row.person_id,operation,previous.hash).all<{offer_hash:string;offer_json:string;receipt_signature:string|null;person_authorization:string|null;received_at:number|null;expires_at:number}>();
 if(!receipts.results.length||receipts.results.some(r=>r.received_at===null||!r.receipt_signature||!r.person_authorization||r.expires_at<=actor.now))throw fail();
 let authorization:string|undefined,hasCurrent=false;
 for(const stored of receipts.results){
  const offer=JSON.parse(stored.offer_json) as RecoveryKeyOffer,epoch=await recoveryEpoch(env,previous,offer.keyEpoch);
  if(!await verifyRecoveryOffer(offer,previous,epoch,recipient,boundary,actor.now)
   ||!await verifyEd25519(row.signing_public_key,stored.receipt_signature!,await recoveryReceiptBytes(offer)))throw fail();
  if(offer.keyEpoch===previous.packet.roster.keyEpoch){hasCurrent=true;authorization=stored.person_authorization!;}
 }
 if(!hasCurrent||!authorization)throw fail();
 const member=previous.packet.roster.members.find(m=>m.personId===row.person_id);if(!member)throw fail();
 const device={id:row.device_id,signingPublicKey:row.signing_public_key,hpkePublicKey:row.hpke_public_key,personAuthorization:authorization};
 if(!await verifyEd25519(member.identityPublicKey,authorization,groupDeviceAuthorization(windowId,row.person_id,device)))throw fail();
 const owner=previous.packet.roster.members.find(m=>m.role==='owner')!;
 const next=await verifyGroupRoster(asObject(body.packet) as unknown as SignedGroupRoster,
  {windowId,ownerPersonId:owner.personId,ownerIdentityPublicKey:owner.identityPublicKey},previous);
 if(next.packet.signerDeviceId!==actor.deviceId||next.packet.roster.keyEpoch!==previous.packet.roster.keyEpoch+1)throw fail();
 const active=await env.DB.prepare(`SELECT m.participant_id,w.device_id FROM group_members m JOIN group_window_devices w
  ON w.space_id=m.space_id AND w.participant_id=m.participant_id JOIN group_person_devices d ON d.id=w.device_id
  WHERE m.space_id=? AND m.state='active' AND w.state='active' AND d.state='active'`).bind(windowId).all<{participant_id:string;device_id:string}>();
 const expected=previous.packet.roster.members.filter(m=>active.results.some(a=>a.participant_id===m.participantId)).map(m=>({...m,
  devices:m.devices.filter(d=>active.results.some(a=>a.participant_id===m.participantId&&a.device_id===d.id))}));
 // A recovering member may currently have no effective devices.
 let target=expected.find(m=>m.personId===row.person_id);
 if(!target){target={...member,devices:[]};expected.push(target);}
 if(target.devices.some(d=>d.id===device.id))throw fail();target.devices.push(device);
 if(shape(expected)!==shape(next.packet.roster.members))throw fail();
 const envelopes=groupEnvelopes(body);await verifyGroupEnvelopes(envelopes,next);
 const names=groupNames(body,next),name=groupCipher(body,'encryptedName');
 const result={state:'recoveryCommitted',operationId:operation,personId:row.person_id,windowId,deviceId:row.device_id,
  revision:next.packet.roster.revision,rosterHash:next.hash};
 const updates=expected.map(m=>env.DB.prepare('UPDATE group_members SET display_name_ciphertext=? WHERE space_id=? AND participant_id=?').bind(names[m.participantId],windowId,m.participantId));
 await env.DB.batch([...groupAuthorizationStatements(env,actor,scope),...recoveryKeyChecks(env,row,previous,crypto.randomUUID(),receipts.results.map(r=>r.offer_hash)),
  env.DB.prepare("INSERT INTO group_person_devices VALUES (?,?,?,?,?,'active',?,NULL) ON CONFLICT(id) DO NOTHING")
   .bind(row.device_id,row.person_id,row.signing_public_key,row.hpke_public_key,row.proof_json,actor.now),
  env.DB.prepare('INSERT INTO group_recovery_device_labels VALUES (?,?) ON CONFLICT(device_id) DO NOTHING').bind(row.device_id,row.model),
  env.DB.prepare("INSERT INTO group_window_devices VALUES (?,?,?,'active',?,NULL)").bind(windowId,row.device_id,member.participantId,next.packet.roster.revision),
  ...updates,...groupPacketStatements(env,next,envelopes,actor,operation,'addDevice',revision),
  env.DB.prepare('UPDATE group_window_metadata SET encrypted_name=?,key_epoch=?,roster_revision=? WHERE space_id=?').bind(name,next.packet.roster.keyEpoch,next.packet.roster.revision,windowId),
  ...await participationStatements(env,body.participationProofs,next,previous),
  env.DB.prepare('INSERT INTO group_recovery_key_completions VALUES (?,?,?,?,?,?,?,?)')
   .bind(row.person_id,operation,windowId,row.device_id,previous.hash,next.packet.roster.revision,next.hash,actor.now),
  env.DB.prepare('DELETE FROM group_recovery_pending WHERE person_id=? AND operation_id=?').bind(row.person_id,operation),
  groupMutationStatement(env,actor,operation,result)]);
 return jsonResponse(result);
}
