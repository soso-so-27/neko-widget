import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';

test('production stage 3 configuration remains closed before every business dependency', async () => {
  const config=JSON.parse(await readFile(new URL('../wrangler.production-closed.jsonc',import.meta.url),'utf8'));
  assert.equal(config.name,'neko-window-sharing-production');
  assert.equal(config.vars.ENVIRONMENT,'production');
  assert.equal(config.workers_dev,false); assert.equal(config.preview_urls,false);
  assert.deepEqual(config.triggers.crons,[]);
  assert.equal(config.d1_databases[0].database_id,'f0622d76-41d5-4af2-87c4-54f0ebc4015f');
  assert.deepEqual(config.r2_buckets,[
    {binding:'MEDIA',bucket_name:'neko-window-sharing-production-media-private'},
    {binding:'MODERATION_MEDIA',bucket_name:'neko-window-sharing-production-moderation-private'},
  ]);
  assert.equal(config.vars.FAMILY_NOTEBOOK_MAX_MEMBERS,'6');
  for(const [name,value] of Object.entries(config.vars)) if(name.endsWith('_ENABLED')) assert.equal(value,'NO',name);
  assert.equal(config.vars.INTAKE_ENABLED,'NO');
  assert.equal(new Set(config.ratelimits.map(r=>r.namespace_id)).size,3);
  assert.deepEqual(config.ratelimits.map(r=>[r.name,r.simple.limit,r.simple.period]),[
    ['CREATE_RATE_LIMITER',5,60],['INVITE_RATE_LIMITER',10,60],['MEMBER_RATE_LIMITER',120,60],
  ]);
  assert.ok(!JSON.stringify(config).includes('staging'));
  const compiled=await build({entryPoints:[fileURLToPath(new URL('../src/index.ts',import.meta.url))],bundle:true,
    format:'esm',platform:'neutral',target:'es2022',write:false});
  const worker=(await import('data:text/javascript;base64,'+Buffer.from(compiled.outputFiles[0].text).toString('base64'))).default;
  let calls=0;
  const env=new Proxy(config.vars,{get:(o,k)=>{if(k in o)return o[k];calls++;throw Error('Unexpected business dependency '+String(k));}});
  const ctx={waitUntil(){calls++;throw Error('Unexpected background task');}};
  for(const path of ['/v3/group-identities','/v3/group-windows','/v3/family-notebooks',
    '/v3/group-identities/deletion-requests','/v1/spaces','/operator/v1/reports','/v1/billing/transactions','/v1/billing/apple-notifications']){
    const request=new Request('https://local.invalid'+path,{method:'POST',body:'{}'});
    const r=await worker.fetch(request,env,ctx);
    assert.equal(r.status,503,path); assert.equal(await r.text(),''); assert.equal(request.bodyUsed,false);
  }
  for(const cron of ['* * * * *','*/5 * * * *','2,7,12,17,22,27,32,37,42,47,52,57 * * * *']) await worker.scheduled({cron},env,ctx);
  assert.equal(calls,0);
});
