import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { DurableAuth } from '../src/auth';
import { randomToken, sha256 } from '../src/contracts';
import { envelopeKeyCustody } from '../src/key-custody';
import { OwnerRecoveryCopy } from '../src/owner-recovery-copy';
import { syntheticKeyAuthority } from './key-fixture';
import { openOwnerSnapshot } from '../src/owner-snapshot-codec';
import type { RecoveryObject, S3RecoveryCopy } from '../src/s3-recovery-copy';

const db = (env as unknown as {DB:D1Database}).DB;
const now = 1_790_035_200_000;
async function fixture(count=0) {
  const authority=await syntheticKeyAuthority();
  const keys=envelopeKeyCustody({enabled:true,wrapper:authority.make()});
  const secret=randomToken(), objects=new Map<string,Uint8Array>();
  const io={reads:0,writes:0,readBytes:0,writeBytes:0};
  const s3={
    async putVersioned(key:string,bytes:Uint8Array):Promise<RecoveryObject> {
      io.writes++;io.writeBytes+=bytes.length;objects.set(key,bytes.slice());
      return {key,versionId:'synthetic-v1',sha256:await sha256(bytes),bytes:bytes.length};
    },
    async getVerified(ref:RecoveryObject) {
      const bytes=objects.get(ref.key);
      if (!bytes || ref.versionId!=='synthetic-v1' || bytes.length!==ref.bytes || await sha256(bytes)!==ref.sha256) throw Error('synthetic checksum');
      io.reads++;io.readBytes+=bytes.length;return bytes.slice();
    },
  } as S3RecoveryCopy;
  const copy=new OwnerRecoveryCopy(keys,s3,secret,{pagedWrites:true,compressWrites:true});
  const auth=new DurableAuth({db,keys,identityIndexSecret:secret,now:()=>now});
  const session=await auth.establish({issuer:'https://appleid.apple.com',subject:crypto.randomUUID(),refreshToken:randomToken()});
  const owner=session.ownerId;
  await db.prepare('INSERT INTO pa_inventory(owner_id) VALUES(?)').bind(owner).run();
  if (count) {
    await db.prepare(`WITH RECURSIVE ids(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM ids WHERE n<?)
      INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,metadata,deleted)
      SELECT ?,lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-4000-8000-'||lower(hex(randomblob(6))),
        1,'synthetic','synthetic',X'01',0 FROM ids`).bind(count,owner).run();
    await markers(owner);
  }
  const first=await copy.copyCurrent(db,owner,now);
  const ids=(await db.prepare('SELECT record_id FROM pa_records WHERE owner_id=? ORDER BY record_id')
    .bind(owner).all<{record_id:string}>()).results.map(row=>row.record_id);
  const baselineIO={...io};
  const reset=()=>{io.reads=io.writes=io.readBytes=io.writeBytes=0;};
  reset();
  return {copy,owner,first,ids,io,baselineIO,reset,objects,s3,keys,secret,authority};
}
async function markers(owner:string) {
  await db.batch([
    db.prepare(`INSERT OR IGNORE INTO pa_record_recovery_versions(owner_id,record_id,revision,
      record_object_key,record_version_id,record_sha256,record_bytes,committed_at)
      SELECT owner_id,record_id,revision,'recovery/v1/'||owner_id||'/record/'||
        lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-4000-8000-'||lower(hex(randomblob(6))),
        'synthetic-version',?,100,100 FROM pa_records WHERE owner_id=?`).bind('e'.repeat(64),owner),
    db.prepare(`INSERT OR IGNORE INTO pa_record_commit_markers(owner_id,record_id,revision,
      marker_object_key,marker_version_id,marker_sha256,marker_bytes,confirmed_at)
      SELECT owner_id,record_id,revision,'recovery/v1/'||owner_id||'/manifest/'||
        lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-4000-8000-'||lower(hex(randomblob(6))),
        'synthetic-version',?,100,100 FROM pa_records WHERE owner_id=?`).bind('f'.repeat(64),owner),
  ]);
}
async function change(owner:string,id:string,deleted=false) {
  await db.prepare(`UPDATE pa_records SET revision=revision+1,deleted=?,metadata=? WHERE owner_id=? AND record_id=?`)
    .bind(deleted?1:0,deleted?null:new Uint8Array([2]),owner,id).run();
  await markers(owner);
}
function intercept(action:(sql:string,method:string,result:unknown)=>Promise<void>,before=false):D1Database {
  return new Proxy(db,{get(target,key){
    if (key!=='prepare') {const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;}
    return (sql:string)=>{
      const wrap=(statement:D1PreparedStatement):D1PreparedStatement=>new Proxy(statement,{get(stmt,method){
        if(method==='bind')return (...args:unknown[])=>wrap(stmt.bind(...args));
        const value=Reflect.get(stmt,method);
        if(typeof value!=='function')return value;
        return async (...args:unknown[])=>{
          if(before)await action(sql,String(method),undefined);
          const result=await value.apply(stmt,args);
          if(!before)await action(sql,String(method),result);
          return result;
        };
      }});
      return wrap(target.prepare(sql));
    };
  }});
}

