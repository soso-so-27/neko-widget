import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { ArchiveStore } from '../src/storage';
import { DurableAuth } from '../src/auth';
import { randomToken, sha256, type ArchiveDocument, type KeyCustody } from '../src/contracts';
import { measureProductRecord, requireProductCapacity } from '../src/product-usage';
import type { ProductQuotaSettings } from '../src/product-quota-policy';

const binding = env as unknown as { DB: D1Database; ARCHIVE: R2Bucket };
const base: ArchiveDocument = { formatVersion: 1, text: 'one memo', capturedAt: null, writtenAt: null,
  updatedAt: null, catNames: [], photoFile: null };
const input = (document = base, expectedRevision: number | null = null) =>
  ({ document,expectedRevision,consentVersion:'managed-preservation-v1',photoBase64:null });
async function fixture(settings: ProductQuotaSettings = {}) {
  await binding.DB.prepare('UPDATE pa_recovery_write_policy SET delete_intent_required=0,owner_snapshot_required=0 WHERE singleton=1').run();
  // Test-only reversible metadata. Real key custody is unchanged and tested separately.
  const keys: KeyCustody = { seal: async value => new Uint8Array(value), open: async value => new Uint8Array(value) };
  const now = () => 1_790_035_200_000;
  const auth = new DurableAuth({ db:binding.DB,keys,identityIndexSecret:randomToken(),now });
  const session = await auth.establish({ issuer:'https://appleid.apple.com',subject:crypto.randomUUID(),refreshToken:randomToken() });
  const archive = new ArchiveStore({db:binding.DB,bucket:binding.ARCHIVE,keys,auth,now,
    membership:{status:async()=>'active'},photos:{validateJPEG:async()=>true},
    quotaBytes:32*1024*1024,maximumRecords:1000,productQuotaSettings:settings});
  return {archive,session,keys};
}

it('returns real logical bytes/count only to opt-in readers; retries, updates and deletes reconcile',async()=>{
  const f=await fixture(),id=crypto.randomUUID(),token=f.session.token;
  await f.archive.put(token,id,input());
  await f.archive.put(token,id,input());
  expect((await f.archive.usage(token)).productQuota).toBeUndefined();
  expect((await f.archive.usage(token,1)).productQuota).toBeUndefined();
  const first=(await f.archive.usage(token,2)).productQuota!;
  expect(first.accountingStatus).toBe('ready');
  expect(first.usage?.records.saved).toBe(1);
  expect(first.usage?.storage.usedBytes).toBe(new TextEncoder().encode(JSON.stringify(base)).length);
  await f.archive.put(token,id,input({...base,text:'longer saved memo'},1));
  const second=(await f.archive.usage(token,2)).productQuota!;
  expect(second.usage?.records.saved).toBe(1);
  expect(second.usage!.storage.usedBytes).toBeGreaterThan(first.usage!.storage.usedBytes);
  await f.archive.remove(token,id,2);
  expect((await f.archive.usage(token,2)).productQuota?.usage).toMatchObject({storage:{usedBytes:0},records:{saved:0}});
});

it('invalidates derived facts on restored/replaced data and recounts without changing archive revision',async()=>{
  const f=await fixture(),id=crypto.randomUUID(),token=f.session.token;
  await f.archive.put(token,id,input());
  await binding.DB.prepare('UPDATE pa_records SET metadata=metadata WHERE owner_id=? AND record_id=?').bind(f.session.ownerId,id).run();
  expect((await f.archive.usage(token,2)).productQuota?.usage).toBeNull();
  expect(await f.archive.recountProductUsage(token)).toMatchObject({processed:1,nextCursor:null});
  expect((await f.archive.usage(token,2)).productQuota?.usage?.records.saved).toBe(1);
  expect((await f.archive.read(token,id)).revision).toBe(1);
});

it('rejects a second record at the product count limit while retaining reads, edits and removal',async()=>{
  const f=await fixture({PRODUCT_VISIBLE_RECORDS:'1',PRODUCT_QUOTA_ENFORCEMENT:'true'}),token=f.session.token,id=crypto.randomUUID();
  await f.archive.put(token,id,input());
  await expect(f.archive.put(token,crypto.randomUUID(),input())).rejects.toMatchObject({code:'PRODUCT_RECORD_LIMIT_EXCEEDED'});
  await f.archive.put(token,id,input({...base,text:'edited'},1));
  expect((await f.archive.read(token,id)).revision).toBe(2);
  await f.archive.remove(token,id,2);
  await f.archive.put(token,crypto.randomUUID(),input());
});

it('fences competing admission against the same total',async()=>{
  const f=await fixture({PRODUCT_VISIBLE_RECORDS:'1',PRODUCT_QUOTA_ENFORCEMENT:'true'}),token=f.session.token;
  const results=await Promise.allSettled([f.archive.put(token,crypto.randomUUID(),input()),f.archive.put(token,crypto.randomUUID(),input())]);
  expect(results.filter(r=>r.status==='fulfilled')).toHaveLength(1);
  expect((await f.archive.usage(token,2)).productQuota?.usage?.records.saved).toBe(1);
});

