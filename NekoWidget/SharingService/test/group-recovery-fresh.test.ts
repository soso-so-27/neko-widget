import {expect,it} from 'vitest';
import {groupRecoveryCatalogAPI,type RecoveryChallenge} from '../src/group-recovery-catalog';
import {pendingAuthentication,type PendingIntent} from '../src/group-recovery-pending';
import {freshConsentTranscript,freshMaterialHash} from '../src/group-recovery-fresh';
import {groupRecoverySignatureBytes,type GroupRecoveryClaim} from '../src/group-recovery-proof';
import {anchorReceiptTranscript} from '../src/group-anchor-receipts';
import {groupDeviceKeyHash} from '../src/group-identities';
import {create,db,key,member,packet,person,sign,signed,send,testEnv} from './group-fixture';
import {plusOwner} from './group-billing-fixture';
import {randomBase64url} from '../src/encoding';
const settings={...testEnv,ENVIRONMENT:'staging',GROUP_RECOVERY_CATALOG_ENABLED:'YES',MEMBER_RATE_LIMITER:{limit:async()=>({success:true})}};
const req=(path:string,body:unknown)=>new Request('https://test.invalid/v3/group-recovery/'+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
async function fixture(){
 const p=await plusOwner(),w=await create(p),signing=await key(),hpke=randomBase64url(32),deviceId=await groupDeviceKeyHash(signing.publicKey,hpke),op=crypto.randomUUID();
 const candidate={...p,signing,hpke,deviceId};
 expect((await send(await signed(p,`/v3/group-windows/${w.windowId}/anchor-receipt`,{environment:'staging',personId:p.id,ownerPersonId:p.id,ownerPublicKey:p.identity.publicKey,
 rootSignature:await sign(p.identity.privateKey,anchorReceiptTranscript('staging',p.id,w.windowId,p.id,p.identity.publicKey))}),settings)).status).toBe(200);
 async function challenge(){const r=await groupRecoveryCatalogAPI(req('challenges',{identityPublicKey:p.identity.publicKey,operationId:op,purpose:'register'}),settings);return (await r.json() as {challenge:RecoveryChallenge}).challenge;}
 const c=await challenge(),intent:PendingIntent={windowId:w.windowId,signingPublicKey:signing.publicKey,hpkePublicKey:hpke,model:'Synthetic'};
 await groupRecoveryCatalogAPI(req(`operations/${op}`,{challengeId:c.id,...intent,rootSignature:await sign(p.identity.privateKey,pendingAuthentication(c,w.windowId,intent)),deviceSignature:await sign(signing.privateKey,pendingAuthentication(c,w.windowId,intent,'device'))}),settings);
 const m=await member(candidate,w.windowId,'owner',w.roster.members[0]!.participantId);
 const material=await packet(candidate,{...w.roster,revision:2,keyEpoch:2,previousHash:w.hash,members:[m]});
 const {hash,...wire}=material;
 async function prepare(){const c=await challenge(),claim:GroupRecoveryClaim={version:1,environment:'staging',windowId:w.windowId,personId:p.id,participantId:m.participantId,
 recoveryGeneration:1,previousRevision:1,previousHash:w.hash,nextHash:hash,newDevice:m.devices[0]!,replacedDeviceIds:w.roster.members[0]!.devices.map(d=>d.id),
 operationId:op,challenge:c.nonce,issuedAt:c.issued_at,expiresAt:c.expires_at};
 const proof={claim,rootSignature:await sign(p.identity.privateKey,groupRecoverySignatureBytes(claim,'root')),deviceSignature:await sign(signing.privateKey,groupRecoverySignatureBytes(claim,'device'))};
 const body={challengeId:c.id,...wire,proof,consentSignature:await sign(p.identity.privateKey,freshConsentTranscript(c,await freshMaterialHash(wire)))};
 return {body,call:()=>groupRecoveryCatalogAPI(req(`operations/${op}/fresh`,body),settings)};}
 return {p,w,op,deviceId,prepare};
}
it('explicit solo recovery atomically replaces the epoch, retries without advancing again and preserves old roster/key history',async()=>{
 const f=await fixture();await db.prepare("UPDATE group_window_devices SET state='revoked',removed_revision=1 WHERE space_id=?").bind(f.w.windowId).run();
 const first=await f.prepare();expect(await (await first.call()).json()).toMatchObject({state:'freshGenerationCommitted',revision:2,deviceId:f.deviceId});
 expect(await (await (await f.prepare()).call()).json()).toMatchObject({revision:2});
 expect((await db.prepare('SELECT revision FROM group_rosters WHERE space_id=? ORDER BY revision').bind(f.w.windowId).all()).results).toEqual([{revision:1},{revision:2}]);
 expect(await db.prepare('SELECT 1 FROM group_key_envelopes WHERE space_id=? AND epoch=1').bind(f.w.windowId).first()).not.toBeNull();
 expect(await db.prepare('SELECT 1 FROM group_recovery_pending WHERE operation_id=?').bind(f.op).first()).toBeNull();
 await db.prepare("UPDATE group_people SET state='revoked' WHERE id=?").bind(f.p.id).run();
 expect(await db.prepare('SELECT 1 FROM group_recovery_fresh_generations WHERE person_id=?').bind(f.p.id).first()).toBeNull();
 await expect((await f.prepare()).call()).rejects.toThrow();
});
it('effective old device or newly appearing family member prevents issuance and rolls back the challenge and all new rows',async()=>{
 const f=await fixture(),r=await f.prepare();await expect(r.call()).rejects.toThrow('group_recovery_fresh_state_changed');
 expect(await db.prepare('SELECT revision FROM group_windows WHERE space_id=?').bind(f.w.windowId).first()).toEqual({revision:1});
 expect(await db.prepare('SELECT 1 FROM group_person_devices WHERE id=?').bind(f.deviceId).first()).toBeNull();
 await db.prepare("UPDATE group_window_devices SET state='revoked',removed_revision=1 WHERE space_id=?").bind(f.w.windowId).run();
 const other=await person();await db.prepare("INSERT INTO group_members VALUES (?,?,?,'member','active',1,NULL,'synthetic')").bind(crypto.randomUUID(),f.w.windowId,other.id).run();
 await expect((await f.prepare()).call()).rejects.toThrow('group_recovery_fresh_state_changed');
});
it('changing encrypted names after consent or using a wrong root cannot change the epoch',async()=>{
 const f=await fixture();await db.prepare("UPDATE group_window_devices SET state='revoked',removed_revision=1 WHERE space_id=?").bind(f.w.windowId).run();
 const r=await f.prepare();r.body.encryptedName=randomBase64url(48);await expect(r.call()).rejects.toMatchObject({status:409});
 expect(await db.prepare('SELECT revision FROM group_windows WHERE space_id=?').bind(f.w.windowId).first()).toEqual({revision:1});
});