it('updates one of 36500 records without expanding history, preserving tombstones and the old tree',async(context)=>{
  const f=await fixture(36_500), beforeObjects=new Map(f.objects);
  const original=f.copy.capture.bind(f.copy);
  const baseline=await original(db,f.owner);
  f.copy.capture=async()=>{throw Error('full inventory unexpectedly read');};
  await change(f.owner,f.ids[100]!,true);
  let deltaRows=0;
  const measured=intercept(async(sql,method,result)=>{
    if(sql.includes('ORDER BY items.change_sequence') && method==='all')deltaRows+=(result as D1Result).results.length;
    expect(sql).not.toContain('SELECT count(*) FROM pa_records');
    expect(sql).not.toContain('ORDER BY items.record_id');
  });
  const next=await f.copy.copyCurrent(measured,f.owner,now);
  expect(deltaRows).toBe(1);
  expect(f.io.reads).toBeLessThan(20);expect(f.io.writes).toBeLessThan(10);
  expect(f.io.readBytes).toBeLessThan(200_000);expect(f.io.writeBytes).toBeLessThan(100_000);
  await context.annotate(JSON.stringify({ownerDeltaProbe:{records:36_500,changed:1,deltaRows,
    incremental:{...f.io},baseline:f.baselineIO}}),'measurement');
  for(const [key,bytes] of beforeObjects)expect(f.objects.get(key)).toBe(bytes);
  const expected=await original(db,f.owner);
  // These calls verify the full logical inventory hash and actual S3 roots;
  // they do not repeatedly download 4369 unchanged pages for the cost probe.
  expect(await f.copy.read(f.owner,next,expected)).toEqual(expected);
  expect(await f.copy.read(f.owner,f.first,baseline)).toEqual(baseline);
  expect(baseline.records.find(r=>r.recordId===f.ids[100])?.deleted).toBe(false);
  expect(expected.records.find(r=>r.recordId===f.ids[100])?.deleted).toBe(true);
},60_000);

it('pages a 401-record delta and coalesces repeated writes while owner generations also advance',async()=>{
  const f=await fixture(401);
  await db.prepare('UPDATE pa_records SET revision=revision+1 WHERE owner_id=?').bind(f.owner).run();
  await markers(f.owner);
  await change(f.owner,f.ids[0]!); // sequence jumps are valid; the newest value wins.
  await db.prepare('UPDATE pa_identity_credentials SET updated_at=updated_at+1 WHERE owner_id=?').bind(f.owner).run();
  let pages=0;
  const observed=intercept(async(sql,method)=>{if(sql.includes('ORDER BY items.change_sequence')&&method==='all')pages++;});
  const next=await f.copy.copyCurrent(observed,f.owner,now);
  expect(pages).toBe(3);
  expect(await f.copy.read(f.owner,next)).toEqual(await f.copy.capture(db,f.owner));
  expect(await db.prepare('SELECT count(*) AS n FROM pa_owner_record_changes WHERE owner_id=?').bind(f.owner).first('n')).toBe(401);
},30_000);

