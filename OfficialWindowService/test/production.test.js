import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import worker from '../src/production.js';
import { BLACK_CAT_CREDIT } from '../src/black-cat-loop.js';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const first = Buffer.from('synthetic first image'), second = Buffer.from('synthetic second image');
const a = hash(first), b = hash(second), prefix = 'programs/' + 'a'.repeat(64);
const start = Date.parse('2026-11-03T15:00:00Z');
function setup() {
  const index = { schemaVersion: 4, credit: BLACK_CAT_CREDIT,
    images: [{sha256:a,width:1,height:1,caption:'一日目'}, {sha256:b,width:1,height:1,caption:'二日目'}],
    epochs:[{action:'create',startsAt:'2026-11-03T15:00:00Z',cycleStartsAt:'2026-11-03T15:00:00Z',order:[a,b]}] };
  const objects = new Map([[prefix+'/__program/index.json',Buffer.from(JSON.stringify(index))],
    [prefix+'/__program/images/'+a+'.jpg',first],[prefix+'/__program/images/'+b+'.jpg',second]]);
  const reads = [];
  const env = { ENVIRONMENT:'production', INTAKE_ENABLED:'YES', OFFICIAL_PROGRAM_PREFIX:prefix,
    OFFICIAL:{ async get(key) { reads.push(key); const data=objects.get(key);
      return data ? {size:data.length,body:new Response(data).body} : null; } } };
  return {env,reads,objects};
}
const request = (env,route='/windows/black-cats/catalog.json',method='GET') =>
  worker.fetch(new Request('https://official.invalid'+route,{method}),env);

test('328 channel-base compatibility serves the same validated feed and relative image without redirect', async t => {
  t.mock.method(Date,'now',()=>start); const f=setup();
  const oldBase='/windows/black-cats/windows/black-cats/';
  const canonical=await request(f.env), compatible=await request(f.env,oldBase+'catalog.json');
  assert.equal(compatible.status,200); assert.equal(compatible.headers.get('location'),null);
  assert.equal(await compatible.text(),await canonical.text());
  const photo=await request(f.env,oldBase+a+'.jpg');
  assert.equal(photo.status,200); assert.equal(hash(Buffer.from(await photo.arrayBuffer())),a);
  const head=await request(f.env,oldBase+a+'.jpg','HEAD');
  assert.equal(head.status,200); assert.equal(await head.text(),'');
  for(const route of [oldBase+'catalog.json?other=1',oldBase+'__program/index.json',
    oldBase+'windows/black-cats/catalog.json',oldBase+'f'.repeat(64)+'.jpg']) {
    assert.equal((await request(f.env,route)).status,404);
  }
  assert.equal((await request(f.env,oldBase+'catalog.json','POST')).status,405);
  const closed=setup(); closed.env.INTAKE_ENABLED='NO';
  assert.equal((await request(closed.env,oldBase+'catalog.json')).status,503);
  assert.deepEqual(closed.reads,[]);
});

test('gate and environment reject before any binding access, including HEAD and hidden URLs', async () => {
  for (const value of [undefined,'NO','yes',' YES','YES ',true,1]) {
    for (const method of ['GET','HEAD','POST']) {
      const f=setup(); f.env.INTAKE_ENABLED=value;
      const r=await request(f.env,'/__program/index.json',method);
      assert.equal(r.status,503); assert.equal(r.headers.get('cache-control'),'no-store');
      if(method==='HEAD') assert.equal(await r.text(),'');
      assert.deepEqual(f.reads,[]);
    }
  }
  for (const value of [undefined,'staging','Production']) {
    const f=setup(); f.env.ENVIRONMENT=value;
    assert.equal((await request(f.env)).status,503); assert.deepEqual(f.reads,[]);
  }
});

test('production uses reviewed prefix, switches at JST midnight and retains matching next-day caption', async t => {
  let now=start; t.mock.method(Date,'now',()=>now); const f=setup();
  const read=async()=>{const r=await request(f.env);assert.equal(r.status,200);return r.json();};
  const day1=await read(); assert.equal(day1.photos[0].sha256,a);
  assert.equal(day1.photos[0].catName,'のわ'); assert.equal(day1.photos[0].caption,'一日目');
  assert.equal(day1.photos[1].caption,'二日目');
  now=start+86400000-1; assert.equal((await read()).photos[0].sha256,a);
  now++; const day2=await read(); assert.deepEqual(day2.photos[0],day1.photos[1]);
  const image=await request(f.env,'/windows/black-cats/'+b+'.jpg');
  assert.equal(image.status,200);assert.equal(hash(Buffer.from(await image.arrayBuffer())),b);
  now+=86400000; assert.equal((await read()).photos[0].sha256,a);
  assert(f.reads.every(key=>key.startsWith(prefix+'/__program/')));
});

test('hidden routes and invalid prefix never read R2; missing, oversized and corrupt objects fail closed', async t => {
  t.mock.method(Date,'now',()=>start);
  for (const route of ['/__program/index.json','/schedule-review.json','/windows/black-cats/catalog.json?x=1']) {
    const f=setup(); assert.equal((await request(f.env,route)).status,404); assert.deepEqual(f.reads,[]);
  }
  for (const value of [undefined,'UNCONFIGURED','programs/../other','programs/'+'A'.repeat(64)]) {
    const f=setup();f.env.OFFICIAL_PROGRAM_PREFIX=value;
    assert.equal((await request(f.env)).status,503);assert.deepEqual(f.reads,[]);
  }
  const f=setup();f.objects.clear();assert.equal((await request(f.env)).status,503);
  f.env.OFFICIAL.get=async()=>({size:256*1024+1,body:new Response('x').body});
  assert.equal((await request(f.env)).status,503);
  const corrupt=setup();corrupt.objects.set(prefix+'/__program/images/'+a+'.jpg',second);
  assert.equal((await request(corrupt.env,'/windows/black-cats/'+a+'.jpg')).status,503);
});

test('committed production configuration is closed and only binds the production bucket', async () => {
  const config=JSON.parse(await readFile(new URL('../wrangler.production-closed.jsonc',import.meta.url)));
  assert.equal(config.name,'neko-official-cats-production');
  assert.deepEqual(config.vars,{ENVIRONMENT:'production',INTAKE_ENABLED:'NO',OFFICIAL_PROGRAM_PREFIX:'UNCONFIGURED'});
  assert.deepEqual(config.r2_buckets,[{binding:'OFFICIAL',bucket_name:'neko-official-cats-production-private'}]);
  assert.equal(config.workers_dev,false);assert.equal(config.preview_urls,false);
  assert.deepEqual(config.triggers.crons,[]);assert.equal(config.assets,undefined);
});