it('also enforces a legacy standalone tool snapshot at publication, not by its transport row count',async()=>{
  const f=await fixture({PRODUCT_VISIBLE_RECORDS:'1',PRODUCT_QUOTA_ENFORCEMENT:'true'}),token=f.session.token;
  const root=crypto.randomUUID(),piece=crypto.randomUUID(),raw='{"schemaVersion":1,"cats":[{},{}]}',hash=await sha256(raw);
  await f.archive.put(token,piece,input({...base,formatVersion:3,toolBackup:{
    snapshotId:root,kind:'json',path:'CareHandoff/plan.json',part:0,count:1,sha256:hash,payload:btoa(raw)}}));
  expect((await f.archive.usage(token,2)).productQuota?.usage?.records.saved).toBe(0);
  const index=JSON.stringify({version:3,snapshotID:root,createdAt:1,
    files:[{path:'CareHandoff/plan.json',bytes:raw.length,sha256:hash,records:[piece]}]});
  await expect(f.archive.put(token,root,input({...base,formatVersion:3,toolBackup:{
    snapshotId:root,kind:'index',path:'index.json',part:0,count:1,sha256:await sha256(index),payload:btoa(index)}})))
    .rejects.toMatchObject({code:'PRODUCT_RECORD_LIMIT_EXCEEDED'});
});

it('distinguishes bytes, records and both; unknown is never free capacity; reductions remain possible',()=>{
  const settings={PRODUCT_PLUS_BYTES:'100',PRODUCT_TRIAL_BYTES:'50',PRODUCT_VISIBLE_RECORDS:'2',PRODUCT_QUOTA_ENFORCEMENT:'true'};
  const counters={product_bytes:100,product_records:2,product_unknown:0},zero={bytes:0,records:0};
  for(const [next,code] of [[{bytes:1,records:0},'PRODUCT_STORAGE_LIMIT_EXCEEDED'],
    [{bytes:0,records:1},'PRODUCT_RECORD_LIMIT_EXCEEDED'],[{bytes:1,records:1},'PRODUCT_STORAGE_AND_RECORD_LIMIT_EXCEEDED']] as const){
    expect(()=>requireProductCapacity(settings,counters,zero,next,false)).toThrow(code);
  }
  expect(()=>requireProductCapacity(settings,{...counters,product_unknown:1},zero,zero,false)).toThrow('PRODUCT_QUOTA_ACCOUNTING_UNAVAILABLE');
  expect(()=>requireProductCapacity(settings,{...counters,product_bytes:200},{bytes:50,records:1},{bytes:40,records:1},false)).not.toThrow();
});

it('counts reconstructed JSON notes once despite multiple transport pieces and history metadata',async()=>{
  const root=crypto.randomUUID(),piece=crypto.randomUUID(),notes=JSON.stringify({schema:1,notes:{a:{text:'a'},b:{text:'b'}}});
  const raw=new TextEncoder().encode(notes),hash=await sha256(raw);
  const index={version:4,snapshotID:root,uploadSnapshotID:root,createdAt:1,prefix:'',files:[
    {path:'PhotoMemoryNotes/state.json',bytes:raw.length,sha256:hash,records:[piece]}]};
  const indexRaw=JSON.stringify(index),indexHash=await sha256(indexRaw);
  const head={...base,text:JSON.stringify({kind:'app-records-v1',snapshotID:root,indexHash})};
  const result=await measureProductRecord(head,0,async id=>({document:{...base,formatVersion:3,toolBackup:
    id===root ? {snapshotId:root,kind:'index',path:'index.json',part:0,count:1,sha256:indexHash,payload:btoa(indexRaw)}
    : {snapshotId:root,kind:'json',path:'PhotoMemoryNotes/state.json',part:0,count:1,sha256:hash,payload:btoa(notes)}},photoBytes:0}));
  expect(result).toEqual({bytes:raw.length,records:2});
});

it('measures 3000 synthetic notes from chunked v4 JSON without charging chunk/index overhead',async()=>{
  const root=crypto.randomUUID(),manifestID=crypto.randomUUID(),nodes=new Map<string,ArchiveDocument>();
  const raw=new TextEncoder().encode(JSON.stringify({schemaVersion:4,notes:Object.fromEntries(
    Array.from({length:3000},(_,i)=>[String(i),{text:'synthetic note '+i}]))}));
  const files:{path:string;bytes:number;sha256:string;records:string[]}[]=[],chunks:{file:string;bytes:number;sha256:string}[]=[];
  const add=async(path:string,bytes:Uint8Array)=>{
    const id=crypto.randomUUID(),hash=await sha256(bytes);
    nodes.set(id,{...base,formatVersion:3,toolBackup:{snapshotId:root,kind:'json',path,part:0,count:1,sha256:hash,
      payload:btoa(String.fromCharCode(...bytes))}});
    files.push({path,bytes:bytes.length,sha256:hash,records:[id]});
    return {file:path.split('/')[1]!,bytes:bytes.length,sha256:hash};
  };
  for(let at=0;at<raw.length;at+=32768)chunks.push(await add('PhotoMemoryNotes/'+crypto.randomUUID()+'.json',raw.slice(at,at+32768)));
  await add('PhotoMemoryNotes/state.json',new TextEncoder().encode('NEKO-JSON-CHUNKS-1\n'+JSON.stringify({bytes:raw.length,sha256:await sha256(raw),chunks})));
  const index={version:4,snapshotID:root,uploadSnapshotID:root,createdAt:1,prefix:'',files},wire=JSON.stringify(index),hash=await sha256(wire);
  nodes.set(root,{...base,formatVersion:3,toolBackup:{snapshotId:root,kind:'index',path:'index.json',part:0,count:1,sha256:hash,payload:btoa(wire)}});
  let reads=0;const started=performance.now();
  const result=await measureProductRecord({...base,text:JSON.stringify({kind:'app-records-v1',snapshotID:root,indexHash:hash})},0,
    async id=>{reads++;return {document:nodes.get(id)!,photoBytes:0};});
  expect(result).toEqual({bytes:raw.length,records:3000});
  console.info(JSON.stringify({localSyntheticOnly:true,notes:3000,logicalBytes:raw.length,metadataOpens:reads,photoDownloads:0,
    elapsedMilliseconds:Math.round(performance.now()-started),notProductionCost:true}));
});
