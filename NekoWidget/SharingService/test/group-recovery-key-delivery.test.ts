import {expect,it} from 'vitest';
import {plusOwner} from './group-billing-fixture';
import {create,key,packet,sign,db,signed,send,ok,testEnv} from './group-fixture';
import {randomBase64url,base64urlDecode} from '../src/encoding';
import {groupRecoveryCatalogAPI,type RecoveryChallenge} from '../src/group-recovery-catalog';
import {pendingAuthentication} from '../src/group-recovery-pending';
import {anchorReceiptTranscript} from '../src/group-anchor-receipts';
import {participationBytes,type ParticipationBoundary} from '../src/group-recovery-participation';
import {groupDeviceAuthorization,groupFields} from '../src/group-protocol';
import {recoveryOfferBytes,recoveryReceiptBytes,type RecoveryKeyOffer} from '../src/group-recovery-key-protocol';
import {recoveryRecipientAction} from '../src/group-recovery-key-recipient';
const settings={...testEnv,ENVIRONMENT:'staging',GROUP_RECOVERY_CATALOG_ENABLED:'YES',MEMBER_RATE_LIMITER:{limit:async()=>({success:true})}};
const req=(path:string,body:unknown)=>new Request('https://example.test/v3/group-recovery/'+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
it('keeps registration pending through stable encrypted delivery and exact recipient receipt',async()=>{
 const owner=await plusOwner(),w=await create(owner),device=await key(),operation=crypto.randomUUID(),now=Math.floor(Date.now()/1000);
 const intent={windowId:w.windowId,signingPublicKey:device.publicKey,hpkePublicKey:randomBase64url(32),model:'Synthetic iPhone'};
 ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/anchor-receipt`,{environment:'staging',personId:owner.id,
  ownerPersonId:owner.id,ownerPublicKey:owner.identity.publicKey,
  rootSignature:await sign(owner.identity.privateKey,anchorReceiptTranscript('staging',owner.id,w.windowId,owner.id,owner.identity.publicKey))}),settings));
 const challenge=async(purpose:string)=>{const r=await groupRecoveryCatalogAPI(req('challenges',{identityPublicKey:owner.identity.publicKey,operationId:operation,purpose}),settings);return (await r.json() as {challenge:RecoveryChallenge}).challenge;};
 const c=await challenge('register');
 const pending=await (await groupRecoveryCatalogAPI(req(`operations/${operation}`,{challengeId:c.id,...intent,
  rootSignature:await sign(owner.identity.privateKey,pendingAuthentication(c,w.windowId,intent)),
  deviceSignature:await sign(device.privateKey,pendingAuthentication(c,w.windowId,intent,'device'))}),settings)).json() as {deviceId:string};
 const path=`/v3/group-windows/${w.windowId}/recovery/`;
 const unknown=ok(await send(await signed(owner,path+'pending',{}),settings));expect(unknown.items[0].state).toBe('needsParticipationProof');
 // Known synthetic genesis: tests the delivery transport, not a production backfill.
 const u:Omit<ParticipationBoundary,'signature'>={environment:'staging',windowId:w.windowId,personId:owner.id,
  participantId:w.roster.members[0]!.participantId,admissionRevision:1,rosterHash:w.hash,signerDeviceId:owner.deviceId};
 const boundary={...u,signature:await sign(owner.signing.privateKey,participationBytes(u))};
 await db.prepare('INSERT INTO group_recovery_participation VALUES (?,?,?,?,?)').bind(w.windowId,owner.id,u.participantId,w.hash,JSON.stringify(boundary)).run();
 const offer:RecoveryKeyOffer={environment:'staging',windowId:w.windowId,operationId:operation,offerId:crypto.randomUUID(),keyEpoch:1,
  epochRosterHash:w.hash,currentRosterHash:w.hash,recipientDeviceId:pending.deviceId,senderDeviceId:owner.deviceId,
  encapsulatedKey:randomBase64url(32),ciphertext:randomBase64url(48),expiresAt:now+3600,signature:''};
 offer.signature=await sign(owner.signing.privateKey,await recoveryOfferBytes(offer));
 const first=ok(await send(await signed(owner,path+operation+'/key-offers',{offer}),settings));
 const retry=ok(await send(await signed(owner,path+operation+'/key-offers',{offer}),settings));expect(retry).toEqual(first);
 const changed={...offer,ciphertext:randomBase64url(48)};changed.signature=await sign(owner.signing.privateKey,await recoveryOfferBytes(changed));
 expect((await send(await signed(owner,path+operation+'/key-offers',{offer:changed}),settings)).data.error.code).toBe('idempotency_conflict');
 const listChallenge=await challenge('status'),payload=groupFields(['0']);
 const list=await (await groupRecoveryCatalogAPI(req(`operations/${operation}/key-offers`,{challengeId:listChallenge.id,windowId:w.windowId,afterEpoch:0,
  rootSignature:await sign(owner.identity.privateKey,recoveryRecipientAction(listChallenge,w.windowId,'offers',payload))}),settings)).json() as {items:{offer:RecoveryKeyOffer}[]};
 expect(list.items).toHaveLength(1);expect(list.items[0]!.offer).toEqual(offer);
 const receiptSignature=await sign(device.privateKey,await recoveryReceiptBytes(offer));
 const authorization=await sign(owner.identity.privateKey,groupDeviceAuthorization(w.windowId,owner.id,{id:pending.deviceId,
  signingPublicKey:intent.signingPublicKey,hpkePublicKey:intent.hpkePublicKey,personAuthorization:''}));
 const newDevice={id:pending.deviceId,signingPublicKey:intent.signingPublicKey,hpkePublicKey:intent.hpkePublicKey,personAuthorization:authorization};
 const nextRoster={...w.roster,revision:2,keyEpoch:2,previousHash:w.hash,members:[{...w.roster.members[0]!,devices:[...w.roster.members[0]!.devices,newDevice]}]};
 const {hash:nextHash,...material}=await packet(owner,nextRoster);
 const completion={operationId:operation,expectedRevision:1,...material};
 const beforeReceipt=await send(await signed(owner,path+operation+'/complete',completion),settings);
 expect(beforeReceipt.data.error.code).toBe('recovery_receipt_required');
 const rc=await challenge('status'),rp=groupFields([offer.offerId,'1',base64urlDecode(receiptSignature,64),base64urlDecode(authorization,64)]);
 const result=await (await groupRecoveryCatalogAPI(req(`operations/${operation}/key-receipts`,{challengeId:rc.id,windowId:w.windowId,
  offerId:offer.offerId,keyEpoch:1,receiptSignature,personAuthorization:authorization,
  rootSignature:await sign(owner.identity.privateKey,recoveryRecipientAction(rc,w.windowId,'receipt',rp))}),settings)).json();
 expect(result).toMatchObject({state:'receivedWaitingForOwner',canOpen:false,canSend:false});
 expect(await db.prepare('SELECT revision FROM group_windows WHERE space_id=?').bind(w.windowId).first()).toEqual({revision:1});
 expect(await db.prepare('SELECT 1 FROM group_person_devices WHERE id=?').bind(pending.deviceId).first()).toBeNull();
 const completed=ok(await send(await signed(owner,path+operation+'/complete',completion),settings));
 expect(completed).toMatchObject({state:'recoveryCommitted',revision:2,rosterHash:nextHash});
 expect(ok(await send(await signed(owner,path+operation+'/complete',completion),settings))).toEqual(completed);
 expect(await db.prepare('SELECT 1 FROM group_recovery_pending WHERE operation_id=?').bind(operation).first()).toBeNull();
 expect(await db.prepare('SELECT state FROM group_person_devices WHERE id=?').bind(pending.deviceId).first()).toEqual({state:'active'});
 const doneChallenge=await challenge('status');
 const done=await (await groupRecoveryCatalogAPI(req(`operations/${operation}/key-offers`,{challengeId:doneChallenge.id,windowId:w.windowId,afterEpoch:0,
  rootSignature:await sign(owner.identity.privateKey,recoveryRecipientAction(doneChallenge,w.windowId,'offers',groupFields(['0'])))}),settings)).json();
 expect(done).toMatchObject({state:'recoveryCommitted',deviceId:pending.deviceId,rosterHash:nextHash,canOpen:false,canSend:false});
 await db.prepare("UPDATE group_windows SET mode='closed' WHERE space_id=?").bind(w.windowId).run();
 expect(await db.prepare('SELECT 1 FROM group_recovery_key_offers WHERE operation_id=?').bind(operation).first()).toBeNull();
});
