import {expect,it} from 'vitest';
import {create,key,packet,sign} from './group-fixture';
import {plusOwner} from './group-billing-fixture';
import {randomBase64url,verifyEd25519} from '../src/encoding';
import {verifyGroupRoster} from '../src/group-protocol';
import {pendingAuthentication} from '../src/group-recovery-pending';
import {participationBytes,verifyParticipation,type ParticipationBoundary} from '../src/group-recovery-participation';
import {verifyRecoveryRecipient,verifyRecoveryOffer,recoveryOfferBytes,recoveryReceiptBytes,type RecoveryKeyOffer} from '../src/group-recovery-key-protocol';
import type {RecoveryChallenge} from '../src/group-recovery-catalog';
it('requires both recipient proofs, pinned participation, current sender and an exact signed envelope',async()=>{
 const owner=await plusOwner(),w=await create(owner),device=await key(),now=Math.floor(Date.now()/1000);
 const head=await verifyGroupRoster((await packet(owner,w.roster)).packet,{windowId:w.windowId,ownerPersonId:owner.id,ownerIdentityPublicKey:owner.identity.publicKey});
 const c:RecoveryChallenge={id:crypto.randomUUID(),person_id:owner.id,identity_public_key:owner.identity.publicKey,
  operation_id:crypto.randomUUID(),purpose:'register',environment:'staging',nonce:randomBase64url(32),issued_at:now-600,expires_at:now-300,consumed_at:now-500};
 const intent={windowId:w.windowId,signingPublicKey:device.publicKey,hpkePublicKey:randomBase64url(32),model:'Synthetic'};
 const proof={challenge:c,intent,rootSignature:await sign(owner.identity.privateKey,pendingAuthentication(c,w.windowId,intent)),
  deviceSignature:await sign(device.privateKey,pendingAuthentication(c,w.windowId,intent,'device'))};
 const recipient=await verifyRecoveryRecipient(proof,head,'staging');expect(recipient).not.toBeNull();
 // Registration intent survives its one-use challenge lifetime, but cannot change.
 expect(await verifyRecoveryRecipient({...proof,intent:{...intent,hpkePublicKey:randomBase64url(32)}},head,'staging')).toBeNull();
 expect(await verifyRecoveryRecipient({...proof,deviceSignature:randomBase64url(64)},head,'staging')).toBeNull();
 expect(await verifyRecoveryRecipient(proof,head,'production')).toBeNull();
 const unsigned:Omit<ParticipationBoundary,'signature'>={environment:'staging',windowId:w.windowId,personId:owner.id,
  participantId:w.roster.members[0]!.participantId,admissionRevision:1,rosterHash:head.hash,signerDeviceId:owner.deviceId};
 const boundary=await verifyParticipation({...unsigned,signature:await sign(owner.signing.privateKey,participationBytes(unsigned))},head,'staging',owner.id);
 const offer:RecoveryKeyOffer={environment:'staging',windowId:w.windowId,operationId:c.operation_id,offerId:crypto.randomUUID(),keyEpoch:1,
  epochRosterHash:head.hash,currentRosterHash:head.hash,recipientDeviceId:recipient!.deviceId,senderDeviceId:owner.deviceId,
  encapsulatedKey:randomBase64url(32),ciphertext:randomBase64url(48),expiresAt:now+86400,signature:''};
 offer.signature=await sign(owner.signing.privateKey,await recoveryOfferBytes(offer));
 expect(await verifyRecoveryOffer(offer,head,head,recipient!,boundary!,now)).toEqual(offer);
 for(const change of [{ciphertext:randomBase64url(48)},{operationId:crypto.randomUUID()},{offerId:crypto.randomUUID()},
  {recipientDeviceId:owner.deviceId},{currentRosterHash:randomBase64url(32)},{keyEpoch:2},{expiresAt:now+86401}])
  expect(await verifyRecoveryOffer({...offer,...change},head,head,recipient!,boundary!,now)).toBeNull();
 expect(await verifyRecoveryOffer(offer,head,head,recipient!,boundary!,now+86400)).toBeNull();
 const receipt=await sign(device.privateKey,await recoveryReceiptBytes(offer));
 expect(await verifyEd25519(device.publicKey,receipt,await recoveryReceiptBytes(offer))).toBe(true);
 expect(await verifyEd25519(device.publicKey,receipt,await recoveryReceiptBytes({...offer,ciphertext:randomBase64url(48)}))).toBe(false);
});
