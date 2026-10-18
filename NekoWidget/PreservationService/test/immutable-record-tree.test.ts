import {expect,it} from 'vitest';
import {ImmutableRecordTree,type TreeEntry} from '../src/immutable-record-tree';
import {sha256,type KeyCustody} from '../src/contracts';
import type {S3RecoveryCopy,RecoveryObject} from '../src/s3-recovery-copy';
const owner='00000000-0000-4000-8000-000000000001';
async function fixture(){
 const objects=new Map<string,Uint8Array>();let reads=0,writes=0,failAfter=Infinity,active=0,peak=0,writtenBytes=0;
 // Deliberately synthetic custody/I/O for topology and byte counts. Existing
 // custody/S3 suites own actual cryptographic and exact-version guarantees.
 const keys:KeyCustody={seal:async(v)=>v.slice(),open:async(v)=>v.slice()};
 const s3={async putVersioned(key:string,body:Uint8Array):Promise<RecoveryObject>{
   if(writes>=failAfter)throw Error('synthetic interrupted write');
   writes++;writtenBytes+=body.length;active++;peak=Math.max(peak,active);
   try {objects.set(key,body.slice());return {key,versionId:'synthetic-v1',bytes:body.length,sha256:await sha256(body)}}finally{active--}
 },async getVerified(ref:RecoveryObject){
   reads++;const body=objects.get(ref.key);
   if(!body || ref.versionId!=='synthetic-v1' || body.length!==ref.bytes || await sha256(body)!==ref.sha256)throw Error('missing or corrupt synthetic version');
   return body.slice();
 }} as unknown as S3RecoveryCopy;
 return {tree:new ImmutableRecordTree(owner,'owner-inventory-v1',keys,s3),objects,keys,s3,
 counts:()=>({reads,writes,peak,writtenBytes}),reset:()=>{reads=0;writes=0;peak=0;writtenBytes=0},failAfter:(n:number)=>{failAfter=n}};
}
it('changes one logical record among twenty thousand with bounded page I/O and preserves the accepted root',async()=>{
 const f=await fixture();const entries:TreeEntry[]=[];
 for(let i=0;i<20000;i++)entries.push({key:(await sha256('record-'+i)).slice(0,32),value:{revision:1,deleted:false,marker:'immutable-'+i}});
 const root=await f.tree.create(entries);
 expect(f.counts().peak).toBeLessThanOrEqual(8);
 f.reset();expect(await f.tree.create(entries,root)).toEqual(root);expect(f.counts()).toMatchObject({reads:0,writes:0});
 const changed={...entries[10000]!,value:{revision:2,deleted:true,marker:'immutable-after'}};
 const next=await f.tree.update(root,[changed]);const io=f.counts();
 expect(io.reads).toBeLessThanOrEqual(6);expect(io.writes).toBeLessThanOrEqual(6);expect(io.writes).toBeGreaterThan(0);
 expect(io.writtenBytes).toBeLessThan(65536);
 expect(next.count).toBe(20000);expect(next).not.toEqual(root);
 const restored=await f.tree.entries(next);expect(restored.find(e=>e.key===changed.key)).toEqual(changed);
 expect((await f.tree.entries(root)).find(e=>e.key===changed.key)).toEqual(entries[10000]);
 f.reset();expect(await f.tree.update(next,[changed])).toEqual(next);expect(f.counts().writes).toBe(0);
 const expected=entries.map(e=>e.key===changed.key?changed:e);
 expect(await f.tree.logicalHash(expected)).toBe(next.hash);
 f.reset();f.failAfter(1);
 await expect(f.tree.update(next,[{...changed,value:{revision:3,deleted:true,marker:'must-not-publish'}}])).rejects.toThrow();
 expect((await f.tree.entries(next)).find(e=>e.key===changed.key)).toEqual(changed);
},120000);
it('rejects foreign, missing, altered, duplicate and oversized records without exposing a partial tree',async()=>{
 const f=await fixture(),entry={key:'a'.repeat(32),value:{text:'private'}},root=await f.tree.create([entry]);
 const other=new ImmutableRecordTree('00000000-0000-4000-8000-000000000002','owner-inventory-v1',f.keys,f.s3);
 await expect(other.entries(root)).rejects.toThrow();
 await expect(new ImmutableRecordTree(owner,'other-tree',f.keys,f.s3).entries(root)).rejects.toThrow();
 await expect(f.tree.entries({...root,hash:'b'.repeat(64)})).rejects.toThrow();
 await expect(f.tree.create([entry,entry])).rejects.toThrow();
 await expect(f.tree.update(root,[{...entry,value:'x'.repeat(24577)}])).rejects.toThrow();
 f.objects.delete(root.object.key);await expect(f.tree.entries(root)).rejects.toThrow();
});
it('splits a full leaf and adds a previously absent prefix without changing the accepted root',async()=>{
 const f=await fixture();const entries=Array.from({length:64},(_,i)=>({key:'a'+i.toString(16).padStart(31,'0'),value:i}));
 const root=await f.tree.create(entries);
 const extra={key:'b'.repeat(32),value:64};
 const next=await f.tree.update(root,[extra]);
 expect(await f.tree.entries(root)).toEqual(entries);
 expect(await f.tree.entries(next)).toEqual([...entries,extra]);
 const more={key:'c'.repeat(32),value:65};
 expect(await f.tree.entries(await f.tree.update(next,[more]))).toEqual([...entries,extra,more]);
});
it('shares the I/O limit across instances and drains siblings before returning a failure',async()=>{
 const f=await fixture();let active=0,peak=0,finished=0;
 const s3={...f.s3,async putVersioned(key:string,body:Uint8Array){
   active++;peak=Math.max(peak,active);
   try { await new Promise(resolve=>setTimeout(resolve,5));return await f.s3.putVersioned(key,body); }
   finally {active--;finished++;}
 }} as S3RecoveryCopy;
 const entries=Array.from({length:128},(_,i)=>({key:i.toString(16).padStart(2,'0')+'0'.repeat(30),value:i}));
 await Promise.all([new ImmutableRecordTree(owner,'one',f.keys,s3).create(entries),
   new ImmutableRecordTree(owner,'two',f.keys,s3).create(entries)]);
 expect(peak).toBeLessThanOrEqual(8);expect(active).toBe(0);
 let attempts=0;finished=0;
 const interrupted={...s3,async putVersioned(key:string,body:Uint8Array){
   if(++attempts===1)throw Error('first sibling fails');
   return s3.putVersioned(key,body);
 }} as S3RecoveryCopy;
 await expect(new ImmutableRecordTree(owner,'failed',f.keys,interrupted).create(entries)).rejects.toThrow('first sibling fails');
 expect(active).toBe(0);expect(finished).toBe(attempts-1);
});
it('keeps materialized inventories bounded separately from authenticated delta roots',async()=>{
 const f=await fixture(),entry={key:'a'.repeat(32),value:1};
 const oversized=Array.from({length:100_001},()=>entry);
 await expect(f.tree.create(oversized)).rejects.toThrow();
 await expect(f.tree.logicalHash(oversized)).rejects.toThrow();
 const root=await f.tree.create([entry]);f.reset();
 await expect(f.tree.entries({...root,count:100_001})).rejects.toThrow();
 expect(f.counts().reads).toBe(0);
 await expect(f.tree.verifyRoot({...root,count:1_000_001})).rejects.toThrow();
 await expect(f.tree.update({...root,count:1_000_001},[entry])).rejects.toThrow();
 expect(f.counts().reads).toBe(0);
});
it('streams ordered authenticated pages and bounds node reads independently of total records',async()=>{
 const f=await fixture(),entries:TreeEntry[]=[];
 for(let i=0;i<2001;i++)entries.push({key:(await sha256('page-'+i)).slice(0,32),value:i});
 const root=await f.tree.create(entries),actual:TreeEntry[]=[];let after='',pages=0;
 do {
   f.reset();const page=await f.tree.page(root,after,200);pages++;
   expect(page.entries.length).toBeLessThanOrEqual(200);expect(page.nodes).toBeLessThanOrEqual(256);
   expect(f.counts().reads).toBe(page.nodes);actual.push(...page.entries);
   if(page.nextAfter===null)break;
   expect(page.nextAfter>after).toBe(true);after=page.nextAfter;
 }while(true);
 expect(pages).toBe(11);expect(actual).toEqual(entries.sort((a,b)=>a.key.localeCompare(b.key)));
 await expect(f.tree.page({...root,hash:'0'.repeat(64)})).rejects.toThrow();
 await expect(f.tree.page(root,'x')).rejects.toThrow();
});
