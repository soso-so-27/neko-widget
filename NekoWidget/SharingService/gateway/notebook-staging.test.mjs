import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { createNotebookStagingRouter } from './notebook-staging-router.mjs';

test('notebook adapter preserves other requests, billing scope and existing scheduled work',async()=>{
  const env={ENVIRONMENT:'staging',BILLING_STORE_ENVIRONMENT:'unchanged'},ctx={waitUntil(p){pending.push(p);}},pending=[];
  let legacyCalls=0,notebookCalls=0,schedules=0,cleanups=0;
  const router=createNotebookStagingRouter({fetch(r,e,c){assert.equal(e,env);assert.equal(c,ctx);legacyCalls++;return new Response(r.body);},scheduled(c,e){assert.equal(e,env);schedules++;return 'existing';}},
    {fetch(r,e){assert.equal(e.BILLING_STORE_ENVIRONMENT,'Sandbox');assert.equal(e.BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED,'YES');notebookCalls++;return new Response('notebook');}},async()=>{cleanups++;},'cleanup');
  for(const path of ['/v1/billing/transactions','/v1/billing/apple-notifications','/v3/group-windows','/v2/family-records','/v3/family-notebooks-other']){
    const r=await router.fetch(new Request('https://local'+path,{method:'POST',body:'exact bytes'}),env,ctx);assert.equal(await r.text(),'exact bytes');
  }
  for(const path of ['/v3/family-notebooks','/v3/family-notebooks/me'])assert.equal(await (await router.fetch(new Request('https://local'+path),env,ctx)).text(),'notebook');
  assert.equal((await router.fetch(new Request('https://local/v3/family-notebooks'),{ENVIRONMENT:'production'},ctx)).status,503);
  assert.equal(router.scheduled({cron:'other'},env,ctx),'existing');router.scheduled({cron:'cleanup'},env,ctx);await Promise.all(pending);
  assert.deepEqual([legacyCalls,notebookCalls,schedules,cleanups],[5,2,2,1]);assert.equal(env.BILLING_STORE_ENVIRONMENT,'unchanged');
});

test('workerd rejects unsigned notebook requests and preserves all legacy routes',{timeout:30000},async()=>{
  const compiled=await build({entryPoints:[fileURLToPath(new URL('./notebook-staging-entry.mjs',import.meta.url))],
    alias:{'notebook-staging-legacy':process.env.NOTEBOOK_STAGING_LEGACY_MODULE||fileURLToPath(new URL('./family-entry.mjs',import.meta.url))},
    bundle:true,format:'esm',platform:'neutral',target:'es2022',external:['cloudflare:workers'],write:false});
  const mf=new Miniflare(convertV4MiniflareOptions({cf:false,modules:true,script:compiled.outputFiles[0].text,compatibilityDate:'2026-08-17',
    bindings:{ENVIRONMENT:'staging',FAMILY_NOTEBOOK_API_RUNTIME_ENABLED:'YES',FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED:'YES'},d1Databases:{DB:'notebook-staging-fixture'},
    ratelimits:{MEMBER_RATE_LIMITER:{namespace_id:'710003',simple:{limit:120,period:60}}}}));
  try{
    const db=await mf.getD1Database('DB');await db.exec('CREATE TABLE family_notebook_runtime_gate(singleton INTEGER PRIMARY KEY,enabled INTEGER,generation INTEGER); INSERT INTO family_notebook_runtime_gate VALUES(1,1,1)');
    const r=await mf.dispatchFetch('https://local/v3/family-notebooks/me');const body=await r.json();assert.equal(r.status,401,JSON.stringify(body));assert.equal(body.error.code,'invalid_authentication');
    const closed=await mf.dispatchFetch('https://local/v1/billing/transactions',{method:'POST',body:'{}'});assert.equal(closed.status,503);
    const gate=await db.prepare('SELECT * FROM family_notebook_runtime_gate').all();assert.deepEqual(gate.results,[{singleton:1,enabled:1,generation:1}]);
  }finally{await mf.dispose();}
});
