import {expect,it} from 'vitest';
import {groupRecoveryCatalogAPI,type RecoveryChallenge} from '../src/group-recovery-catalog';
import {recoveryDeviceRemovalTranscript} from '../src/group-recovery-devices';
import {create,db,person,sign,testEnv} from './group-fixture';
import {plusOwner} from './group-billing-fixture';
const settings={...testEnv,ENVIRONMENT:'staging',GROUP_RECOVERY_CATALOG_ENABLED:'YES',MEMBER_RATE_LIMITER:{limit:async()=>({success:true})}};
const req=(path:string,body:unknown)=>new Request('https://test.invalid/v3/group-recovery/'+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
async function removal(p:Awaited<ReturnType<typeof person>>,device:string,operation=crypto.randomUUID()){
 const response=await groupRecoveryCatalogAPI(req('challenges',{identityPublicKey:p.identity.publicKey,operationId:operation,purpose:'register'}),settings);
 const {challenge}=await response.json() as {challenge:RecoveryChallenge};
 const body={challengeId:challenge.id,deviceId:device,rootSignature:await sign(p.identity.privateKey,recoveryDeviceRemovalTranscript(challenge,device))};
 return {body,call:()=>groupRecoveryCatalogAPI(req('devices/remove',body),settings)};
}
it('root removes only its selected device, prevents re-registration, leaves membership/photos and frees the slot',async()=>{
 const p=await plusOwner(),w=await create(p),other=await person(p.identity);
 const members=(await db.prepare('SELECT * FROM group_members WHERE space_id=?').bind(w.windowId).all()).results;
 const operation=crypto.randomUUID(),r=await removal(p,p.deviceId,operation);
 expect(await (await r.call()).json()).toMatchObject({state:'revoked',deviceId:p.deviceId});
 await expect(r.call()).rejects.toMatchObject({status:401});
 expect(await (await (await removal(p,p.deviceId,operation)).call()).json()).toMatchObject({state:'revoked'});
 expect((await db.prepare('SELECT * FROM group_members WHERE space_id=?').bind(w.windowId).all()).results).toEqual(members);
 expect(await db.prepare('SELECT mode,revision,rotation_required FROM group_windows WHERE space_id=?').bind(w.windowId).first()).toMatchObject({mode:'active',revision:1,rotation_required:1});
 expect(await db.prepare('SELECT state FROM group_person_devices WHERE id=?').bind(other.deviceId).first()).toMatchObject({state:'active'});
 await person(p.identity);await person(p.identity);
});
it('cannot remove another person or reinterpret a signature as another target',async()=>{
 const a=await person(),b=await person(),r=await removal(a,b.deviceId);
 await expect(r.call()).rejects.toMatchObject({status:404});
 const s=await removal(a,a.deviceId);s.body.deviceId=b.deviceId;await expect(s.call()).rejects.toMatchObject({status:401});
});
