import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { test } from 'node:test';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { createGroupStagingRouter } from './group-staging-router.mjs';
import { groupStagingConfigs } from './group-staging-config.mjs';

test('existing schedule is preserved and only its APNs tick adds the group drain',async()=>{
  const env={ENVIRONMENT:'staging'},pending=[];let legacyRuns=0,drains=0;
  const ctx={waitUntil(job){pending.push(job);}};
  const router=createGroupStagingRouter({scheduled(_c,e,x){assert.equal(e,env);assert.equal(x,ctx);legacyRuns++;}},
    {},async()=>{},'cleanup',async(e)=>{assert.equal(e,env);drains++;},'* * * * *');
  router.scheduled({cron:'unrelated'},env,ctx);assert.equal(drains,0);
  router.scheduled({cron:'* * * * *'},env,ctx);await Promise.all(pending);
  assert.equal(drains,1);assert.equal(legacyRuns,2);
});

test('exact legacy body/environment/context and scheduled callback remain untouched',async()=>{
  const env={ENVIRONMENT:'staging',PRIVATE_BILLING_GATEWAY:{},BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED:'NO'},ctx={waitUntil(){}};
  let schedules=0,cleanups=0;
  const legacy={async fetch(request,e,c){assert.equal(e,env);assert.equal(c,ctx);return new Response(await request.text());},
    scheduled(c,e,x){assert.equal(e,env);assert.equal(x,ctx);schedules++;}};
  const router=createGroupStagingRouter(legacy,{fetch(){assert.fail('Legacy route entered group code');}},async()=>{cleanups++;},'cleanup');
  for(const path of ['/v1/billing/transactions','/v2/reports/responses','/v2/family-records','/v3/group-windows-other']) {
    const response=await router.fetch(new Request('https://local'+path,{method:'POST',body:'exact bytes'}),env,ctx);
    assert.equal(await response.text(),'exact bytes');
  }
  router.scheduled({cron:'other'},env,ctx);router.scheduled({cron:'cleanup'},env,ctx);
  assert.equal(schedules,2);assert.equal(cleanups,1);assert.equal(env.BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED,'NO');
});

test('Sandbox authority is scoped to group and production remains closed',async()=>{
  const env={ENVIRONMENT:'staging',GROUP_RUNTIME_ENABLED:'YES'},ctx={};
  const router=createGroupStagingRouter({fetch(){assert.fail('Group route entered legacy');}},
    {fetch(r,e,c){assert.equal(c,ctx);assert.equal(e.BILLING_STORE_ENVIRONMENT,'Sandbox');assert.equal(e.BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED,'YES');return new Response('group');}},()=>{},'cleanup');
  assert.equal(await (await router.fetch(new Request('https://local/v3/group-windows'),env,ctx)).text(),'group');
  assert.equal(env.BILLING_STORE_ENVIRONMENT,undefined);
  assert.equal((await router.fetch(new Request('https://local/v3/group-windows'),{ENVIRONMENT:'production'},ctx)).status,503);
});

test('OFF/ON retain all existing config and differ only by GROUP value',()=>{
  const baseline={name:'neko-window-sharing-staging',main:'old.js',compatibility_date:'2026-08-17',workers_dev:true,preview_urls:false,
    vars:{ENVIRONMENT:'staging',APNS_RUNTIME_ENABLED:'YES'},d1_databases:[{binding:'DB',database_id:'cb3b2386-3a6f-4253-b918-8aafed9ff735'}],
    services:[{binding:'PRIVATE_BILLING_GATEWAY',service:'neko-billing-gateway-staging-private',entrypoint:'BillingGateway',environment:'production'}],
    triggers:{crons:['* * * * *']},r2_buckets:[{binding:'MEDIA',bucket_name:'existing-private'}]};
  const {off,on}=groupStagingConfigs(baseline,'/source','/live/entry.js');
  const check=structuredClone(on);check.vars.GROUP_RUNTIME_ENABLED='NO';assert.deepEqual(check,off);
  for(const name of ['services','d1_databases','triggers','r2_buckets'])assert.deepEqual(off[name],baseline[name]);
  assert.equal(baseline.vars.GROUP_RUNTIME_ENABLED,undefined);
  assert.throws(()=>groupStagingConfigs({...baseline,vars:{ENVIRONMENT:'production'}},'/source','/live'));
  assert.throws(()=>groupStagingConfigs({...baseline,services:[]},'/source','/live'));
});

