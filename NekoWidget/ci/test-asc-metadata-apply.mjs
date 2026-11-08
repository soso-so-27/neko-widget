import test from 'node:test';
import assert from 'node:assert/strict';
import {checkPlan} from './asc-metadata-apply.mjs';
const allowed=[{scope:'app-info',locale:'ja',field:'subtitle',value:'approved'}];
const change={scope:'app-info',locale:'ja',field:'subtitle',to:'approved'};
test('only the exact approved field, locale and value can be applied',()=>{
  assert.equal(checkPlan({dryRun:true,adds:[],updates:[change],deletes:[]},allowed).length,1);
  for(const c of [{...change,locale:'en-US'},{...change,field:'name'},{...change,to:'different'}])assert.throws(()=>checkPlan({dryRun:true,adds:[c],updates:[],deletes:[]},allowed));
  assert.throws(()=>checkPlan({dryRun:true,adds:[],updates:[],deletes:[change]},allowed));
  assert.throws(()=>checkPlan({dryRun:false,adds:[],updates:[]},allowed));
});
