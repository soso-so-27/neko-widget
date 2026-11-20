import {expect,it} from 'vitest';
import localWorker from '../scripts/e2e-worker';
import {authenticateGroupRequest} from '../src/group-auth';
import {base64urlDecode,randomBase64url,sha256Base64url} from '../src/encoding';
import {acceptIdentityFence} from '../src/group-identity-fence';
import {groupFields} from '../src/group-protocol';
import {groupRecoveryCatalogAPI,type RecoveryChallenge} from '../src/group-recovery-catalog';
import {recoveryDeviceRemovalTranscript} from '../src/group-recovery-devices';
import {create,db,ok,person,post,send,sign,signed,testEnv} from './group-fixture';
import {plusOwner} from './group-billing-fixture';
const settings={...testEnv,ENVIRONMENT:'staging',GROUP_RECOVERY_CATALOG_ENABLED:'YES',MEMBER_RATE_LIMITER:{limit:async()=>({success:true})}};
const req=(path:string,body:unknown)=>new Request('https://test.invalid/v3/group-recovery/'+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
async function removal(p:Awaited<ReturnType<typeof person>>,device:string,operation=crypto.randomUUID()){
 const response=await groupRecoveryCatalogAPI(req('challenges',{identityPublicKey:p.identity.publicKey,operationId:operation,purpose:'register'}),settings);
 const {challenge}=await response.json() as {challenge:RecoveryChallenge};
 const body={challengeId:challenge.id,deviceId:device,rootSignature:await sign(p.identity.privateKey,recoveryDeviceRemovalTranscript(challenge,device))};
 return {body,call:()=>groupRecoveryCatalogAPI(req('devices/remove',body),settings)};
}
it('returns an authentication failure when simultaneous requests consume the same challenge',async()=>{
 const p=await person(),r=await removal(p,p.deviceId);
 const results=await Promise.allSettled([r.call(),r.call()]);
 expect(results.filter(result=>result.status==='fulfilled')).toHaveLength(1);
 expect(results.find(result=>result.status==='rejected')).toMatchObject({
  reason:{status:401,code:'recovery_authentication_failed'},
 });
});
it('root removes only its selected device, prevents re-registration, leaves membership/photos and frees the slot',async()=>{
 const p=await plusOwner(),w=await create(p),other=await person(p.identity);
 const members=(await db.prepare('SELECT * FROM group_members WHERE space_id=?').bind(w.windowId).all()).results;
 const operation=crypto.randomUUID(),r=await removal(p,p.deviceId,operation);
 expect(await (await r.call()).json()).toMatchObject({state:'revoked',deviceId:p.deviceId});
 await expect(r.call()).rejects.toMatchObject({status:401});
 expect(await (await (await removal(p,p.deviceId,operation)).call()).json()).toMatchObject({state:'revoked'});
 const repeatOperation=crypto.randomUUID();await (await removal(p,p.deviceId,repeatOperation)).call();
 await expect((await removal(p,other.deviceId,repeatOperation)).call()).rejects.toMatchObject({code:'idempotency_conflict'});
 expect((await db.prepare('SELECT * FROM group_members WHERE space_id=?').bind(w.windowId).all()).results).toEqual(members);
 expect(await db.prepare('SELECT mode,revision,rotation_required FROM group_windows WHERE space_id=?').bind(w.windowId).first()).toMatchObject({mode:'active',revision:1,rotation_required:1});
 expect(await db.prepare('SELECT state FROM group_person_devices WHERE id=?').bind(other.deviceId).first()).toMatchObject({state:'active'});
 const replacement=await person(p.identity);
 expect(replacement.id).toBe(p.id);
 expect(replacement.deviceId).not.toBe(p.deviceId);
 const unrelated=await person();
 expect(unrelated.id).not.toBe(p.id);
 expect(ok(await send(await signed(unrelated,'/v3/group-windows/list',{after:null,limit:20}))).items).toEqual([]);
 expect(await post('/v3/group-identities',p.registration)).toMatchObject({status:401,data:{error:{code:'invalid_authentication'}}});
 await person(p.identity);
 await person(p.identity,409);
});

const familyPath='/v3/family-notebooks/me';
const groupPath='/v3/group-windows/list';
const plain401={status:401,data:{error:{code:'invalid_authentication',message:'Group authentication failed.'}}};
const removed401={...plain401,data:{error:{...plain401.data.error,reason:'device_revoked'}}};

it('reports a root-authorized removal on both routers in the two-device local Worker, before any shared data access',async()=>{
 const a=await person(),b=await person(a.identity);
 const local={...testEnv,E2E_TOKEN:'local-fixture',GROUP_RECOVERY_CATALOG_ENABLED:'YES',
  FAMILY_NOTEBOOK_API_RUNTIME_ENABLED:'YES',FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED:'YES'};
 await db.prepare('UPDATE family_notebook_runtime_gate SET enabled=1,generation=generation+1 WHERE singleton=1').run();
 const recovery=(path:string,body:unknown)=>localWorker.fetch(new Request(`http://127.0.0.1/v3/group-recovery/${path}`,{
  method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body),
 }),local);
 const issued=await recovery('challenges',{identityPublicKey:a.identity.publicKey,operationId:crypto.randomUUID(),purpose:'register'});
 expect(issued.status).toBe(201);
 const {challenge}=await issued.json() as {challenge:RecoveryChallenge};
 const removed=await recovery('devices/remove',{challengeId:challenge.id,deviceId:b.deviceId,
  rootSignature:await sign(a.identity.privateKey,recoveryDeviceRemovalTranscript(challenge,b.deviceId))});
 expect(removed.status).toBe(200);

 const queries:string[]=[];
 const traced=new Proxy(db,{get(target,name){
  if(name==='prepare')return (sql:string)=>{queries.push(sql);return target.prepare(sql);};
  const value=Reflect.get(target,name);
  return typeof value==='function'?value.bind(target):value;
 }});
 for(const [path,body] of [[groupPath,{after:null,limit:20}],[familyPath,undefined]] as const){
  const request=new Request(`http://127.0.0.1${path}`,await signed(b,path,body));
  const response=await localWorker.fetch(request,{...local,DB:traced});
  expect({status:response.status,data:await response.json()}).toEqual(removed401);
  expect(response.headers.get('cache-control')).toBe('no-store, max-age=0');
  const active=await localWorker.fetch(new Request(`http://127.0.0.1${path}`,await signed(a,path,body)),local);
  expect(active.status).toBe(200);
 }
 const tableNames=queries.flatMap(sql=>Array.from(sql.matchAll(/\b(?:FROM|JOIN|INTO)\s+(\w+)/gi),match=>match[1]));
 expect(new Set(tableNames)).toEqual(new Set([
  'group_people','group_person_devices','group_request_nonces','group_recovery_device_removals',
  'sqlite_master','group_identity_deletion_checkpoint','group_identity_deletion_acceptance','family_notebook_runtime_gate','personal_staging_runtime_gate',
 ]));
 expect(queries.filter(sql=>!sql.trimStart().startsWith('SELECT')).every(sql=>
  /^(DELETE FROM|INSERT INTO) group_request_nonces\b/.test(sql))).toBe(true);
});

