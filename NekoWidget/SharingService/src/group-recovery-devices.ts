import type {Env} from './env';
import {ApiError,jsonResponse} from './errors';
import {base64urlDecode,verifyEd25519} from './encoding';
import {groupFields} from './group-protocol';
import {recoveryCatalogTranscript,type RecoveryChallenge} from './group-recovery-catalog';
import {protectedGroupRead,requireCurrentIdentity} from './group-identity-service';
import {binaryField,exactKeys,uuidField} from './validation';

export const recoveryDeviceRemovalTranscript=(c:RecoveryChallenge,device:string)=>
 groupFields(['NW3.RECOVERY.REMOVE-DEVICE.V1',recoveryCatalogTranscript(c),base64urlDecode(device,32)]);
/** Removing this person's device revokes its server access across their memberships.
 * Does not revoke the root, delete photos, leave a family, or select another root. */
export async function removeRecoveryDevice(env:Env,body:Record<string,unknown>,now:number):Promise<Response>{
 exactKeys(body,['challengeId','deviceId','rootSignature']);
 const device=binaryField(body,'deviceId',32),c=await env.DB.prepare('SELECT * FROM group_recovery_challenges WHERE id=?')
 .bind(uuidField(body,'challengeId')).first<RecoveryChallenge>();
 if(!c||c.environment!==env.ENVIRONMENT||c.purpose!=='register'||c.consumed_at!==null||now<c.issued_at||now>=c.expires_at
 ||!await verifyEd25519(c.identity_public_key,binaryField(body,'rootSignature',64),recoveryDeviceRemovalTranscript(c,device)))
 throw new ApiError(401,'recovery_authentication_failed','Recovery authentication failed.');
 await requireCurrentIdentity(env,c.person_id);
 return protectedGroupRead(env,async()=>{
  const previous=await env.DB.prepare('SELECT device_id FROM group_recovery_device_removals WHERE person_id=? AND operation_id=?').bind(c.person_id,c.operation_id).first<{device_id:string}>();
  if(previous&&previous.device_id!==device)throw new ApiError(409,'idempotency_conflict','Different removal intent.');
  const owned=await env.DB.prepare(`SELECT id FROM group_person_devices WHERE id=? AND person_id=?
   UNION SELECT device_id FROM group_recovery_pending WHERE device_id=? AND person_id=?
   UNION SELECT device_id FROM group_recovery_device_removals WHERE device_id=? AND person_id=?`)
   .bind(device,c.person_id,device,c.person_id,device,c.person_id).first();
  if(!owned)throw new ApiError(404,'device_not_found','Device unavailable.');
  const claim=crypto.randomUUID();
  await env.DB.batch([
   env.DB.prepare('UPDATE group_recovery_challenges SET consumed_at=?,consumed_by=? WHERE id=? AND consumed_at IS NULL AND expires_at>?').bind(now,claim,c.id,now),
   env.DB.prepare('INSERT INTO group_recovery_read_checks VALUES (?,?,?,?)').bind(claim,c.person_id,c.id,now),
   env.DB.prepare('INSERT INTO group_recovery_device_removals VALUES (?,?,?,?) ON CONFLICT(person_id,operation_id) DO NOTHING').bind(c.person_id,c.operation_id,device,now),
   env.DB.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM group_recovery_device_removals WHERE person_id=? AND operation_id=? AND device_id=?) THEN 'true' ELSE 'conflicting removal intent' END)`).bind(c.person_id,c.operation_id,device),
   env.DB.prepare(`UPDATE group_windows SET rotation_required=1 WHERE mode='active' AND space_id IN
    (SELECT space_id FROM group_window_devices WHERE device_id=? AND state='active')`).bind(device),
   env.DB.prepare(`UPDATE group_window_devices SET state='revoked',removed_revision=(SELECT revision FROM group_windows WHERE space_id=group_window_devices.space_id)
    WHERE device_id=? AND state='active'`).bind(device),
   env.DB.prepare("UPDATE group_person_devices SET state='revoked',revoked_at=? WHERE id=? AND person_id=? AND state='active'").bind(now,device,c.person_id),
   env.DB.prepare('DELETE FROM group_recovery_pending WHERE person_id=? AND device_id=?').bind(c.person_id,device),
   ...['group_push_subscriptions','group_join_push_subscriptions','family_push_subscriptions'].map(t=>env.DB.prepare(`UPDATE ${t} SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest='' WHERE device_id=?`).bind(device)),
   env.DB.prepare('DELETE FROM group_recovery_read_checks WHERE id=?').bind(claim),
  ]);
  return jsonResponse({personId:c.person_id,operationId:c.operation_id,deviceId:device,state:'revoked'});
 });
}
