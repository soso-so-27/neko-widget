import test from 'node:test';
import assert from 'node:assert/strict';
import {checkPlan} from './asc-metadata-apply.mjs';
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