it('keeps the removal reason private and claims it at most once for a valid signed request',async()=>{
 const a=await person(),b=await person(a.identity);
 const body={after:null,limit:20};
 const usedNonce=randomBase64url(16);
 const nonce=randomBase64url(16);
 expect((await send(await signed(b,groupPath,body,usedNonce))).status).toBe(200);
 await (await removal(a,b.deviceId)).call();
 expect(await send(await signed(b,groupPath,body,usedNonce))).toEqual(plain401);
 expect(await send(await signed({...a,deviceId:b.deviceId},groupPath,body))).toEqual(plain401);
 expect(await send(await signed({...a,deviceId:randomBase64url(32)},groupPath,body))).toEqual(plain401);

 const stale=await signed(b,groupPath,body);
 const timestamp=String(Math.floor(Date.now()/1000)-301);
 const staleNonce=stale.headers.get('neko-nonce')!;
 const bodyHash=base64urlDecode(await sha256Base64url(new TextEncoder().encode(JSON.stringify(body))),32);
 stale.headers.set('neko-timestamp',timestamp);
 stale.headers.set('neko-signature',await sign(b.signing.privateKey,
  groupFields(['NW3.REQUEST','3',b.deviceId,timestamp,staleNonce,'POST',groupPath,bodyHash])));
 expect(await send(stale)).toEqual(plain401);

 const requests=await Promise.all([signed(b,groupPath,body,nonce),signed(b,groupPath,body,nonce)]);
 const [first,second]=await Promise.all(requests.map(request=>send(request)));
 expect([first,second]).toContainEqual(removed401);
 expect([first,second]).toContainEqual(plain401);
 expect(await send(await signed(b,groupPath,body,nonce))).toEqual(plain401);

 // The report-only grant remains scoped even after the same global removal.
 const window=await create(await plusOwner());
 await db.prepare('INSERT INTO group_report_access VALUES (?,?,unixepoch()+60)').bind(window.windowId,b.deviceId).run();
 const reportPath=`/v3/group-windows/${window.windowId}/reports`;
 await expect(authenticateGroupRequest(await signed(b,reportPath),testEnv,0,window.windowId)).resolves.toMatchObject({actor:{deviceId:b.deviceId}});
 await expect(authenticateGroupRequest(await signed(b,reportPath),testEnv,0,randomBase64url(16))).rejects.toMatchObject({code:'invalid_authentication',details:undefined});

 const store=testEnv.MEDIA!;
 await store.put('group-identity-deletions/v1/control',JSON.stringify({sequence:0,requestId:''}),{onlyIf:{etagDoesNotMatch:'*'}});
 await acceptIdentityFence(store,a.id,crypto.randomUUID(),randomBase64url(32),randomBase64url(32),Math.floor(Date.now()/1000));
 expect(await send(await signed(b,groupPath,body))).toEqual(plain401);
 await db.prepare("UPDATE group_people SET state='revoked' WHERE id=?").bind(a.id).run();
 expect(await send(await signed(b,groupPath,body))).toEqual(plain401);
});
it('cannot remove another person or reinterpret a signature as another target',async()=>{
 const a=await person(),b=await person(),r=await removal(a,b.deviceId);
 await expect(r.call()).rejects.toMatchObject({status:404});
 const s=await removal(a,a.deviceId);s.body.deviceId=b.deviceId;await expect(s.call()).rejects.toMatchObject({status:401});
});