test('real workerd preserves downloaded legacy and rejects unauthenticated group requests',{timeout:30000},async()=>{
  const legacyPath=process.env.GROUP_STAGING_LEGACY_MODULE || fileURLToPath(new URL('./family-entry.mjs',import.meta.url));
  const bundle=await build({entryPoints:[fileURLToPath(new URL('./group-staging-entry.mjs',import.meta.url))],alias:{'group-staging-legacy':resolve(legacyPath)},
    bundle:true,format:'esm',platform:'neutral',target:'es2022',external:['cloudflare:workers'],write:false});
  const options={modules:true,script:bundle.outputFiles[0].text,compatibilityDate:'2026-08-17',
    d1Databases:{DB:'group-staging-runtime'},serviceBindings:{PRIVATE_BILLING_GATEWAY:'private-gateway'},
    ratelimits:{MEMBER_RATE_LIMITER:{namespace_id:'710003',simple:{limit:120,period:60}}}};
  const mf=new Miniflare(convertV4MiniflareOptions({cf:false,workers:[
    {name:'front',modules:true,compatibilityDate:'2026-08-17',
      script:`export default {fetch(r,e){const u=new URL(r.url),off=u.pathname.startsWith('/off/');u.pathname=u.pathname.slice(off?4:3);return (off?e.OFF:e.ON).fetch(new Request(u,r));}}`,
      serviceBindings:{OFF:'off',ON:'on'}},
    ...['off','on'].map(name=>({...options,name,bindings:{ENVIRONMENT:'staging',GROUP_RUNTIME_ENABLED:name==='on'?'YES':'NO',MOMENT_RUNTIME_ENABLED:'YES'}})),
    {name:'private-gateway',modules:true,compatibilityDate:'2026-08-17',
      script:`export default {async fetch(r){return new Response(await r.text(),{status:202,headers:{'x-private-only':'yes'}})}}`},
  ]}));
  try{
    const db=await mf.getD1Database('DB','on');
    await db.exec('CREATE TABLE personal_staging_runtime_gate(singleton INTEGER PRIMARY KEY,generation INTEGER,media_enabled INTEGER,apns_enabled INTEGER,report_ingestion_enabled INTEGER); INSERT INTO personal_staging_runtime_gate VALUES(1,6,1,1,1)');
    const response=await mf.dispatchFetch('https://local/on/v3/group-windows/list');
    assert.equal(response.status,401);assert.equal((await response.json()).error.code,'invalid_authentication');
    const disabled=await mf.dispatchFetch('https://local/off/v3/group-windows/list');
    assert.equal(disabled.status,503);assert.equal((await disabled.json()).error.code,'group_runtime_disabled');
    for(const mode of ['off','on']) {
      const report=await mf.dispatchFetch(`https://local/${mode}/v2/reports/responses`);
      assert.equal(report.status,401);assert.equal((await report.json()).error.code,'invalid_authentication');
      const billing=await mf.dispatchFetch(`https://local/${mode}/v1/billing/transactions`,{method:'POST',body:'exact signed bytes'});
      assert.equal(billing.status,202);assert.equal(await billing.text(),'exact signed bytes');assert.equal(billing.headers.get('x-private-only'),'yes');
      const unknown=await mf.dispatchFetch(`https://local/${mode}/not-found`);assert.equal(unknown.status,404);
    }
  }finally{await mf.dispose();}
});
