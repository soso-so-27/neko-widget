import {getGroupKey} from './group-reads';
import type {GroupActor} from './group-auth';
import type {Env} from './env';
import {ApiError,jsonResponse} from './errors';
import {base64urlDecode,sha256Base64url,verifyEd25519} from './encoding';
import {groupFields,groupDeviceAuthorization,loadStoredGroupRoster} from './group-protocol';
import {recoveryCatalogTranscript,type RecoveryChallenge} from './group-recovery-catalog';
import {protectedGroupRead,requireCurrentIdentity} from './group-identity-service';
import {exactKeys,binaryField,stringField,integerField,uuidField,type JsonRecord} from './validation';
import {recoveryDeliveryState,recoveryEpoch,recoveryKeyChecks,requireRecoveryGate,type RecoveryPendingRow} from './group-recovery-key-delivery';
import {verifyRecoveryOffer,recoveryReceiptBytes,type RecoveryKeyOffer} from './group-recovery-key-protocol';
import {checkTrialRecovery} from './owner-two-device-trial';
import {recoveryExpiryCheckedBatch,recoveryPendingLifetime} from './group-recovery-expiry';

export function recoveryRecipientAction(c:RecoveryChallenge,windowId:string,action:string,payload:Uint8Array):Uint8Array{
 return groupFields(['NW3.RECOVERY.KEY.ACTION.V1',action,recoveryCatalogTranscript(c),windowId,payload]);
}
export async function recipientRecoveryKeys(env:Env,body:JsonRecord,operation:string,receipt:boolean,now:number):Promise<Response>{
 requireRecoveryGate(env);
 exactKeys(body,['challengeId','windowId','rootSignature',...(receipt?['offerId','keyEpoch','receiptSignature','personAuthorization']:['afterEpoch'])]);
 const windowId=stringField(body,'windowId'),rootSignature=binaryField(body,'rootSignature',64);
 const after=receipt?0:integerField(body,'afterEpoch',0,Number.MAX_SAFE_INTEGER);
 const epoch=receipt?integerField(body,'keyEpoch',1,Number.MAX_SAFE_INTEGER):0;
 const offerId=receipt?uuidField(body,'offerId'):'';
 const receiptSignature=receipt?binaryField(body,'receiptSignature',64):'';
 const authorization=receipt?binaryField(body,'personAuthorization',64):'';
 const payload=receipt?groupFields([offerId,String(epoch),base64urlDecode(receiptSignature,64),base64urlDecode(authorization,64)]):groupFields([String(after)]);
 const c=await env.DB.prepare('SELECT * FROM group_recovery_challenges WHERE id=?').bind(uuidField(body,'challengeId')).first<RecoveryChallenge>();
 const denied=()=>new ApiError(401,'recovery_authentication_failed','Recovery authentication failed.');
 if(!c||c.operation_id!==operation||c.purpose!=='status'||c.environment!==env.ENVIRONMENT||c.consumed_at!==null||now<c.issued_at||now>=c.expires_at
  ||!await verifyEd25519(c.identity_public_key,rootSignature,recoveryRecipientAction(c,windowId,receipt?'receipt':'offers',payload)))throw denied();
 checkTrialRecovery(env,c.person_id,windowId);
 await requireCurrentIdentity(env,c.person_id);
 return protectedGroupRead(env,async()=>{
  const row=await env.DB.prepare('SELECT * FROM group_recovery_pending WHERE person_id=? AND operation_id=? AND window_id=? AND created_at>?')
   .bind(c.person_id,operation,windowId,now-recoveryPendingLifetime).first<RecoveryPendingRow>();
  if(!row){
   if(receipt)throw denied();
   const done=await env.DB.prepare('SELECT device_id,previous_hash FROM group_recovery_key_completions WHERE person_id=? AND operation_id=? AND window_id=?')
    .bind(c.person_id,operation,windowId).first<{device_id:string;previous_hash:string}>();if(!done)throw denied();
   checkTrialRecovery(env,c.person_id,windowId,done.device_id);
   const d=await env.DB.prepare("SELECT signing_public_key,hpke_public_key FROM group_person_devices WHERE id=? AND person_id=? AND state='active'")
    .bind(done.device_id,c.person_id).first<{signing_public_key:string;hpke_public_key:string}>();if(!d)throw denied();
   const claim=crypto.randomUUID();
   await env.DB.batch([
    env.DB.prepare('UPDATE group_recovery_challenges SET consumed_at=?,consumed_by=? WHERE id=? AND consumed_at IS NULL AND expires_at>?').bind(now,claim,c.id,now),
    env.DB.prepare('INSERT INTO group_recovery_read_checks VALUES (?,?,?,?)').bind(claim,c.person_id,c.id,now),
    env.DB.prepare('DELETE FROM group_recovery_read_checks WHERE id=?').bind(claim)]);
   const head=await loadStoredGroupRoster(env.DB,windowId);
   const actor:GroupActor={deviceId:done.device_id,personId:c.person_id,identityPublicKey:c.identity_public_key,
    signingPublicKey:d.signing_public_key,hpkePublicKey:d.hpke_public_key,nonce:claim,now,requestHash:''};
   const keys=await (await getGroupKey(env,actor,windowId,head.packet.roster.keyEpoch)).json() as Record<string,unknown>;
   return jsonResponse({...keys,state:'recoveryCommitted',deviceId:done.device_id,previousHash:done.previous_hash,
    revision:head.packet.roster.revision,rosterHash:head.hash,canOpen:false,canSend:false});
  }
  const head=await loadStoredGroupRoster(env.DB,windowId),{recipient,boundary}=await recoveryDeliveryState(env,row,head);
  const claim=crypto.randomUUID(),statements=[
   env.DB.prepare('UPDATE group_recovery_challenges SET consumed_at=?,consumed_by=? WHERE id=? AND consumed_at IS NULL AND expires_at>?').bind(now,claim,c.id,now),
   env.DB.prepare('INSERT INTO group_recovery_read_checks VALUES (?,?,?,?)').bind(claim,c.person_id,c.id,now),
   ...recoveryKeyChecks(env,row,head,claim),
   env.DB.prepare('DELETE FROM group_recovery_read_checks WHERE id=?').bind(claim)];
  if(!boundary){await recoveryExpiryCheckedBatch(env.DB,statements);return jsonResponse({state:'needsParticipationProof',canOpen:false,canSend:false,items:[]});}
  if(!receipt){
   const rows=await env.DB.prepare(`SELECT offer_json,received_at FROM group_recovery_key_offers
    WHERE person_id=? AND operation_id=? AND roster_hash=? AND expires_at>? AND key_epoch>? ORDER BY key_epoch LIMIT 17`)
    .bind(c.person_id,operation,head.hash,now,after).all<{offer_json:string;received_at:number|null}>();
   const items=[];
   for(const stored of rows.results.slice(0,16)){
    const offer=JSON.parse(stored.offer_json) as RecoveryKeyOffer,old=await recoveryEpoch(env,head,offer.keyEpoch);
    if(!await verifyRecoveryOffer(offer,head,old,recipient,boundary,now))throw new ApiError(409,'recovery_proof_invalid','Recovery proof is invalid.');
    items.push({offer,epochRoster:old.packet,received:stored.received_at!==null});
   }
   await recoveryExpiryCheckedBatch(env.DB,statements);await requireCurrentIdentity(env,c.person_id);
   return jsonResponse({state:'waitingForReceipt',canOpen:false,canSend:false,roster:head.packet,participation:boundary,recipientProof:JSON.parse(row.proof_json),
    items,nextAfterEpoch:rows.results.length>16?items.at(-1)!.offer.keyEpoch:null});
  }
  const stored=await env.DB.prepare(`SELECT offer_json,offer_hash FROM group_recovery_key_offers
   WHERE person_id=? AND operation_id=? AND key_epoch=? AND offer_id=? AND roster_hash=? AND expires_at>?`)
   .bind(c.person_id,operation,epoch,offerId,head.hash,now).first<{offer_json:string;offer_hash:string}>();
  if(!stored)throw new ApiError(409,'recovery_offer_unavailable','Recovery offer is unavailable.');
  const offer=JSON.parse(stored.offer_json) as RecoveryKeyOffer,old=await recoveryEpoch(env,head,epoch);
  const device={id:row.device_id,signingPublicKey:row.signing_public_key,hpkePublicKey:row.hpke_public_key,personAuthorization:authorization};
  if(!await verifyRecoveryOffer(offer,head,old,recipient,boundary,now)
    ||!await verifyEd25519(row.signing_public_key,receiptSignature,await recoveryReceiptBytes(offer))
    ||!await verifyEd25519(c.identity_public_key,authorization,groupDeviceAuthorization(windowId,c.person_id,device)))throw denied();
  statements.push(env.DB.prepare(`UPDATE group_recovery_key_offers SET received_at=COALESCE(received_at,?),receipt_signature=?,person_authorization=?
   WHERE person_id=? AND operation_id=? AND key_epoch=? AND offer_hash=? AND expires_at>?`)
   .bind(now,receiptSignature,authorization,c.person_id,operation,epoch,stored.offer_hash,now));
  await recoveryExpiryCheckedBatch(env.DB,statements);await requireCurrentIdentity(env,c.person_id);
  const committed=await env.DB.prepare(`SELECT 1 FROM group_recovery_key_offers WHERE person_id=? AND operation_id=?
   AND key_epoch=? AND offer_hash=? AND received_at IS NOT NULL AND receipt_signature=? AND person_authorization=?`)
   .bind(c.person_id,operation,epoch,stored.offer_hash,receiptSignature,authorization).first();
  if(!committed)throw new ApiError(409,'recovery_offer_unavailable','Recovery offer changed.');
  return jsonResponse({state:'receivedWaitingForOwner',operationId:operation,offerId,canOpen:false,canSend:false});
 });
}
