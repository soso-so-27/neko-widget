import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createFamilyResponseRouter } from './family-response-router.mjs';

test('only exact GET reply reads enter the existing signed reader', async () => {
  for (const path of ['/v2/reports/responses','/v2/reports/responses/invalid-cursor']) {
    const request=new Request('https://sharing.test'+path),env={};
    const response=new Response('signed reader response',{status:401});
    const family={fetch(){assert.fail('reply read fell through')}};
    const reader=(r,e)=>{assert.equal(r,request);assert.equal(e,env);return response};
    assert.equal(await createFamilyResponseRouter(family,reader).fetch(request,env,{}),response);
  }
});

test('all other paths and methods preserve exact request, environment and context', async () => {
  for (const [method,path] of [['GET','/v2/reports/responses/'],['GET','/v2/reports/responses/a/b'],
    ['GET','/v2/reports/responses-other'],['GET','/v2/REPORTS/responses'],['POST','/v2/reports/responses'],
    ['GET','/v1/billing/health'],['POST','/v2/reports/reservations'],['GET','/health']]) {
    const request=new Request('https://sharing.test'+path,{method,...(method==='POST'?{body:'original signed bytes'}:{})});
    const env={},ctx={},response=new Response('deployed response');
    const family={async fetch(r,e,c){assert.equal(r,request);assert.equal(e,env);assert.equal(c,ctx);
      if(method==='POST')assert.equal(await r.text(),'original signed bytes');return response}};
    const reader=()=>assert.fail('another route entered the reply reader');
    assert.equal(await createFamilyResponseRouter(family,reader).fetch(request,env,ctx),response);
  }
});

test('scheduled callbacks retain the deployed family receiver',()=>{
  const controller={},env={},ctx={},result={};
  const family={scheduled(c,e,x){assert.equal(c,controller);assert.equal(e,env);assert.equal(x,ctx);return result}};
  assert.equal(createFamilyResponseRouter(family,()=>assert.fail()).scheduled(controller,env,ctx),result);
});
