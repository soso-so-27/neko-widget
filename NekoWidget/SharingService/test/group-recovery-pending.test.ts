import { describe, expect, it } from 'vitest';
import { groupRecoveryCatalogAPI, type RecoveryChallenge } from '../src/group-recovery-catalog';
import { pendingAuthentication, type PendingIntent } from '../src/group-recovery-pending';
import { anchorReceiptTranscript } from '../src/group-anchor-receipts';
import { plusOwner } from './group-billing-fixture';
import { create, db, person, sign, signed, send, testEnv, key } from './group-fixture';
import { randomBase64url } from '../src/encoding';
const settings={...testEnv,ENVIRONMENT:'staging',GROUP_RECOVERY_CATALOG_ENABLED:'YES',MEMBER_RATE_LIMITER:{limit:async()=>({success:true})}};
const req=(path:string,body:unknown)=>new Request('https://example.test/v3/group-recovery/'+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
async function fixture(receipt=true){
 const p=await plusOwner(),w=await create(p),device=await key(),operation=crypto.randomUUID();
 if(receipt)expect((await send(await signed(p,`/v3/group-windows/${w.windowId}/anchor-receipt`,{environment:'staging',personId:p.id,ownerPersonId:p.id,ownerPublicKey:p.identity.publicKey,
 rootSignature:await sign(p.identity.privateKey,anchorReceiptTranscript('staging',p.id,w.windowId,p.id,p.identity.publicKey))}),settings)).status).toBe(200);
 const intent:PendingIntent={windowId:w.windowId,signingPublicKey:device.publicKey,hpkePublicKey:randomBase64url(32),model:'Synthetic iPhone'};
 async function prepared(register=true,op=operation,value=intent){const response=await groupRecoveryCatalogAPI(req('challenges',{identityPublicKey:p.identity.publicKey,operationId:op,purpose:register?'register':'status'}),settings);
  const {challenge:c}=await response.json() as {challenge:RecoveryChallenge};
  const body={challengeId:c.id,windowId:value.windowId,...(register?{signingPublicKey:value.signingPublicKey,hpkePublicKey:value.hpkePublicKey,model:value.model,deviceSignature:await sign(device.privateKey,pendingAuthentication(c,value.windowId,value,'device'))}:{}),rootSignature:await sign(p.identity.privateKey,pendingAuthentication(c,value.windowId,register?value:undefined))};
  const path=`operations/${op}${register?'':'/status'}`;return {c,body,call:()=>groupRecoveryCatalogAPI(req(path,body),settings)};}
 return {p,w,device,operation,intent,prepared,invoke:async(register=true,op=operation,value=intent)=>(await (await prepared(register,op,value)).call()).json() as Promise<Record<string,any>>};
}
async function current(window:string){const out=[];for(const table of ['group_windows','group_members','group_window_devices','group_rosters','group_roster_packets','group_key_envelopes','group_window_metadata'])out.push((await db.prepare(`SELECT * FROM ${table} WHERE space_id=?`).bind(window).all()).results);return out;}
describe('pending-only root recovery',()=>{
 it('registers without changing current roster, keys, members or device privileges; lost response queries the same operation',async()=>{
  const f=await fixture(),before=await current(f.w.windowId);expect((await f.invoke(false)).state).toBe('notStarted');
  const first=await f.invoke();expect(first).toMatchObject({state:'registeredWaitingForKeys',exists:true,canOpen:false,canSend:false,canRequestFreshGeneration:false,revision:1});
  expect(await f.invoke(false)).toMatchObject({state:'registeredWaitingForKeys',deviceId:first.deviceId});expect(await f.invoke()).toMatchObject({deviceId:first.deviceId});
  expect(await current(f.w.windowId)).toEqual(before);expect(await db.prepare('SELECT 1 FROM group_person_devices WHERE id=?').bind(first.deviceId).first()).toBeNull();
  expect((await db.prepare('SELECT * FROM group_recovery_pending WHERE person_id=?').bind(f.p.id).all()).results).toHaveLength(1);
 });
 it('does not invent an anchor or register when original-device proof is absent',async()=>{const f=await fixture(false);expect(await f.invoke()).toMatchObject({state:'needsOriginalDeviceOrInvitation',canOpen:false,canSend:false});expect(await db.prepare('SELECT 1 FROM group_recovery_pending WHERE person_id=?').bind(f.p.id).first()).toBeNull();});
 it('rejects changed same-operation intent and reused/forged proofs',async()=>{const f=await fixture();const r=await f.prepared();await r.call();await expect(r.call()).rejects.toMatchObject({status:401});
  await expect(f.invoke(true,f.operation,{...f.intent,model:'changed'})).rejects.toMatchObject({code:'idempotency_conflict'});
  const bad=await f.prepared();bad.body.rootSignature=randomBase64url(64);await expect(bad.call()).rejects.toMatchObject({status:401});});
 it('counts pending devices in the three-device limit, including concurrent reservations',async()=>{const f=await fixture();const calls=[];for(let n=0;n<3;n++){const k=await key();const op=crypto.randomUUID();const r=await f.prepared(true,op,{...f.intent,signingPublicKey:k.publicKey,hpkePublicKey:randomBase64url(32)});
  r.body.deviceSignature=await sign(k.privateKey,pendingAuthentication(r.c,f.w.windowId,{windowId:f.w.windowId,signingPublicKey:k.publicKey,hpkePublicKey:r.body.hpkePublicKey!,model:f.intent.model},'device'));calls.push(r.call());}
  const results=await Promise.allSettled(calls);expect(results.filter(r=>r.status==='fulfilled')).toHaveLength(2);expect((await db.prepare('SELECT * FROM group_recovery_pending WHERE person_id=?').bind(f.p.id).all()).results).toHaveLength(2);
  await expect(db.prepare("INSERT INTO group_person_devices VALUES (?,?,?,?,?,'active',?,NULL)").bind(randomBase64url(32),f.p.id,randomBase64url(32),randomBase64url(32),'synthetic',Math.floor(Date.now()/1000)).run()).rejects.toThrow('group_device_limit');
 });
 it('cleans pending requests on root revocation and denies status',async()=>{const f=await fixture();await f.invoke();await db.prepare("UPDATE group_people SET state='revoked' WHERE id=?").bind(f.p.id).run();expect(await db.prepare('SELECT 1 FROM group_recovery_pending WHERE person_id=?').bind(f.p.id).first()).toBeNull();await expect(f.invoke(false)).rejects.toMatchObject({status:401});});
 it('has no waiting expiry; distinguishes no provider without advancing generations',async()=>{const f=await fixture();await f.invoke();await db.prepare("UPDATE group_window_devices SET state='revoked',removed_revision=1 WHERE space_id=?").bind(f.w.windowId).run();
  const result=await f.invoke(false);expect(result).toMatchObject({state:'noKeyProvider',canRequestFreshGeneration:true,canOpen:false,canSend:false,revision:1});
  await db.prepare('UPDATE group_recovery_pending SET created_at=1 WHERE person_id=?').bind(f.p.id).run();expect((await f.invoke(false)).state).toBe('noKeyProvider');
  const other=await person();await db.prepare("INSERT INTO group_members VALUES (?,?,?,'member','active',1,NULL,'synthetic')").bind(crypto.randomUUID(),f.w.windowId,other.id).run();
  expect(await f.invoke(false)).toMatchObject({state:'registeredWaitingForKeys',canRequestFreshGeneration:false});
 });
 it('removes pending immediately when identity deletion is accepted',async()=>{
  const f=await fixture();await f.invoke();await db.prepare('INSERT INTO group_identity_deletion_acceptance(request_id,subject_id,nonce,request_hash,accepted_at) VALUES (?,?,?,?,?)').bind(crypto.randomUUID(),f.p.id,'synthetic','synthetic',Math.floor(Date.now()/1000)).run();
  expect(await db.prepare('SELECT 1 FROM group_recovery_pending WHERE person_id=?').bind(f.p.id).first()).toBeNull();
  await expect(f.invoke(false)).rejects.toMatchObject({status:401});
 });
 it('cleans a pending request on leaving without changing other windows',async()=>{
  const f=await fixture();await f.invoke();await db.prepare("UPDATE group_members SET role='member' WHERE space_id=?").bind(f.w.windowId).run();await db.prepare("UPDATE group_members SET state='left',left_revision=1 WHERE space_id=? AND person_id=?").bind(f.w.windowId,f.p.id).run();
  expect(await db.prepare('SELECT 1 FROM group_recovery_pending WHERE person_id=?').bind(f.p.id).first()).toBeNull();
  await expect(f.invoke(false)).rejects.toMatchObject({status:401});
 });
 it('rejects a forged new-device proof, an expired challenge, and a different-operation duplicate device',async()=>{
  const f=await fixture();const bad=await f.prepared();bad.body.deviceSignature=randomBase64url(64);await expect(bad.call()).rejects.toMatchObject({status:401});
  const expired=await f.prepared();await db.prepare('UPDATE group_recovery_challenges SET issued_at=issued_at-600,expires_at=expires_at-600 WHERE id=?').bind(expired.c.id).run();await expect(expired.call()).rejects.toMatchObject({status:401});
  await f.invoke();await expect(f.invoke(true,crypto.randomUUID())).rejects.toMatchObject({status:409,code:'device_pending'});
 });
 it('removes waiting state on closed windows and remains disabled before any DB access',async()=>{const f=await fixture();await f.invoke();await db.prepare("UPDATE group_windows SET mode='closed' WHERE space_id=?").bind(f.w.windowId).run();expect(await db.prepare('SELECT 1 FROM group_recovery_pending WHERE person_id=?').bind(f.p.id).first()).toBeNull();
  await expect(groupRecoveryCatalogAPI(req(`operations/${f.operation}`,{}),{...settings,DB:undefined,GROUP_RECOVERY_CATALOG_ENABLED:'NO'} as any)).rejects.toMatchObject({code:'recovery_disabled'});
 });
});
