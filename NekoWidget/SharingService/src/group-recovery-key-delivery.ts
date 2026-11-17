import type {Env} from './env';
import {ApiError,jsonResponse} from './errors';
import {requireGroupMember,groupAuthorizationStatements,type GroupActor} from './group-auth';
import {loadStoredGroupRoster,verifyHistoricalRecoveryRoster,type SignedGroupRoster,type VerifiedGroupRoster} from './group-protocol';
import {verifyParticipation} from './group-recovery-participation';
import {verifyRecoveryRecipient,verifyRecoveryOffer,recoveryOfferBytes} from './group-recovery-key-protocol';
import {base64urlEncode,sha256Base64url} from './encoding';
import {exactKeys,uuidField,type JsonRecord} from './validation';

export interface RecoveryPendingRow {person_id:string;operation_id:string;window_id:string;device_id:string;
 signing_public_key:string;hpke_public_key:string;model:string;proof_json:string}
export function requireRecoveryGate(env:Env):asserts env is Env & {ENVIRONMENT:'staging'|'production'} {
 if(env.GROUP_RECOVERY_CATALOG_ENABLED!=='YES')throw new ApiError(503,'recovery_disabled','Recovery is unavailable.');
 if(env.ENVIRONMENT!=='staging'&&env.ENVIRONMENT!=='production')throw new ApiError(503,'recovery_disabled','Recovery is unavailable.');
}
export async function recoveryDeliveryState(env:Env,row:RecoveryPendingRow,head:VerifiedGroupRoster){
 requireRecoveryGate(env);
 const recipient=await verifyRecoveryRecipient(JSON.parse(row.proof_json),head,env.ENVIRONMENT);
 if(!recipient||recipient.deviceId!==row.device_id||recipient.personId!==row.person_id||recipient.operationId!==row.operation_id)
  throw new ApiError(409,'recovery_proof_invalid','Recovery proof is invalid.');
 const b=await env.DB.prepare('SELECT proof_json FROM group_recovery_participation WHERE window_id=? AND person_id=?')
  .bind(row.window_id,row.person_id).first<{proof_json:string}>();
 const boundary=await verifyParticipation(b?JSON.parse(b.proof_json):null,head,env.ENVIRONMENT,row.person_id);
 return {recipient,boundary};
}
export function recoveryKeyChecks(env:Env,row:RecoveryPendingRow,head:VerifiedGroupRoster,id:string,receipts?:string[]):D1PreparedStatement[]{
 return [env.DB.prepare('INSERT INTO group_recovery_key_checks VALUES (?,?,?,?,?,?,?)')
  .bind(id,row.person_id,row.operation_id,row.window_id,head.hash,row.device_id,receipts?JSON.stringify(receipts):null),
  env.DB.prepare('DELETE FROM group_recovery_key_checks WHERE id=?').bind(id)];
}
export async function recoveryEpoch(env:Env,head:VerifiedGroupRoster,keyEpoch:number){
 const owner=head.packet.roster.members.find(m=>m.role==='owner')!;
 const row=await env.DB.prepare(`SELECT p.packet_json FROM group_roster_packets p JOIN group_rosters r
  ON r.space_id=p.space_id AND r.revision=p.revision WHERE r.space_id=? AND r.key_epoch=? ORDER BY r.revision DESC LIMIT 1`)
  .bind(head.packet.roster.windowId,keyEpoch).first<{packet_json:string}>();
 if(!row)throw new ApiError(404,'recovery_epoch_unavailable','Recovery epoch is unavailable.');
 return verifyHistoricalRecoveryRoster(JSON.parse(row.packet_json) as SignedGroupRoster,
  {windowId:head.packet.roster.windowId,ownerPersonId:owner.personId,ownerIdentityPublicKey:owner.identityPublicKey});
}
export async function providerRecoveryAPI(env:Env,actor:GroupActor,windowId:string,suffix:string,body:JsonRecord):Promise<Response>{
 requireRecoveryGate(env);
 const access=await requireGroupMember(env,actor,windowId),head=await loadStoredGroupRoster(env.DB,windowId);
 if(suffix==='recovery/pending'){
  exactKeys(body,[]);
  const rows=await env.DB.prepare(`SELECT r.* FROM group_recovery_pending r JOIN group_members m ON m.person_id=r.person_id AND m.space_id=r.window_id
   JOIN group_people p ON p.id=r.person_id WHERE r.window_id=? AND m.state='active' AND p.state='active' ORDER BY r.created_at LIMIT 18`)
   .bind(windowId).all<RecoveryPendingRow>();
  const items=[];
  for(const row of rows.results){const {boundary}=await recoveryDeliveryState(env,row,head);
   const receipts=await env.DB.prepare('SELECT key_epoch AS keyEpoch,person_authorization AS personAuthorization FROM group_recovery_key_offers WHERE person_id=? AND operation_id=? AND roster_hash=? AND received_at IS NOT NULL AND expires_at>? ORDER BY key_epoch')
    .bind(row.person_id,row.operation_id,head.hash,actor.now).all<{keyEpoch:number;personAuthorization:string}>();
   items.push({operationId:row.operation_id,receipts:receipts.results,
   personId:row.person_id,deviceId:row.device_id,model:row.model,proof:JSON.parse(row.proof_json),participation:boundary,
   state:boundary?'waitingForKeys':'needsParticipationProof'});}
  await env.DB.batch(groupAuthorizationStatements(env,actor,{windowId,expectedRevision:access.revision}));
  const participationProofs=[];
  for(const member of head.packet.roster.members){
   const row=await env.DB.prepare('SELECT proof_json FROM group_recovery_participation WHERE window_id=? AND person_id=?').bind(windowId,member.personId).first<{proof_json:string}>();
   const proof=await verifyParticipation(row?JSON.parse(row.proof_json):null,head,env.ENVIRONMENT,member.personId);
   if(proof)participationProofs.push(proof);
  }
  return jsonResponse({roster:head.packet,rosterHash:head.hash,items,participationProofs});
 }
 const match=suffix.match(/^recovery\/([0-9a-f-]{36})\/key-offers$/u);
 if(!match)throw new ApiError(404,'not_found','Recovery endpoint unavailable.');
 exactKeys(body,['offer']);
 const operation=uuidField({operation:match[1]},'operation');
 const candidates=await env.DB.prepare('SELECT * FROM group_recovery_pending WHERE window_id=? AND operation_id=? LIMIT 2').bind(windowId,operation).all<RecoveryPendingRow>();
 if(candidates.results.length>1)throw new ApiError(409,'recovery_operation_ambiguous','Recovery operation is ambiguous.');
 const row=candidates.results[0];
 if(!row)throw new ApiError(404,'recovery_pending_unavailable','Recovery registration unavailable.');
 const {recipient,boundary}=await recoveryDeliveryState(env,row,head);
 if(!boundary)return jsonResponse({state:'needsParticipationProof',canOpen:false,canSend:false},409);
 const raw=body.offer as Record<string,unknown>;
 if(!raw||!Number.isSafeInteger(raw.keyEpoch)||Number(raw.keyEpoch)<1)throw new ApiError(400,'invalid_recovery_offer','Invalid recovery offer.');
 const epoch=await recoveryEpoch(env,head,Number(raw.keyEpoch));
 const offer=await verifyRecoveryOffer(raw,head,epoch,recipient,boundary,actor.now);
 if(!offer||offer.senderDeviceId!==actor.deviceId)throw new ApiError(400,'invalid_recovery_offer','Invalid recovery offer.');
 const hash=await sha256Base64url(await recoveryOfferBytes(offer));
 const old=await env.DB.prepare('SELECT offer_hash,offer_json,expires_at FROM group_recovery_key_offers WHERE person_id=? AND operation_id=? AND key_epoch=?')
  .bind(row.person_id,operation,offer.keyEpoch).first<{offer_hash:string;offer_json:string;expires_at:number}>();
 if(old&&old.expires_at>actor.now&&(old.offer_hash!==hash||JSON.parse(old.offer_json).signature!==offer.signature))
  throw new ApiError(409,'idempotency_conflict','A different recovery envelope is already pending.');
 await env.DB.batch([...groupAuthorizationStatements(env,actor,{windowId,expectedRevision:access.revision}),
  ...recoveryKeyChecks(env,row,head,crypto.randomUUID()),
  env.DB.prepare('DELETE FROM group_recovery_key_offers WHERE person_id=? AND operation_id=? AND key_epoch=? AND expires_at<=?')
   .bind(row.person_id,operation,offer.keyEpoch,actor.now),
  env.DB.prepare(`INSERT INTO group_recovery_key_offers VALUES (?,?,?,?,?,?,?,?,?,?,NULL,NULL,NULL)
   ON CONFLICT(person_id,operation_id,key_epoch) DO NOTHING`).bind(row.person_id,operation,offer.keyEpoch,offer.offerId,
    windowId,head.hash,actor.deviceId,JSON.stringify(offer),hash,offer.expiresAt)]);
 const saved=await env.DB.prepare('SELECT offer_hash,offer_json FROM group_recovery_key_offers WHERE person_id=? AND operation_id=? AND key_epoch=?')
  .bind(row.person_id,operation,offer.keyEpoch).first<{offer_hash:string;offer_json:string}>();
 if(!saved||saved.offer_hash!==hash||JSON.parse(saved.offer_json).signature!==offer.signature)throw new ApiError(409,'idempotency_conflict','Recovery offer changed.');
 return jsonResponse({state:'waitingForReceipt',operationId:operation,offerId:offer.offerId});
}
