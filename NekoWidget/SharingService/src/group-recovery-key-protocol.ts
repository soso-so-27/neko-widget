import {base64urlDecode,sha256Base64url,verifyEd25519} from './encoding';
import {groupFields,type VerifiedGroupRoster} from './group-protocol';
import {pendingAuthentication,type PendingIntent} from './group-recovery-pending';
import type {RecoveryChallenge} from './group-recovery-catalog';
import {groupDeviceKeyHash} from './group-identities';
import {participationAllowsEpoch,type VerifiedParticipation} from './group-recovery-participation';
import {asObject,binaryField,exactKeys,integerField,stringField,uuidField} from './validation';

export interface RecoveryPendingProof {
 challenge:RecoveryChallenge; intent:PendingIntent; rootSignature:string; deviceSignature:string;
}
const pendingVerified=Symbol('verified-pending-recipient');
export interface VerifiedRecoveryRecipient {
 readonly [pendingVerified]:true; readonly operationId:string; readonly personId:string;
 readonly deviceId:string; readonly signingPublicKey:string; readonly hpkePublicKey:string;
 readonly environment:'production'|'staging'; readonly windowId:string;
}
export async function verifyRecoveryRecipient(value:unknown,head:VerifiedGroupRoster,environment:'production'|'staging'):
 Promise<VerifiedRecoveryRecipient|null> {
 try {
  const o=asObject(value);exactKeys(o,['challenge','intent','rootSignature','deviceSignature']);
  const p=o as unknown as RecoveryPendingProof,c=p.challenge,i=p.intent;
  exactKeys(asObject(i),['windowId','signingPublicKey','hpkePublicKey','model']);
  const member=head.packet.roster.members.find(m=>m.personId===c.person_id);
  if(!member||c.purpose!=='register'||c.environment!==environment||i.windowId!==head.packet.roster.windowId
    ||c.identity_public_key!==member.identityPublicKey||c.person_id!==await sha256Base64url(base64urlDecode(c.identity_public_key,32))
    ||!Number.isSafeInteger(c.issued_at)||!Number.isSafeInteger(c.expires_at)||c.expires_at-c.issued_at!==300
    ||typeof i.model!=='string'||i.model.length<1||i.model.length>80||/[\u0000-\u001f\u007f]/u.test(i.model))return null;
  uuidField({operation:c.operation_id},'operation');uuidField({challenge:c.id},'challenge');
  if(!await verifyEd25519(member.identityPublicKey,p.rootSignature,pendingAuthentication(c,i.windowId,i))
    ||!await verifyEd25519(i.signingPublicKey,p.deviceSignature,pendingAuthentication(c,i.windowId,i,'device')))return null;
  return Object.freeze({[pendingVerified]:true as const,operationId:c.operation_id,personId:c.person_id,
   deviceId:await groupDeviceKeyHash(i.signingPublicKey,i.hpkePublicKey),signingPublicKey:i.signingPublicKey,hpkePublicKey:i.hpkePublicKey,
   environment,windowId:i.windowId});
 }catch{return null;}
}

export interface RecoveryKeyOffer {
 environment:'production'|'staging';windowId:string;operationId:string;offerId:string;keyEpoch:number;
 epochRosterHash:string;currentRosterHash:string;recipientDeviceId:string;senderDeviceId:string;
 encapsulatedKey:string;ciphertext:string;expiresAt:number;signature:string;
}
export function recoveryKeyContext(o:RecoveryKeyOffer):Uint8Array {
 return groupFields(['NW3.RECOVERY.KEY.V1',o.environment,o.windowId,o.operationId,o.offerId,String(o.keyEpoch),
  base64urlDecode(o.epochRosterHash,32),base64urlDecode(o.currentRosterHash,32),o.recipientDeviceId,o.senderDeviceId,String(o.expiresAt)]);
}
export async function recoveryOfferBytes(o:RecoveryKeyOffer):Promise<Uint8Array>{
 return groupFields(['NW3.RECOVERY.KEY.SIGN.V1',recoveryKeyContext(o),base64urlDecode(o.encapsulatedKey,32),
  base64urlDecode(await sha256Base64url(base64urlDecode(o.ciphertext,48)),32)]);
}
export async function verifyRecoveryOffer(value:unknown,current:VerifiedGroupRoster,epoch:VerifiedGroupRoster,
 recipient:VerifiedRecoveryRecipient,boundary:VerifiedParticipation,now:number):Promise<RecoveryKeyOffer|null>{
 try{
  const raw=asObject(value);exactKeys(raw,['environment','windowId','operationId','offerId','keyEpoch','epochRosterHash','currentRosterHash',
   'recipientDeviceId','senderDeviceId','encapsulatedKey','ciphertext','expiresAt','signature']);
  const o=raw as unknown as RecoveryKeyOffer;
  uuidField(raw,'offerId');uuidField(raw,'operationId');
  integerField(raw,'keyEpoch',1,Number.MAX_SAFE_INTEGER);integerField(raw,'expiresAt',1,Number.MAX_SAFE_INTEGER);
  const sender=current.packet.roster.members.flatMap(m=>m.devices).find(d=>d.id===o.senderDeviceId);
  const pastSender=epoch.packet.roster.members.flatMap(m=>m.devices).find(d=>d.id===o.senderDeviceId);
  if(!sender||!pastSender||sender.signingPublicKey!==pastSender.signingPublicKey
   ||boundary.personId!==recipient.personId||!participationAllowsEpoch(boundary,current,epoch)
   ||o.environment!==recipient.environment||o.windowId!==recipient.windowId||o.operationId!==recipient.operationId
   ||o.keyEpoch!==epoch.packet.roster.keyEpoch||o.epochRosterHash!==epoch.hash||o.currentRosterHash!==current.hash
   ||o.recipientDeviceId!==recipient.deviceId||o.expiresAt<=now||o.expiresAt>now+86400)return null;
  binaryField(raw,'signature',64);binaryField(raw,'encapsulatedKey',32);binaryField(raw,'ciphertext',48);
  if(!await verifyEd25519(sender.signingPublicKey,o.signature,await recoveryOfferBytes(o)))return null;
  return Object.freeze({...o});
 }catch{return null;}
}
export async function recoveryReceiptBytes(offer:RecoveryKeyOffer):Promise<Uint8Array>{
 return groupFields(['NW3.RECOVERY.KEY.RECEIPT.V1',recoveryKeyContext(offer),
  base64urlDecode(await sha256Base64url(await recoveryOfferBytes(offer)),32),base64urlDecode(offer.signature,64)]);
}
