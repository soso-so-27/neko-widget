import {env} from 'cloudflare:workers';
import {beforeEach,expect,it} from 'vitest';
import {randomToken,sha256} from '../src/contracts';
import {identityIndexKey,indexedOwnerIdentity} from '../src/identity-index';
import {envelopeKeyCustody} from '../src/key-custody';
import {OwnerArchiveRecovery} from '../src/owner-archive-recovery';
import {OwnerQuarantineRestore} from '../src/owner-quarantine-restore';
import {OwnerRecoveryCopy,type OwnerRecoveryImage} from '../src/owner-recovery-copy';
import {RecordRecoveryCopy} from '../src/record-recovery-copy';
import type {S3RecoveryCopy,RecoveryObject,RecoveryVersionCursor} from '../src/s3-recovery-copy';
import type {S3PurgeIntentStore} from '../src/s3-purge-intent';
import {ownerD1DeleteOrder} from '../src/owner-d1-residue';
import {syntheticKeyAuthority} from './key-fixture';
import {ImmutableRecordTree} from '../src/immutable-record-tree';
import {openOwnerSnapshot} from '../src/owner-snapshot-codec';
const owner='00000000-0000-4000-8000-000000000001';
const {DB:db,ARCHIVE:bucket}=env as unknown as {DB:D1Database;ARCHIVE:R2Bucket};
beforeEach(async()=>{
 await db.prepare('UPDATE pa_recovery_write_policy SET delete_intent_required=0,owner_snapshot_required=0 WHERE singleton=1').run();
 for(const table of ownerD1DeleteOrder)await db.prepare(`DELETE FROM ${table}`).run();
 const page=await bucket.list({prefix:`personal/${owner}/`});for(const row of page.objects)await bucket.delete(row.key);
});
async function fixture(extraVersions=0){
 const keys=envelopeKeyCustody({enabled:true,wrapper:(await syntheticKeyAuthority()).bridge()}),secret=randomToken();
 const objects=new Map<string,Uint8Array>(),refs:RecoveryObject[]=[],omitted=new Set<string>();
 const io={gets:0,heads:0,lists:0,maxList:0,readBytes:0,dbStatements:0,maxBatch:0,maxBindings:0},state={fenced:true,offline:true,purged:false,interrupt:false,photoInterrupt:false,extraVersions};
 const s3={
  async putVersioned(key:string,bytes:Uint8Array):Promise<RecoveryObject>{const ref={key,versionId:crypto.randomUUID(),sha256:await sha256(bytes),bytes:bytes.length};objects.set(key,bytes.slice());refs.push(ref);return ref;},
  async getVerified(ref:RecoveryObject){io.gets++;io.readBytes+=ref.bytes;const bytes=objects.get(ref.key);if(!bytes || await sha256(bytes)!==ref.sha256 || ref.bytes!==bytes.length)throw Error('bad synthetic version');return bytes.slice();},
  async referenceForListedVersion(row:{key:string;versionId:string;bytes?:number}){io.heads++;const ref=refs.find(r=>r.key===row.key&&r.versionId===row.versionId);if(!ref || ref.bytes!==row.bytes)throw Error('missing synthetic ref');return ref;},
  async listOwnerVersionsPage(id:string,cursor?:RecoveryVersionCursor){
   if(id!==owner)throw Error('wrong owner');if(state.interrupt){state.interrupt=false;throw Error('synthetic listing interrupted');}
   io.lists++;const actual=refs.filter(r=>!omitted.has(r.key));const start=Number(cursor?.keyMarker??0),end=Math.min(start+1000,actual.length+state.extraVersions);
   const versions=Array.from({length:end-start},(_,offset)=>{const at=start+offset,r=actual[at];return r?{key:r.key,versionId:r.versionId,bytes:r.bytes,deleteMarker:false}
    :{key:`recovery/v1/${owner}/unused/${(at-actual.length).toString().padStart(10,'0')}`,versionId:'synthetic-unused',bytes:1,deleteMarker:false};});
   io.maxList=Math.max(io.maxList,versions.length);return {versions,nextCursor:end<actual.length+state.extraVersions?{keyMarker:String(end)}:null};
  },
 } as S3RecoveryCopy;
 const owners=new OwnerRecoveryCopy(keys,s3,secret,{pagedWrites:true,compressWrites:true}),records=new RecordRecoveryCopy(keys,s3);
 const id=crypto.randomUUID(),deletedId=crypto.randomUUID(),operation=crypto.randomUUID(),photoKey=`personal/${owner}/${id}/${crypto.randomUUID()}`;
 const photo=new Uint8Array([255,216,255,217]),cipher=await keys.seal(photo,{ownerId:owner,purpose:'record',recordId:`${id}/photo`});
 const document={formatVersion:1,text:'synthetic restore',capturedAt:null,writtenAt:null,updatedAt:null,catNames:[],photoFile:'photo.jpg'};
 const make=async(recordId:string,revision:number,deleted=false)=>{
  const livePhoto=recordId===id&&!deleted;
  const metadata=deleted?null:await keys.seal(new TextEncoder().encode(JSON.stringify({version:1,ownerId:owner,recordId,revision,
   document:{...document,photoFile:livePhoto?'photo.jpg':null},photoSHA256:livePhoto?await sha256(photo):null,photoBytes:livePhoto?photo.length:0})),
   {ownerId:owner,purpose:'record',recordId:`${recordId}/document`});
  return records.copy({ownerId:owner,recordId,revision,initialFingerprint:'a'.repeat(64),initialOperation:operation,metadata,
   photoKey:livePhoto?photoKey:null,photoBytes:livePhoto?photo.length:0,quotaBytes:deleted?0:metadata!.length+(livePhoto?cipher.length:0),
   deleted,photoCiphertext:livePhoto?cipher:null});
 };
 const first=await make(id,1);await records.commit(owner,id,1,first);
 const second=await make(id,2),marker=await records.commit(owner,id,2,second);
 const old=await make(deletedId,1);await records.commit(owner,deletedId,1,old);
 const tombstone=await make(deletedId,2,true);await records.prepareDelete(owner,deletedId,1,tombstone);
 const deletedMarker=await records.commit(owner,deletedId,2,tombstone);
 const issuer='https://appleid.apple.com',subject='synthetic-offline-recovery';
 const credential=await keys.seal(new TextEncoder().encode(JSON.stringify({issuer,subject,refreshToken:randomToken()})),{ownerId:owner,purpose:'identity'});
 const image:OwnerRecoveryImage={ownerId:owner,generation:1,identityKey:await indexedOwnerIdentity(await identityIndexKey(secret),issuer,subject),epoch:0,disabled:false,
  purgeFenceId:null,createdAt:100,credential:{ownerEpoch:0,sealedCredentials:credential,updatedAt:100},contact:null,billing:null,retention:null,inventoryGeneration:4,
  records:[{recordId:id,revision:2,deleted:false,marker},{recordId:deletedId,revision:2,deleted:true,marker:deletedMarker}].sort((a,b)=>a.recordId.localeCompare(b.recordId))};
 await owners.copy(image);
 const purge={listOwnerVersionsPage:async()=>({versions:[],nextCursor:null})} as unknown as S3PurgeIntentStore;
 const measuredDB=new Proxy(db,{get(target,key){
  if(key==='prepare')return(sql:string)=>{io.dbStatements++;const stmt=target.prepare(sql);return new Proxy(stmt,{get(s,method){
   if(method==='bind')return(...args:unknown[])=>{io.maxBindings=Math.max(io.maxBindings,args.length);return s.bind(...args);};
   const value=Reflect.get(s,method);return typeof value==='function'?value.bind(s):value;
  }});};
  if(key==='batch')return(statements:D1PreparedStatement[])=>{io.maxBatch=Math.max(io.maxBatch,statements.length);return target.batch(statements);};
  const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
 }});
 const interruptedBucket=new Proxy(bucket,{get(target,key){if(key==='put')return async(...args:Parameters<R2Bucket['put']>)=>{
  const result=await target.put(...args);if(state.photoInterrupt){state.photoInterrupt=false;throw Error('synthetic lost photo response');}return result;
 };const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;}});
 const restore=new OwnerQuarantineRestore(new OwnerArchiveRecovery(s3,owners,records),records,measuredDB,interruptedBucket,purge,
  {async assertNotRequested(){if(state.purged)throw Error('independent deletion intent');}});
 const safety={async assertSourceFenced(){if(!state.fenced)throw Error('source not fenced');},async assertTargetOffline(){if(!state.offline)throw Error('target not offline');}};
 const step=()=>restore.resume(owner,1000,safety);
 return {step,restore,owners,records,image,refs,objects,omitted,io,state,id,deletedId,photoKey,cipher,keys,s3};
}
async function finish(f:Awaited<ReturnType<typeof fixture>>,maximum=1000){
 let steps=0,peakGets=0,peakHeads=0,peakLists=0,peakBytes=0,peakMs=0,peakDB=0;
 for(;;){const before={...f.io},started=performance.now(),result=await f.step();steps++;
  peakGets=Math.max(peakGets,f.io.gets-before.gets);peakHeads=Math.max(peakHeads,f.io.heads-before.heads);
  peakLists=Math.max(peakLists,f.io.lists-before.lists);peakBytes=Math.max(peakBytes,f.io.readBytes-before.readBytes);peakMs=Math.max(peakMs,performance.now()-started);peakDB=Math.max(peakDB,f.io.dbStatements-before.dbStatements);
  if(result.status!=='pending')return {result,metrics:{steps,peakGets,peakHeads,peakLists,peakBytes,peakMs,peakDB,maxList:f.io.maxList,maxBatch:f.io.maxBatch,maxBindings:f.io.maxBindings}};
  expect(steps).toBeLessThan(maximum);
  const row=await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?').bind(owner).first();if(row)expect(row).toEqual({disabled:1});
 }
}
it('resumes an interrupted offline spool and restores every revision, tombstone and photo while remaining disabled',async()=>{
 const f=await fixture();f.state.interrupt=true;await expect(f.step()).rejects.toThrow('synthetic listing interrupted');
 expect(await db.prepare('SELECT listed_count FROM pa_offline_recovery_jobs').first('listed_count')).toBe(0);
 const finished=await finish(f);expect(finished.result).toEqual({status:'staged-disabled',ownerId:owner,records:2,photos:1});
 expect(await db.prepare('SELECT count(*) n FROM pa_record_recovery_versions').first('n')).toBe(4);
 expect(await db.prepare('SELECT count(*) n FROM pa_record_commit_markers').first('n')).toBe(4);
 expect(await db.prepare('SELECT count(*) n FROM pa_record_delete_intents').first('n')).toBe(1);
 expect(await db.prepare('SELECT deleted FROM pa_records WHERE record_id=?').bind(f.deletedId).first('deleted')).toBe(1);
 expect(new Uint8Array(await (await bucket.get(f.photoKey))!.arrayBuffer())).toEqual(f.cipher);
 expect(await f.step()).toEqual(finished.result);
 expect(finished.metrics.peakGets).toBeLessThanOrEqual(30);expect(finished.metrics.maxList).toBeLessThanOrEqual(1000);
});
it('spools and rechecks more than 100000 S3 versions in bounded resumable pages',async(context)=>{
 const f=await fixture(100_001),result=await finish(f);
 expect(result.result).toMatchObject({status:'staged-disabled',records:2});
 expect(await db.prepare('SELECT listed_count FROM pa_offline_recovery_jobs').first('listed_count')).toBe(f.refs.length+100_001);
 expect(result.metrics.maxList).toBe(1000);expect(result.metrics.peakLists).toBe(1);expect(result.metrics.peakHeads).toBeLessThanOrEqual(8);
 expect(result.metrics.maxBatch).toBeLessThanOrEqual(98);expect(result.metrics.maxBindings).toBeLessThanOrEqual(100);
 await context.annotate(JSON.stringify({offlineRecoveryProbe:{versions:f.refs.length+100_001,...result.metrics}}),'measurement');
},120_000);
it('quarantines a missing committed marker and refuses source, target or independent deletion fences',async()=>{
 const f=await fixture();f.omitted.add(f.image.records[0]!.marker.key);
 f.state.fenced=false;await expect(f.step()).rejects.toThrow('source not fenced');f.state.fenced=true;
 f.state.offline=false;await expect(f.step()).rejects.toThrow('target not offline');f.state.offline=true;
 f.state.purged=true;await expect(f.step()).rejects.toThrow('independent deletion intent');f.state.purged=false;
 expect((await finish(f)).result).toEqual({status:'quarantined'});
 expect(await db.prepare('SELECT count(*) n FROM pa_sessions').first('n')).toBe(0);
});

