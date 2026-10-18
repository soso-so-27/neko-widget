import {env} from 'cloudflare:workers';
import {expect,it} from 'vitest';
import {ArchiveStore} from '../src/storage';
import type {KeyCustody} from '../src/contracts';

const db=(env as unknown as {DB:D1Database}).DB;
async function fixture(count=0){
 const owner=crypto.randomUUID(),hash=crypto.randomUUID();
 await db.prepare('INSERT INTO pa_owners(owner_id,identity_key,created_at) VALUES(?,?,1)').bind(owner,hash).run();
 await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(owner).run();
 await db.prepare('INSERT INTO pa_sessions(session_hash,owner_id,owner_epoch,created_at,expires_at) VALUES(?,?,0,1,100000)')
  .bind(hash,owner).run();
 if(count)await db.prepare(`WITH RECURSIVE ids(n) AS(SELECT 1 UNION ALL SELECT n+1 FROM ids WHERE n<?)
  INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,metadata,quota_bytes)
  SELECT ?,lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-4000-8000-'||lower(hex(randomblob(6))),1,'f','o',X'01',123 FROM ids`).bind(count,owner).run();
 const session={ownerId:owner,sessionHash:hash,expiresAt:100000};
 const options={db,auth:{requireSession:async()=>session},now:()=>100,quotaBytes:100_000_000,maximumRecords:1_000_000,
  keys:{} as KeyCustody,bucket:{} as R2Bucket,membership:{status:async()=>'active' as const},photos:{validateJPEG:async()=>true}};
 return {owner,archive:new ArchiveStore(options),options};
}
async function counters(owner:string){return db.prepare('SELECT record_count,live_count,record_bytes,pending_ack FROM pa_owner_record_counters WHERE owner_id=?').bind(owner).first();}
async function version(owner:string,id:string,rev=1){
 await db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,revision,record_object_key,record_version_id,record_sha256,record_bytes,committed_at)
 VALUES(?,?,?,?,'v',?,1,1)`).bind(owner,id,rev,crypto.randomUUID(),'f'.repeat(64)).run();
}
async function marker(owner:string,id:string,rev=1){
 await db.prepare('INSERT INTO pa_record_commit_markers VALUES(?,?,?,?,?,?,1,1)').bind(owner,id,rev,crypto.randomUUID(),'v','f'.repeat(64)).run();
}
it('distinguishes the returned recovery row and SQLite CAS changes from D1 trigger change counts',async(context)=>{
 const f=await fixture(1),id=await db.prepare('SELECT record_id FROM pa_records WHERE owner_id=?').bind(f.owner).first<string>('record_id');
 await version(f.owner,id!);await marker(f.owner,id!);
 const results=await db.batch([
  db.prepare('UPDATE pa_records SET revision=2,deleted=1,metadata=NULL,quota_bytes=0 WHERE owner_id=? AND record_id=? AND revision=1 RETURNING revision').bind(f.owner,id),
  db.prepare(`INSERT INTO pa_record_recovery_versions(owner_id,record_id,revision,record_object_key,record_version_id,record_sha256,record_bytes,committed_at)
   SELECT ?,?,2,?,'v',?,1,1 WHERE changes()=1 RETURNING revision`).bind(f.owner,id,crypto.randomUUID(),'e'.repeat(64)),
  db.prepare('SELECT changes() AS changed'),
 ]);
 await context.annotate(JSON.stringify(results.map(x=>({results:x.results,changes:x.meta.changes}))), 'D1 changes');
 expect(results[0]!.results).toEqual([{revision:2}]);expect(results[1]!.results).toEqual([{revision:2}]);
 expect(results[2]!.results).toEqual([{changed:1}]);
});
it('matches exact legacy, recovery preparation, ACK, marker loss, edits, tombstones and rollback atomically',async()=>{
 const f=await fixture(1),id=await db.prepare('SELECT record_id FROM pa_records WHERE owner_id=?').bind(f.owner).first<string>('record_id');
 expect(await counters(f.owner)).toEqual({record_count:1,live_count:1,record_bytes:123,pending_ack:1});
 await db.prepare(`INSERT INTO pa_record_legacy_baseline SELECT owner_id,record_id,revision,initial_operation,initial_fingerprint,
  photo_key,photo_bytes,quota_bytes,deleted FROM pa_records WHERE owner_id=?`).bind(f.owner).run();
 expect(await counters(f.owner)).toMatchObject({pending_ack:0});
 await version(f.owner,id!);expect(await counters(f.owner)).toMatchObject({pending_ack:1});
 await marker(f.owner,id!);expect(await counters(f.owner)).toMatchObject({pending_ack:0});
 await db.prepare('DELETE FROM pa_record_commit_markers WHERE owner_id=?').bind(f.owner).run();
 expect(await counters(f.owner)).toMatchObject({pending_ack:1});
 await marker(f.owner,id!);
 await db.prepare('UPDATE pa_records SET revision=2,quota_bytes=124 WHERE owner_id=?').bind(f.owner).run();
 expect(await counters(f.owner)).toEqual({record_count:1,live_count:1,record_bytes:124,pending_ack:1});
 await version(f.owner,id!,2);await marker(f.owner,id!,2);
 await expect(db.batch([db.prepare('UPDATE pa_records SET quota_bytes=999 WHERE owner_id=?').bind(f.owner),
  db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(f.owner)])).rejects.toThrow();
 expect(await counters(f.owner)).toEqual({record_count:1,live_count:1,record_bytes:124,pending_ack:0});
 await db.prepare('UPDATE pa_records SET revision=3,deleted=1,metadata=NULL,quota_bytes=0 WHERE owner_id=?').bind(f.owner).run();
 expect(await counters(f.owner)).toEqual({record_count:1,live_count:0,record_bytes:0,pending_ack:1});
 await db.prepare('DELETE FROM pa_owner_record_changes WHERE owner_id=? AND record_id=?').bind(f.owner,id).run();
 await expect(f.archive.usage('synthetic')).rejects.toMatchObject({code:'ARCHIVE_ACCOUNTING_UNAVAILABLE'});
});
it('serves 277400 lifetime IDs without record scans and rejects accounting divergence or missing counters',async(context)=>{
 const fixtureStarted=performance.now(),f=await fixture(277_400),fixtureMs=performance.now()-fixtureStarted;
 let prepares=0;
 const measured=new Proxy(db,{get(target,key){
  if(key==='prepare')return(sql:string)=>{prepares++;expect(sql).not.toMatch(/FROM pa_records|FROM pa_record_commit_markers/u);return target.prepare(sql);};
  const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
 }});
 const start=performance.now();
 const usage=await new ArchiveStore({...f.options,db:measured}).usage('synthetic');
 expect(usage.records.saved).toBe(277_400);expect(usage.storage.usedBytes).toBe(277_400*123);
 await context.annotate(JSON.stringify({usageCounterProbe:{records:277_400,fixtureMs,dbStatements:prepares,elapsedMs:performance.now()-start,recordScans:0}}),'measurement');
 await db.prepare('UPDATE pa_owner_record_counters SET record_bytes=record_bytes-1 WHERE owner_id=?').bind(f.owner).run();
 await expect(f.archive.usage('synthetic')).rejects.toMatchObject({code:'ARCHIVE_ACCOUNTING_UNAVAILABLE'});
 const empty=await fixture();
 await db.prepare('DELETE FROM pa_owner_record_counters WHERE owner_id=?').bind(empty.owner).run();
 await expect(empty.archive.usage('synthetic')).rejects.toMatchObject({code:'ARCHIVE_ACCOUNTING_UNAVAILABLE'});
},60_000);
