import type { Env } from './env';
import { ApiError, jsonResponse } from './errors';
import { base64urlDecode, sha256Base64url, verifyEd25519 } from './encoding';
import { groupFields, loadStoredGroupRoster } from './group-protocol';
import { groupDeviceKeyHash } from './group-identities';
import { anchorReceiptTranscript } from './group-anchor-receipts';
import { protectedGroupRead, requireCurrentIdentity } from './group-identity-service';
import { binaryField, exactKeys, opaqueId, stringField, uuidField } from './validation';
import { recoveryCatalogTranscript, type RecoveryChallenge } from './group-recovery-catalog';

export interface PendingIntent { windowId:string; signingPublicKey:string; hpkePublicKey:string; model:string }
export function pendingIntentBytes(i:PendingIntent):Uint8Array {
 return groupFields(['NW3.RECOVERY.PENDING.INTENT.V1',i.windowId,base64urlDecode(i.signingPublicKey,32),base64urlDecode(i.hpkePublicKey,32),i.model]);
}
export function pendingAuthentication(c:RecoveryChallenge,windowId:string,intent?:PendingIntent,signer='root'):Uint8Array {
 return groupFields([intent?'NW3.RECOVERY.PENDING.REGISTER.V1':'NW3.RECOVERY.PENDING.STATUS.V1',signer,
  recoveryCatalogTranscript(c),windowId,intent?pendingIntentBytes(intent):new Uint8Array()]);
}
const denied=()=>new ApiError(401,'recovery_authentication_failed','Recovery authentication failed.');
interface PendingRow {device_id:string;request_hash:string;model:string;created_at:number}
async function readState(env:Env,c:RecoveryChallenge,windowId:string,row:PendingRow|null) {
 const receipt=await env.DB.prepare('SELECT owner_person_id,owner_public_key,root_signature FROM group_anchor_receipts WHERE person_id=? AND space_id=? AND environment=?')
  .bind(c.person_id,windowId,c.environment).first<{owner_person_id:string;owner_public_key:string;root_signature:string}>();
 let valid=false;
 if(receipt) {try {valid=receipt.owner_person_id===await sha256Base64url(base64urlDecode(receipt.owner_public_key,32)) && await verifyEd25519(c.identity_public_key,receipt.root_signature,
  anchorReceiptTranscript(c.environment,c.person_id,windowId,receipt.owner_person_id,receipt.owner_public_key));}catch{}}
 if(!valid||!receipt)return {state:'needsOriginalDeviceOrInvitation',canOpen:false,canSend:false,exists:true};
 const roster=await loadStoredGroupRoster(env.DB,windowId);
 const owner=roster.packet.roster.members.find(m=>m.role==='owner');
 if(owner?.personId!==receipt.owner_person_id||owner.identityPublicKey!==receipt.owner_public_key)throw new ApiError(409,'anchor_receipt_conflict','The anchor changed.');
 if(!roster.packet.roster.members.some(m=>m.personId===c.person_id))throw denied();
 const providers=await env.DB.prepare(`SELECT
  (SELECT COUNT(*) FROM group_members m JOIN group_people p ON p.id=m.person_id WHERE m.space_id=? AND m.state='active' AND p.state='active' AND m.person_id<>?) AS others,
  (SELECT COUNT(*) FROM group_window_devices w JOIN group_person_devices d ON d.id=w.device_id JOIN group_members m ON m.participant_id=w.participant_id
   WHERE w.space_id=? AND m.person_id=? AND m.state='active' AND w.state='active' AND d.state='active') AS ownDevices`).bind(windowId,c.person_id,windowId,c.person_id).first<{others:number;ownDevices:number}>();
 if(!providers)throw new ApiError(503,'unavailable','Recovery state unavailable.');
 const noProvider=providers.others===0&&providers.ownDevices===0;
 const freshAllowed=noProvider&&owner.personId===c.person_id;
 return {state:row?(freshAllowed?'noKeyProvider':'registeredWaitingForKeys'):'notStarted',exists:true,canOpen:false,canSend:false,
  canRequestFreshGeneration:!!row&&freshAllowed,
  deviceId:row?.device_id??null,model:row?.model??null,registeredAt:row?.created_at??null,
  anchorReceipt:{environment:c.environment,personId:c.person_id,windowId,ownerPersonId:receipt.owner_person_id,ownerPublicKey:receipt.owner_public_key,rootSignature:receipt.root_signature},
  roster:roster.packet,revision:roster.packet.roster.revision,rosterHash:roster.hash};
}
/** Pending-only registration: no active identity/device/membership, roster or epoch write. */
export async function groupRecoveryPendingAPI(env:Env,body:Record<string,unknown>,path:string,now:number):Promise<Response> {
 const match=path.match(/^\/v3\/group-recovery\/operations\/([0-9a-f-]{36})(\/status)?$/u);if(!match)throw new ApiError(404,'not_found','Endpoint unavailable.');
 const register=!match[2];
 exactKeys(body,register?['challengeId','windowId','signingPublicKey','hpkePublicKey','model','rootSignature','deviceSignature']:['challengeId','windowId','rootSignature']);
 const windowId=stringField(body,'windowId');opaqueId(windowId,'windowId');
 const rootSignature=binaryField(body,'rootSignature',64);
 const c=await env.DB.prepare('SELECT * FROM group_recovery_challenges WHERE id=?').bind(uuidField(body,'challengeId')).first<RecoveryChallenge>();
 if(!c||c.operation_id!==match[1]||c.environment!==env.ENVIRONMENT||c.purpose!==(register?'register':'status')||c.consumed_at!==null||now<c.issued_at||now>=c.expires_at)throw denied();
 let intent:PendingIntent|undefined;
 if(register){const model=stringField(body,'model');if(model.length<1||model.length>80||/[\u0000-\u001f\u007f]/u.test(model))throw new ApiError(400,'invalid_request','Invalid device model.');
  intent={windowId,signingPublicKey:binaryField(body,'signingPublicKey',32),hpkePublicKey:binaryField(body,'hpkePublicKey',32),model};}
 if(!await verifyEd25519(c.identity_public_key,rootSignature,pendingAuthentication(c,windowId,intent)))throw denied();
 if(intent&&!await verifyEd25519(intent.signingPublicKey,binaryField(body,'deviceSignature',64),pendingAuthentication(c,windowId,intent,'device')))throw denied();
 await requireCurrentIdentity(env,c.person_id);
 return protectedGroupRead(env,async()=>{
  const membership=await env.DB.prepare(`SELECT 1 FROM group_members m JOIN group_windows w ON w.space_id=m.space_id JOIN group_people p ON p.id=m.person_id
   WHERE m.person_id=? AND m.space_id=? AND m.state='active' AND w.mode='active' AND p.state='active'`).bind(c.person_id,windowId).first();if(!membership)throw denied();
  const previous=await env.DB.prepare('SELECT * FROM group_recovery_pending WHERE person_id=? AND operation_id=?').bind(c.person_id,c.operation_id).first<PendingRow & {window_id:string}>();
  if(previous&&previous.window_id!==windowId)throw new ApiError(409,'idempotency_conflict','Different recovery intent.');
  const state=await readState(env,c,windowId,previous);
  const claim=crypto.randomUUID();const statements=[
   env.DB.prepare('UPDATE group_recovery_challenges SET consumed_at=?,consumed_by=? WHERE id=? AND consumed_at IS NULL AND expires_at>?').bind(now,claim,c.id,now),
   env.DB.prepare('INSERT INTO group_recovery_read_checks VALUES (?,?,?,?)').bind(claim,c.person_id,c.id,now),
  ];
  if(intent&&state.state!=='needsOriginalDeviceOrInvitation'){
   const device=await groupDeviceKeyHash(intent.signingPublicKey,intent.hpkePublicKey),hash=await sha256Base64url(pendingIntentBytes(intent));
   if(previous&&previous.request_hash!==hash)throw new ApiError(409,'idempotency_conflict','Different recovery intent.');
   if(!previous)statements.push(env.DB.prepare('INSERT INTO group_recovery_pending VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(person_id,operation_id) DO NOTHING')
    .bind(c.person_id,c.operation_id,windowId,c.environment,device,intent.signingPublicKey,intent.hpkePublicKey,intent.model,hash,JSON.stringify({challenge:c,rootSignature,deviceSignature:body.deviceSignature,intent}),now));
  }
  statements.push(env.DB.prepare('DELETE FROM group_recovery_read_checks WHERE id=?').bind(claim));
  try{await env.DB.batch(statements);}catch(error){const message=String(error);if(message.includes('group_device_limit'))throw new ApiError(409,'device_limit','Three device slots are already reserved.');
   if(message.includes('UNIQUE constraint failed: group_recovery_pending'))throw new ApiError(409,'device_pending','Device already has a pending registration.');
   if(message.includes('group_recovery_'))throw denied();throw error;}
  // Recheck current root/membership after the commit before disclosing a roster.
  await requireCurrentIdentity(env,c.person_id);
  const active=await env.DB.prepare("SELECT 1 FROM group_members m JOIN group_windows w ON w.space_id=m.space_id JOIN group_people p ON p.id=m.person_id WHERE m.person_id=? AND m.space_id=? AND m.state='active' AND w.mode='active' AND p.state='active'").bind(c.person_id,windowId).first();if(!active)throw denied();
  const saved=await env.DB.prepare('SELECT * FROM group_recovery_pending WHERE person_id=? AND operation_id=?').bind(c.person_id,c.operation_id).first<PendingRow>();
  if(intent&&saved&&saved.request_hash!==await sha256Base64url(pendingIntentBytes(intent)))throw new ApiError(409,'idempotency_conflict','Different recovery intent.');
  return jsonResponse({operationId:c.operation_id,personId:c.person_id,windowId,...await readState(env,c,windowId,saved)});
 });
}