it('retries an identical staged photo after a lost response without duplicating rows or history',async()=>{
 const f=await fixture();f.state.photoInterrupt=true;
 await expect(finish(f)).rejects.toThrow('synthetic lost photo response');
 expect(await bucket.head(f.photoKey)).not.toBeNull();
 expect((await finish(f)).result).toMatchObject({status:'staged-disabled',records:2,photos:1});
 expect(await db.prepare('SELECT count(*) n FROM pa_record_commit_markers').first('n')).toBe(4);
});

it('does not publish success after source inventory changes during staging',async()=>{
 const f=await fixture();
 for(let n=0;n<100;n++){const value=await f.step();if(value.status==='pending'&&value.phase==='relist')break;if(n===99)throw Error('phase not reached');}
 f.state.extraVersions=1;
 expect((await finish(f)).result).toEqual({status:'quarantined'});
 expect(await db.prepare('SELECT disabled FROM pa_owners WHERE owner_id=?').bind(owner).first('disabled')).toBe(1);
});

it('quarantines historical owner rollback before staging any owner or record',async()=>{
 const f=await fixture();await f.owners.copy({...f.image,generation:2,records:[f.image.records[0]!]});
 expect((await finish(f)).result).toEqual({status:'quarantined'});
 expect(await db.prepare('SELECT count(*) n FROM pa_owners').first('n')).toBe(0);
});

