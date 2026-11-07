import {queries} from './export-queries.mjs';
import {test} from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
import {Miniflare,convertV4MiniflareOptions} from '../NekoWidget/SharingService/node_modules/miniflare/dist/src/index.js';
import worker,{validate,digest,store} from './worker.mjs';
const now=Date.now(),day=new Date(now-86400000).toISOString().slice(0,10);
const sample=()=>({schema:1,day,batch:crypto.randomUUID(),app:'1.0 (343)',os:'18',state:{plus:true,widget:false,cats:'2',windows:'1-2',family:true,photoAccess:'limited'},counts:{mado_opened:3,'plus_offer_shown.create-family':1,'plus_purchased.settings':1,unknown_private_text:900}});
test('input bounds, daily keyed HMAC, no payload identifiers retained',async()=>{
 const r=validate(sample());assert(!('os' in r));assert(!('unknown_private_text' in r.counts));
 for(const change of [{schema:2},{day:'2026-02-30'},{batch:'device-id'},{counts:{mado_opened:-1}},{counts:{mado_opened:1.5}},{counts:{mado_opened:10001}},{app:'person@example.com'}])assert.throws(()=>validate({...sample(),...change}));
 assert.notEqual(await digest('a'.repeat(43),day,r.batch),await digest('a'.repeat(43),'2020-01-01',r.batch));
 assert.notEqual(await digest('a'.repeat(43),day,r.batch),await digest('b'.repeat(43),day,r.batch));
 assert(r.expires-now<8*86400000);
});
test('real D1 transaction: parallel retry once, rollback, aggregation, expiry and cap',async()=>{
 const mf=new Miniflare(convertV4MiniflareOptions({cf:false,modules:true,script:'export default {fetch(){return new Response("ok")}}',compatibilityDate:'2026-08-17',d1Databases:{DB:'usage-test'}}));
 try{
 const db=await mf.getD1Database('DB');await db.exec(readFileSync(new URL('./schema.sql',import.meta.url),'utf8').replace(/^\uFEFF/,''));
 const raw=sample(),r=validate(raw),h=await digest('s'.repeat(43),r.day,r.batch);
 assert.deepEqual(await Promise.all([store(db,r,h),store(db,r,h)]),[204,204]);
 assert.equal((await db.prepare('SELECT devices FROM usage_days').first()).devices,1);
 assert.equal((await db.prepare("SELECT total FROM usage_events WHERE name='mado_opened'").first()).total,3);
 assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM usage_states').first()).n,6);
 assert.equal((await db.prepare('SELECT marker FROM usage_dedup').first()).marker,null);
 assert(!JSON.stringify((await db.prepare('SELECT * FROM usage_dedup').all()).results).includes(raw.batch));
 await db.exec("CREATE TRIGGER fail_test BEFORE INSERT ON usage_states BEGIN SELECT RAISE(ABORT,'synthetic'); END;");
 const r2=validate(sample()),h2=await digest('s'.repeat(43),r2.day,r2.batch);
 await assert.rejects(store(db,r2,h2));assert.equal((await db.prepare('SELECT devices FROM usage_days').first()).devices,1);
 await db.exec('DROP TRIGGER fail_test;');assert.equal(await store(db,r2,h2),204);
 assert.equal((await db.prepare('SELECT devices FROM usage_days').first()).devices,2);
 for(const {sql} of Object.values(queries(day,day)))assert((await db.prepare(sql).all()).success);
 const funnel=(await db.prepare(queries(day,day).plus.sql).all()).results;
 assert.deepEqual(funnel.map(x=>[x.context,x.shown,x.purchased,x.count_ratio]),[['create-family',2,0,0],['settings',0,2,null]]);
 await db.exec('UPDATE usage_dedup SET expires=0;');await worker.scheduled({}, {DB:db});assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM usage_dedup').first()).n,0);
 await db.exec('UPDATE usage_quota SET accepted=5000;');assert.equal(await store(db,validate(sample()),'a'.repeat(64)),429);
 const req=new Request('https://usage.test/v1/usage',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(sample())});
 assert.equal((await worker.fetch(req,{HMAC_KEY:'x'.repeat(43),LIMIT:{limit:async()=>({success:false})},DB:db})).status,429);
 }finally{await mf.dispose();}
});
