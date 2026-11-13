import test from 'node:test';
import assert from 'node:assert/strict';
import {checkPlan,errorDetails,runGroups,permissionFailure,approvedDescriptionUpdate,approvedDailyPhotoAppDescription,dailyPlusDescriptionChange} from './asc-metadata-apply.mjs';

test('1111d permits only the daily-photo copy changes in the Japanese descriptions',()=>{
  const desired=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/version/1.0/ja.json',import.meta.url),'utf8')).description;
  const before=desired.replace('毎日ちがう 1 枚に入れ替わります。','')
    .replace('■ ねこのまど Plus\n','■ ねこのまど Plus\n・毎日、新しい 1 枚がホーム画面に\n');
  assert.notEqual(before,desired);
  assert.equal(approvedDailyPhotoAppDescription(before,desired),true);
  assert.equal(approvedDailyPhotoAppDescription(before+'\n別の追記',desired),false);
  assert.equal(approvedDailyPhotoAppDescription(before,desired.replace('980 円','990 円')),false);
  assert.equal(dailyPlusDescriptionChange('うちの子との毎日を続ける。まど・毎日の新しい 1 枚・まとめ'),
    '月の作品、まど、家族の手帳、メモ、保存');
  assert.equal(dailyPlusDescriptionChange('月の作品、まど、家族の手帳、メモ、保存'),null);
  assert.throws(()=>dailyPlusDescriptionChange('別の説明'),/STOP_SCOPE/u);
});
import {readFileSync} from 'node:fs';
test('1113d removes only the paid photo-memo bullet',()=>{
  const desired=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/version/1.0/ja.json',import.meta.url),'utf8')).description;
  const before=desired.replace('■ ねこのまど Plus\n','■ ねこのまど Plus\n・写真に新しいメモを書く\n');
  assert.notEqual(before,desired);
  assert.equal(approvedDescriptionUpdate(before,desired),true);
  assert.equal(approvedDescriptionUpdate(before,desired.replace('980 円','990 円')),false);
  assert.equal(approvedDescriptionUpdate(before+'\n別の追記',desired),false);
  assert.equal(approvedDescriptionUpdate(before.replace('・写真に新しいメモを書く\n','・写真に新しいメモを書く\n・写真に新しいメモを書く\n'),desired),false);
});
const allowed=[{scope:'app-info',locale:'ja',field:'subtitle',value:'approved'}];
const change={scope:'app-info',locale:'ja',field:'subtitle',to:'approved'};

test('1110b description allows only the two approved edits and preserves all other copy',()=>{
  const before='approved opening\n季節のムービーもあります。\napproved middle（3GB・記録 3,000 件まで）\napproved ending';
  const after=before.replace('季節のムービーもあります。','季節のムービーもあります。作品を開くのは Plus です（14 日間無料）。')
    .replace('（3GB・記録 3,000 件まで）','（3GB・記録 3,000 件まで。お試し中は 250MB）');
  assert.equal(approvedDescriptionUpdate(before,after),true);
  assert.equal(approvedDescriptionUpdate(after,after),true);
  assert.equal(approvedDescriptionUpdate(before,after.replace('approved ending','other ending')),false);
  assert.equal(approvedDescriptionUpdate(undefined,after),false);
  assert.equal(approvedDescriptionUpdate(before+before,after),false);
});
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
test('Apple permission error suffixes still stop every group without an HTTP code',()=>{
  for(const text of ['FORBIDDEN_ERROR','NOT_AUTHORIZED','AUTHENTICATION_ERROR','HTTP 403','UNAUTHORIZED_ERROR'])assert.equal(permissionFailure(text),true);
  assert.equal(permissionFailure('ENTITY_ERROR.ATTRIBUTE.INVALID whatsNew'),false);
});