it('refuses a missing authenticated tree and resumes after exact bytes return without acknowledging partial state',async()=>{
 const f=await fixture(),reference=f.refs.find(r=>r.key.includes('/owner/'))!;
 const root=(await f.owners.inspectRecoveryHeader(owner,reference)).tree!,body=f.objects.get(root.object.key)!;
 f.objects.delete(root.object.key);await f.step();
 await expect(f.step()).rejects.toThrow();
 expect(await db.prepare('SELECT expected_count FROM pa_offline_recovery_jobs').first('expected_count')).toBe(0);
 expect(await db.prepare('SELECT count(*) n FROM pa_owners').first('n')).toBe(0);
 f.objects.set(root.object.key,body);
 expect((await finish(f)).result).toMatchObject({status:'staged-disabled',records:2});
});

it('CAS checkpoints let only one concurrent quantum advance without duplicate rows or lost progress',async()=>{
 const f=await fixture();await f.step();
 const attempts=await Promise.allSettled([f.step(),f.step()]);
 expect(attempts.filter(x=>x.status==='fulfilled')).toHaveLength(1);
 expect(attempts.filter(x=>x.status==='rejected')).toHaveLength(1);
 expect((await finish(f)).result).toMatchObject({status:'staged-disabled',records:2});
 expect(await db.prepare('SELECT count(*) n FROM pa_record_commit_markers').first('n')).toBe(4);
});

