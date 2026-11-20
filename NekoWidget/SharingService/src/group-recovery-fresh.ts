import type {Env} from './env';
import {ApiError,jsonResponse} from './errors';
import {base64urlDecode,sha256Base64url,verifyEd25519} from './encoding';
import {groupFields,loadStoredGroupRoster,verifySoloRecoveryRoster,verifyGroupEnvelopes,type SignedGroupRoster} from './group-protocol';
import {groupRecoverySignatureBytes,type GroupRecoveryProof,type GroupRecoveryLedger} from './group-recovery-proof';
import {recoveryCatalogTranscript,type RecoveryChallenge} from './group-recovery-catalog';
import {anchorReceiptTranscript} from './group-anchor-receipts';
import {groupDeviceKeyHash} from './group-identities';
import {protectedGroupRead,requireCurrentIdentity} from './group-identity-service';
import {groupCipher,groupNames,groupEnvelopes,groupPacketStatements} from './group-windows';
import {asObject,binaryField,exactKeys,stringField,uuidField} from './validation';
import {recoveryExpiryCheckedBatch,recoveryPendingLifetime} from './group-recovery-expiry';

function fail(code='recovery_fresh_unavailable'):never{throw new ApiError(409,code,'Fresh recovery is unavailable.');}
export function freshConsentTranscript(c:RecoveryChallenge,hash:string):Uint8Array{
 return groupFields(['NW3.RECOVERY.FRESH-CONSENT.V1',recoveryCatalogTranscript(c),base64urlDecode(hash,32)]);
}
export async function freshMaterialHash(body:Record<string,unknown>):Promise<string>{
 // JSON is NOT signed directly: explicit fields keep Swift/JS independent of key order.
 const packet=asObject(body.packet) as unknown as SignedGroupRoster,r=packet.roster;
 const names=asObject(body.encryptedMemberNames),envelopes=groupEnvelopes(body);
 if(r.members.length!==1||envelopes.length!==1||Object.keys(names).length!==1)fail();
 const e=envelopes[0]!;
 return sha256Base64url(groupFields(['NW3.RECOVERY.FRESH-MATERIAL.V1',r.windowId,String(r.revision),String(r.keyEpoch),
  base64urlDecode(r.previousHash,32),packet.signerDeviceId,base64urlDecode(packet.signature,64),
  groupCipher(body,'encryptedName'),r.members[0]!.participantId,groupCipher(names,r.members[0]!.participantId,2048),
  e.windowId,String(e.keyEpoch),e.rosterHash,e.deviceId,e.encapsulatedKey,e.ciphertext,e.signerDeviceId,e.signature]));
}
/** The only key-generation exception: signed solo owner, explicit consent and
 * zero effective providers checked again inside the same D1 batch as issuance. */
