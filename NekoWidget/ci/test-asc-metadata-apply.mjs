import test from 'node:test';
import assert from 'node:assert/strict';
import {checkPlan,errorDetails,runGroups} from './asc-metadata-apply.mjs';
import {readFileSync} from 'node:fs';
const allowed=[{scope:'app-info',locale:'ja',field:'subtitle',value:'approved'}];
const change={scope:'app-info',locale:'ja',field:'subtitle',to:'approved'};
test('only the exact approved field, locale and value can be applied',()=>{
  assert.equal(checkPlan({dryRun:true,adds:[],updates:[change],deletes:[]},allowed).length,1);
  for(const c of [{...change,locale:'en-US'},{...change,field:'name'},{...change,to:'different'}])assert.throws(()=>checkPlan({dryRun:true,adds:[c],updates:[],deletes:[]},allowed));
  assert.throws(()=>checkPlan({dryRun:true,adds:[],updates:[],deletes:[change]},allowed));
  assert.throws(()=>checkPlan({dryRun:false,adds:[],updates:[]},allowed));
});

test('write credential stays in the protected metadata workflow only',()=>{
  const workflow=readFileSync(new URL('../../.github/workflows/asc-metadata-1109d.yml',import.meta.url),'utf8');
  assert.match(workflow,/environment: asc-metadata/);
  assert.doesNotMatch(workflow,/environment: testflight|OWNER_INTERNAL_GROUP_ID/);
  assert.match(workflow,/asc-metadata-apply\.mjs --validate/);
  const readonly=readFileSync(new URL('../../.github/workflows/asc-readonly.yml',import.meta.url),'utf8');
  assert.match(readonly,/environment: testflight/);
  assert.doesNotMatch(readonly,/asc-metadata/);
  const implementation=readFileSync(new URL('./asc-metadata-apply.mjs',import.meta.url),'utf8');
  assert.doesNotMatch(implementation,/\['(?:submit|review)'/);
});

test('ordinary API failure continues while protected boundaries stop all groups',()=>{
  const visited=[];
  const actions=[['first',()=>{visited.push('first');throw Error('STOP_API');}],['second',()=>visited.push('second')]];
  assert.deepEqual(runGroups(actions,()=>{}),['first']);
  assert.deepEqual(visited,['first','second']);
  for(const code of ['STOP_PERMISSION','STOP_SCOPE','STOP_AGE_RATING','STOP_READBACK','STOP_IDENTITY']){
    let later=false;
    assert.throws(()=>runGroups([['first',()=>{throw Error(code)}],['second',()=>{later=true}]],()=>{}),new RegExp(code));
    assert.equal(later,false);
  }
});

test('Apple error details survive but keys, IDs and contacts do not',()=>{
  const details=errorDetails(JSON.stringify({actions:[{error:JSON.stringify({errors:[{code:'ENTITY_ERROR.ATTRIBUTE.INVALID',title:'Invalid attribute',detail:'whatsNew not allowed: secret-key 1234567890 owner@example.com'}]})}]}),'',['secret-key']);
  assert.equal(details[0].code,'ENTITY_ERROR.ATTRIBUTE.INVALID');
  assert.match(details[0].detail,/whatsNew not allowed/);
  for(const value of ['secret-key','1234567890','owner@example.com'])assert.ok(!JSON.stringify(details).includes(value));
  assert.doesNotMatch(JSON.stringify(errorDetails('', '-----BEGIN PRIVATE KEY----- hidden',[])),/hidden/);
});

test('first version never requests whatsNew',()=>{
  const input=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/version/1.0/ja.json',import.meta.url),'utf8'));
  assert.equal(Object.hasOwn(input,'whatsNew'),false);
  assert.deepEqual(Object.keys(input).sort(),['description','keywords','promotionalText','supportUrl']);
});