it('streams an actual 100001-entry owner tree into the offline expected spool without whole hydration',async(context)=>{
 const fixtureStarted=performance.now(),f=await fixture(),entries=[...f.image.records];
 for(let i=0;i<99_998;i++)entries.push({recordId:crypto.randomUUID(),revision:1,deleted:false,marker:f.image.records[0]!.marker});
 entries.sort((a,b)=>a.recordId.localeCompare(b.recordId));
 const base=await f.owners.copy({...f.image,generation:2,inventoryGeneration:100000,records:entries});
 const inspected=await f.owners.inspectRecoveryHeader(owner,base);
 const finalId='ffffffff-ffff-4fff-8fff-ffffffffffff',last={recordId:finalId,revision:1,deleted:false,marker:f.image.records[0]!.marker};
 const tree=new ImmutableRecordTree(owner,'owner-inventory-v1',f.keys,f.s3),root=await tree.update(inspected.tree!,[{key:finalId.replaceAll('-',''),value:last}]);
 const wire=JSON.parse(new TextDecoder().decode(await openOwnerSnapshot(await f.keys.open(await f.s3.getVerified(base),{ownerId:owner,purpose:'recovery'}))));
 const sealed=await f.keys.seal(new TextEncoder().encode(JSON.stringify({...wire,generation:3,inventoryGeneration:100001,recordsTree:root})),{ownerId:owner,purpose:'recovery'});
 await f.s3.putVersioned(`recovery/v1/${owner}/owner/${crypto.randomUUID()}`,sealed);
 const fixtureMs=performance.now()-fixtureStarted;
 // Exercise the new offline route, not copyCurrent's separate rebuild cursor.
 let quantum=0,peakRows=0,peakGets=0,peakDB=0,peakMs=0,lastCount=0,sawPartial=false;
 for(;;){const before={...f.io},start=performance.now(),result=await f.step();quantum++;
  peakGets=Math.max(peakGets,f.io.gets-before.gets);peakDB=Math.max(peakDB,f.io.dbStatements-before.dbStatements);peakMs=Math.max(peakMs,performance.now()-start);
  if(result.status!=='pending')throw Error('stopped before expected spool completion');
  peakRows=Math.max(peakRows,result.records-lastCount);lastCount=result.records;
  if(result.phase==='owners'&&result.records>0&&result.records<100001){sawPartial=true;expect(await db.prepare('SELECT count(*) n FROM pa_owners').first('n')).toBe(0);}
  if(result.phase==='initialize')break;expect(quantum).toBeLessThan(3000);
 }
 expect(sawPartial).toBe(true);expect(peakRows).toBeLessThanOrEqual(200);
 expect(await db.prepare('SELECT count(*) n,max(record_id) tail FROM pa_offline_recovery_expected').first()).toEqual({n:100001,tail:finalId});
 expect(await db.prepare('SELECT expected_count FROM pa_offline_recovery_jobs').first('expected_count')).toBe(root.count);
 // Synthetic placeholder markers intentionally lack each new record's history.
 // They cannot become a completed or publicly readable restore.
 expect((await finish(f)).result).toEqual({status:'quarantined'});
 await context.annotate(JSON.stringify({offlineOwnerTreeProbe:{actualEntries:100001,fixtureMs,quantum,peakRows,peakGets,peakDB,peakMs,maxBatch:f.io.maxBatch,maxBindings:f.io.maxBindings}}),'measurement');
},240_000);