export async function freshRecovery(env:Env,body:Record<string,unknown>,operation:string,now:number):Promise<Response>{
 exactKeys(body,['challengeId','proof','packet','envelopes','encryptedName','encryptedMemberNames','consentSignature']);
 const c=await env.DB.prepare('SELECT * FROM group_recovery_challenges WHERE id=?').bind(uuidField(body,'challengeId')).first<RecoveryChallenge>();
 if(!c||c.environment!==env.ENVIRONMENT||c.operation_id!==operation||c.purpose!=='register'||c.consumed_at!==null||now<c.issued_at||now>=c.expires_at)fail();
 const proof=asObject(body.proof) as unknown as GroupRecoveryProof,claim=proof.claim,materialHash=await freshMaterialHash(body);
 if(!await verifyEd25519(c.identity_public_key,binaryField(body,'consentSignature',64),freshConsentTranscript(c,materialHash))
 ||!await verifyEd25519(c.identity_public_key,proof.rootSignature,groupRecoverySignatureBytes(claim,'root'))
 ||claim.personId!==c.person_id||claim.operationId!==operation||claim.environment!==c.environment)fail();
 await requireCurrentIdentity(env,c.person_id);
 return protectedGroupRead(env,async()=>{
  const prior=await env.DB.prepare('SELECT * FROM group_recovery_fresh_generations WHERE person_id=? AND operation_id=?')
   .bind(c.person_id,operation).first<{window_id:string;device_id:string;result_revision:number;result_hash:string;request_hash:string}>();
  const response=(row:typeof prior)=>({personId:c.person_id,operationId:operation,windowId:row!.window_id,
   deviceId:row!.device_id,revision:row!.result_revision,rosterHash:row!.result_hash,state:'freshGenerationCommitted'});
  if(prior){if(prior.request_hash!==materialHash)fail('idempotency_conflict');
   const active=await env.DB.prepare(`SELECT 1 FROM group_windows w JOIN group_person_devices d ON d.id=?
    JOIN group_members m ON m.space_id=w.space_id AND m.person_id=d.person_id
    WHERE w.space_id=? AND w.mode='active' AND m.state='active' AND d.state='active' AND d.person_id=?`)
    .bind(prior.device_id,prior.window_id,c.person_id).first();if(!active)fail();return jsonResponse(response(prior));}
  const pending=await env.DB.prepare('SELECT * FROM group_recovery_pending WHERE person_id=? AND operation_id=? AND created_at>?')
   .bind(c.person_id,operation,now-recoveryPendingLifetime).first<{window_id:string;device_id:string;signing_public_key:string;hpke_public_key:string;model:string}>();
  if(!pending||pending.window_id!==claim.windowId||pending.device_id!==claim.newDevice.id
   ||pending.signing_public_key!==claim.newDevice.signingPublicKey||pending.hpke_public_key!==claim.newDevice.hpkePublicKey
   ||pending.device_id!==await groupDeviceKeyHash(pending.signing_public_key,pending.hpke_public_key))fail();
  const receipt=await env.DB.prepare('SELECT owner_person_id,owner_public_key,root_signature FROM group_anchor_receipts WHERE person_id=? AND space_id=? AND environment=?')
   .bind(c.person_id,pending.window_id,c.environment).first<{owner_person_id:string;owner_public_key:string;root_signature:string}>();
  if(!receipt||receipt.owner_person_id!==c.person_id||receipt.owner_public_key!==c.identity_public_key
   ||!await verifyEd25519(c.identity_public_key,receipt.root_signature,anchorReceiptTranscript(c.environment,c.person_id,pending.window_id,c.person_id,c.identity_public_key)))fail();
  const previous=await loadStoredGroupRoster(env.DB,pending.window_id),owner=previous.packet.roster.members[0]!;
  const revoked=!!await env.DB.prepare("SELECT 1 FROM group_person_devices WHERE id=? AND state='revoked'").bind(pending.device_id).first();
  const ledger:GroupRecoveryLedger={environment:c.environment,windowId:pending.window_id,personId:c.person_id,participantId:owner.participantId,
   identityPublicKey:c.identity_public_key,revision:previous.packet.roster.revision,hash:previous.hash,
   recoveryGeneration:previous.packet.roster.revision,state:'active',newDeviceWasRevoked:revoked,
   challenge:{value:c.nonce,operationId:operation,issuedAt:c.issued_at,expiresAt:c.expires_at,consumed:false}};
  const next=await verifySoloRecoveryRoster(asObject(body.packet) as unknown as SignedGroupRoster,previous,proof,ledger,now);
  const envelopes=groupEnvelopes(body);await verifyGroupEnvelopes(envelopes,next);
  const names=groupNames(body,next),name=groupCipher(body,'encryptedName'),r=next.packet.roster,check=crypto.randomUUID();
  await recoveryExpiryCheckedBatch(env.DB,[
   env.DB.prepare('UPDATE group_recovery_challenges SET consumed_at=?,consumed_by=? WHERE id=? AND consumed_at IS NULL AND expires_at>?').bind(now,check,c.id,now),
   env.DB.prepare('INSERT INTO group_recovery_read_checks VALUES (?,?,?,?)').bind(check,c.person_id,c.id,now),
   env.DB.prepare('INSERT INTO group_recovery_fresh_checks VALUES (?,?,?,?,?,?,?)').bind(check,c.person_id,operation,pending.window_id,pending.device_id,previous.packet.roster.revision,previous.hash),
   env.DB.prepare("INSERT INTO group_person_devices VALUES (?,?,?,?,?,'active',?,NULL) ON CONFLICT(id) DO NOTHING")
    .bind(pending.device_id,c.person_id,pending.signing_public_key,pending.hpke_public_key,JSON.stringify(proof),now),
   env.DB.prepare('INSERT INTO group_recovery_device_labels VALUES (?,?) ON CONFLICT(device_id) DO NOTHING').bind(pending.device_id,pending.model),
   env.DB.prepare("UPDATE group_window_devices SET state='revoked',removed_revision=? WHERE space_id=? AND state='active'").bind(r.revision,pending.window_id),
   env.DB.prepare("INSERT INTO group_window_devices VALUES (?,?,?,'active',?,NULL)").bind(pending.window_id,pending.device_id,owner.participantId,r.revision),
   env.DB.prepare('UPDATE group_members SET display_name_ciphertext=? WHERE participant_id=?').bind(names[owner.participantId],owner.participantId),
   ...groupPacketStatements(env,next,envelopes,{deviceId:pending.device_id,personId:c.person_id,signingPublicKey:pending.signing_public_key,
    hpkePublicKey:pending.hpke_public_key,identityPublicKey:c.identity_public_key,nonce:check,now,requestHash:materialHash},operation,'rotate',previous.packet.roster.revision),
   env.DB.prepare('UPDATE group_window_metadata SET encrypted_name=?,key_epoch=?,roster_revision=? WHERE space_id=?').bind(name,r.keyEpoch,r.revision,pending.window_id),
   env.DB.prepare('INSERT INTO group_recovery_fresh_generations VALUES (?,?,?,?,?,?,?,?,?,?)').bind(c.person_id,operation,pending.window_id,pending.device_id,previous.packet.roster.revision,r.revision,next.hash,materialHash,JSON.stringify(proof),now),
   env.DB.prepare('DELETE FROM group_recovery_pending WHERE person_id=? AND operation_id=?').bind(c.person_id,operation),
   env.DB.prepare('DELETE FROM group_recovery_fresh_checks WHERE id=?').bind(check),
   env.DB.prepare('DELETE FROM group_recovery_read_checks WHERE id=?').bind(check),
  ]);
  await requireCurrentIdentity(env,c.person_id);
  return jsonResponse(response({window_id:pending.window_id,device_id:pending.device_id,result_revision:r.revision,result_hash:next.hash,request_hash:materialHash}));
 });
}