it('crosses 100000 lifetime IDs only through a verified delta cursor, retaining full-hydration guards',async(context)=>{
  const fixtureStarted=performance.now(),f=await fixture(100_000),fixtureMs=performance.now()-fixtureStarted;
  const record=crypto.randomUUID();
  await db.prepare(`INSERT INTO pa_records(owner_id,record_id,revision,initial_fingerprint,initial_operation,metadata,deleted)
    VALUES(?,?,1,'synthetic','synthetic',X'01',0)`).bind(f.owner,record).run();
  await markers(f.owner);
  const read=f.s3.getVerified.bind(f.s3);let interrupted=false;
  f.s3.getVerified=async(ref)=>{
    if (!interrupted && ref.key.includes('/owner/') && ref.key!==f.first.key) {
      interrupted=true;throw Error('synthetic readback failure after version INSERT');
    }
    return read(ref);
  };
  await expect(f.copy.copyCurrent(db,f.owner,now)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  expect(interrupted).toBe(true);
  expect(await db.prepare('SELECT count(*) AS n FROM pa_owner_recovery_versions WHERE owner_id=?').bind(f.owner).first('n')).toBe(2);
  expect(await db.prepare('SELECT record_count FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).first('record_count')).toBe(100_000);
  f.reset();
  const next=await f.copy.copyCurrent(db,f.owner,now);
  expect(await db.prepare('SELECT count(*) AS n FROM pa_owner_recovery_versions WHERE owner_id=?').bind(f.owner).first('n')).toBe(2);
  expect(f.io.writes).toBeLessThan(10);
  expect(await db.prepare('SELECT record_count FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).first('record_count')).toBe(100_001);
  f.reset();
  expect(await f.copy.copyCurrent(db,f.owner,now)).toEqual(next);
  expect(f.io.writes).toBe(0);expect(f.io.reads).toBe(2);
  await expect(f.copy.capture(db,f.owner)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  await expect(f.copy.read(f.owner,next)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  await db.prepare('DELETE FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).run();
  f.reset();const firstStarted=performance.now();
  await expect(f.copy.copyCurrent(db,f.owner,now)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  expect(await db.prepare('SELECT processed FROM pa_owner_recovery_builds WHERE owner_id=?').bind(f.owner).first('processed')).toBe(200);
  let pages=1,peakReads=f.io.reads,peakWrites=f.io.writes,peakBytes=f.io.readBytes+f.io.writeBytes,
    peakReadBytes=f.io.readBytes,peakWriteBytes=f.io.writeBytes,peakMs=performance.now()-firstStarted;
  for(;;){
    f.reset();const started=performance.now(),result=await f.copy.rebuildCurrent(db,f.owner,now);pages++;
    expect(result.rows).toBeLessThanOrEqual(200);
    peakReads=Math.max(peakReads,f.io.reads);peakWrites=Math.max(peakWrites,f.io.writes);
    peakBytes=Math.max(peakBytes,f.io.readBytes+f.io.writeBytes);
    peakReadBytes=Math.max(peakReadBytes,f.io.readBytes);peakWriteBytes=Math.max(peakWriteBytes,f.io.writeBytes);peakMs=Math.max(peakMs,performance.now()-started);
    if(result.status==='complete'){expect(result.reference).toEqual(next);break;}
    expect(pages).toBeLessThan(502);
  }
  expect(pages).toBe(501);expect(peakWrites).toBe(0);
  expect(await db.prepare('SELECT 1 FROM pa_owner_recovery_builds WHERE owner_id=?').bind(f.owner).first()).toBeNull();
  await context.annotate(JSON.stringify({ownerRebuildProbe:{records:100_001,fixtureMs,pages,peakReads,peakWrites,peakBytes,peakReadBytes,peakWriteBytes,peakMs,maximumRows:200}}),'measurement');
  expect(await f.copy.copyCurrent(db,f.owner,now)).toEqual(next);
},180_000);

it('restarts a stale rebuild checkpoint and refuses missing markers without acknowledging a partial tree',async()=>{
  const f=await fixture(401);
  await db.prepare('DELETE FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).run();
  expect(await f.copy.rebuildCurrent(db,f.owner,now)).toMatchObject({status:'pending',processed:200,total:401});
  await change(f.owner,f.ids[400]!,true);
  expect(await f.copy.rebuildCurrent(db,f.owner,now)).toMatchObject({status:'pending',processed:200,total:401});
  await db.prepare('UPDATE pa_records SET revision=revision+1 WHERE owner_id=? AND record_id=?')
    .bind(f.owner,f.ids[0]!).run();
  await expect(f.copy.rebuildCurrent(db,f.owner,now)).rejects.toThrow();
  expect(await db.prepare('SELECT 1 FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).first()).toBeNull();
  await markers(f.owner);
  expect(await f.copy.rebuildCurrent(db,f.owner,now)).toMatchObject({status:'pending',processed:200});
  expect(await f.copy.rebuildCurrent(db,f.owner,now)).toMatchObject({status:'pending',processed:400});
  expect(await f.copy.rebuildCurrent(db,f.owner,now)).toMatchObject({status:'complete',processed:401});
});

it('retains rebuild progress across recurring retention header refreshes and binds the final current generation',async()=>{
  const f=await fixture(601);
  await db.prepare('DELETE FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).run();
  await db.prepare(`INSERT INTO pa_retention(owner_id,revision,episode,verified_status,checked_at)
    VALUES(?,1,1,'active',?)`).bind(f.owner,now).run();
  for(let page=1;page<=3;page++){
    expect(await f.copy.rebuildCurrent(db,f.owner,now)).toMatchObject({status:'pending',processed:page*200,total:601});
    await db.prepare('UPDATE pa_retention SET revision=revision+1,checked_at=checked_at+3600000 WHERE owner_id=?').bind(f.owner).run();
  }
  const result=await f.copy.rebuildCurrent(db,f.owner,now);
  expect(result).toMatchObject({status:'complete',processed:601,total:601});
  if(result.status!=='complete')throw Error('not complete');
  expect(await f.copy.read(f.owner,result.reference)).toEqual(await f.copy.capture(db,f.owner));
  expect(await db.prepare('SELECT generation FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).first('generation'))
    .toBe(await db.prepare('SELECT generation FROM pa_owner_recovery_generations WHERE owner_id=?').bind(f.owner).first('generation'));
});

it('refuses an unmarked revision, then includes it after marker repair without dropping other records',async()=>{
  const f=await fixture(2);
  await db.prepare('UPDATE pa_records SET revision=revision+1 WHERE owner_id=? AND record_id=?').bind(f.owner,f.ids[0]).run();
  await expect(f.copy.copyCurrent(db,f.owner,now)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  expect(await db.prepare('SELECT generation FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).first('generation'))
    .toBe((await f.copy.read(f.owner,f.first)).generation);
  await markers(f.owner);
  const next=await f.copy.copyCurrent(db,f.owner,now);
  expect(await f.copy.read(f.owner,next)).toEqual(await f.copy.capture(db,f.owner));
});

it.each(['delta-read','ack-insert','cursor-fence'] as const)('rejects an unmarked competing write at %s',async timing=>{
  const f=await fixture(1);
  await change(f.owner,f.ids[0]!);
  let raced=false;
  const database=intercept(async(sql,method)=>{
    const match=timing==='delta-read'?sql.includes('ORDER BY items.change_sequence')&&method==='all'
      :timing==='ack-insert'?sql.startsWith('INSERT INTO pa_owner_recovery_versions')&&method==='run'
      :sql.startsWith('INSERT INTO pa_owner_recovery_tree_cursors')&&method==='run';
    if(!raced&&match){raced=true;await db.prepare('UPDATE pa_records SET revision=revision+1 WHERE owner_id=? AND record_id=?').bind(f.owner,f.ids[0]).run();}
  },timing!=='delta-read');
  await expect(f.copy.copyCurrent(database,f.owner,now)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  expect(raced).toBe(true);
  expect(await db.prepare('SELECT generation FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).first('generation'))
    .toBe((await f.copy.read(f.owner,f.first)).generation);
});

it('rebuilds a missing cursor or deleted derived entry through full verification',async()=>{
  const f=await fixture(2);
  await db.prepare('DELETE FROM pa_owner_record_changes WHERE owner_id=? AND record_id=?').bind(f.owner,f.ids[0]).run();
  expect(await db.prepare('SELECT count(*) AS n FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).first('n')).toBe(0);
  let captures=0;const capture=f.copy.capture.bind(f.copy);
  f.copy.capture=async(...args)=>{captures++;return capture(...args);};
  await f.copy.copyCurrent(db,f.owner,now);
  expect(captures).toBe(1);
  await change(f.owner,f.ids[0]!);
  const next=await f.copy.copyCurrent(db,f.owner,now);
  expect(captures).toBe(1);
  expect(await f.copy.read(f.owner,next)).toEqual(await capture(db,f.owner));
});

it('invalidates the cursor if an offline repair removes a previously acknowledged current marker',async()=>{
  const f=await fixture(1);
  await db.prepare('DELETE FROM pa_record_commit_markers WHERE owner_id=?').bind(f.owner).run();
  expect(await db.prepare('SELECT count(*) AS n FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).first('n')).toBe(0);
  await expect(f.copy.copyCurrent(db,f.owner,now)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  await markers(f.owner);
  const next=await f.copy.copyCurrent(db,f.owner,now);
  expect(await f.copy.read(f.owner,next)).toEqual(await f.copy.capture(db,f.owner));
});

it('falls back when a legacy writer acknowledges a newer generation without an incremental cursor',async()=>{
  const f=await fixture(1);
  await change(f.owner,f.ids[0]!);
  const legacy=new OwnerRecoveryCopy(f.keys,f.s3,f.secret);
  await legacy.copyCurrent(db,f.owner,now);
  await f.copy.copyCurrent(db,f.owner,now); // v2 remains readable; it must not become a tree cursor.
  await change(f.owner,f.ids[0]!);
  const next=await f.copy.copyCurrent(db,f.owner,now);
  expect(await f.copy.read(f.owner,next)).toEqual(await f.copy.capture(db,f.owner));
});

it('rejects a corrupt prior owner copy and keeps the previous cursor',async()=>{
  const f=await fixture(1);
  await change(f.owner,f.ids[0]!);
  const bytes=f.objects.get(f.first.key)!;bytes[0]=bytes[0]!^1;
  await expect(f.copy.copyCurrent(db,f.owner,now)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  expect(await db.prepare('SELECT count(*) AS n FROM pa_owner_recovery_versions WHERE owner_id=?').bind(f.owner).first('n')).toBe(1);
});

it('concurrent copies bind one winning S3 version and preserve owner isolation',async()=>{
  const f=await fixture(1), other=await fixture(1);
  await change(f.owner,f.ids[0]!);
  const [a,b]=await Promise.all([f.copy.copyCurrent(db,f.owner,now),f.copy.copyCurrent(db,f.owner,now)]);
  expect(a).toEqual(b);
  expect(await f.copy.read(f.owner,a)).toEqual(await f.copy.capture(db,f.owner));
  await expect(f.copy.read(other.owner,a)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
});


it('authenticates the changed root through update without an extra root download, retaining both versions',async()=>{
  const f=await fixture(1),before=new Map(f.objects);
  await change(f.owner,f.ids[0]!);
  const next=await f.copy.copyCurrent(db,f.owner,now);
  // Existing owner + update old leaf + new owner readback + new root readback.
  expect(f.io.reads).toBe(4);expect(f.io.writes).toBe(2);
  for(const [key,value]of before)expect(f.objects.get(key)).toBe(value);
  expect(await f.copy.read(f.owner,next)).toEqual(await f.copy.capture(db,f.owner));
  f.reset();expect(await f.copy.copyCurrent(db,f.owner,now)).toEqual(next);
  expect(f.io.reads).toBe(2);expect(f.io.writes).toBe(0);
});

it.each(['delta','idempotent','header-only']as const)(
  'rejects a missing authenticated root before new publication on the %s path',async path=>{
  const f=await fixture(1);
  const generation=await db.prepare('SELECT generation FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).first('generation');
  const versions=await db.prepare('SELECT count(*)AS n FROM pa_owner_recovery_versions WHERE owner_id=?').bind(f.owner).first('n');
  if(path==='delta')await change(f.owner,f.ids[0]!);
  if(path==='header-only')await db.prepare('UPDATE pa_identity_credentials SET updated_at=updated_at+1 WHERE owner_id=?').bind(f.owner).run();
  const roots=[...f.objects.keys()].filter(key=>key.includes('/record/'));
  expect(roots).toHaveLength(1);f.objects.delete(roots[0]!);f.reset();
  await expect(f.copy.copyCurrent(db,f.owner,now)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  expect(f.io.writes).toBe(0);
  expect(await db.prepare('SELECT generation FROM pa_owner_recovery_tree_cursors WHERE owner_id=?').bind(f.owner).first('generation')).toBe(generation);
  expect(await db.prepare('SELECT count(*)AS n FROM pa_owner_recovery_versions WHERE owner_id=?').bind(f.owner).first('n')).toBe(versions);
});

it('still rechecks key authority when the old root is opened after the delta query',async()=>{
  const f=await fixture(1);await change(f.owner,f.ids[0]!);let revoked=false;
  const observed=intercept(async(sql,method)=>{
    if(!revoked&&sql.includes('ORDER BY items.change_sequence')&&method==='all'){
      revoked=true;f.authority.remove('synthetic/v1');
    }
  });
  await expect(f.copy.copyCurrent(observed,f.owner,now)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  expect(revoked).toBe(true);expect(f.io.writes).toBe(0);
});

it('verifies and publishes a header-only change with no record delta and keeps the old tree',async()=>{
  const f=await fixture(1),before=new Map(f.objects);
  await db.prepare('UPDATE pa_identity_credentials SET updated_at=updated_at+1 WHERE owner_id=?').bind(f.owner).run();
  const next=await f.copy.copyCurrent(db,f.owner,now);
  expect(f.io.reads).toBe(4);expect(f.io.writes).toBe(1);
  for(const [key,value]of before)expect(f.objects.get(key)).toBe(value);
  expect(await f.copy.read(f.owner,next)).toEqual(await f.copy.capture(db,f.owner));
});


it('rejects an authenticated owner image whose claimed old root semantic hash does not match the stored node',async()=>{
  const f=await fixture(1),scope={ownerId:f.owner,purpose:'recovery' as const};
  const opened=await f.keys.open(f.objects.get(f.first.key)!,scope);
  const wire=JSON.parse(new TextDecoder().decode(await openOwnerSnapshot(opened)));
  wire.recordsTree.hash='0'.repeat(64);
  const changed=await f.keys.seal(new TextEncoder().encode(JSON.stringify(wire)),scope);
  // A self-consistent synthetic outer ciphertext/ref still must not make a
  // mismatching inner semantic root trustworthy. No real object is rewritten.
  f.objects.set(f.first.key,changed);
  await db.prepare('UPDATE pa_owner_recovery_versions SET sha256=?,bytes=? WHERE owner_id=? AND object_key=?')
    .bind(await sha256(changed),changed.length,f.owner,f.first.key).run();
  await change(f.owner,f.ids[0]!);f.reset();
  await expect(f.copy.copyCurrent(db,f.owner,now)).rejects.toMatchObject({code:'OWNER_RECOVERY_UNAVAILABLE'});
  expect(f.io.reads).toBe(2);expect(f.io.writes).toBe(0);
});
