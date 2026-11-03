import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync,mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {assertModerationAIDisconnected} from '../scripts/moderation-ai-boundary-lib.mjs';

test('actual Worker entrypoint cannot reach the disconnected moderation AI source',()=>{
  assert.ok(assertModerationAIDisconnected(resolve(dirname(fileURLToPath(import.meta.url)),'..'))>0);
});
function fixture(t,files) {
  const root=mkdtempSync(join(tmpdir(),'neko-ai-boundary-'));
  t.after(()=>rmSync(root,{recursive:true,force:true}));
  for(const [path,source] of Object.entries(files)){mkdirSync(dirname(join(root,path)),{recursive:true});writeFileSync(join(root,path),source);}
  return root;
}
test('allows disconnected AI files, comments and local cycles',t=>{
  const root=fixture(t,{'index.ts':"import './safe'; // import './moderation-ai-transport'",'safe.ts':"import './index';",'moderation-ai-transport.ts':'export const unused=true;'});
  assert.equal(assertModerationAIDisconnected(root,'index.ts'),2);
});
for(const [name,entry,middle] of [
  ['direct',"import './moderation-ai-transport';",''],
  ['transitive export',"import './bridge';","export * from './moderation-ai-transport';"],
  ['lazy import',"import './bridge';","export const load=()=>import('./moderation-ai-transport');"],
  ['require',"import './bridge';","const ai=require('./moderation-ai-transport');"],
  ['type import',"import type {AI} from './moderation-ai-transport';",''],
])test('rejects '+name+' reachability',t=>{
  const root=fixture(t,{'index.ts':entry,'bridge.ts':middle,'moderation-ai-transport.ts':'export type AI = string;'});
  assert.throws(()=>assertModerationAIDisconnected(root,'index.ts'),/Moderation AI reachable/);
});
test('resolves tsconfig aliases rather than treating them as external packages',t=>{
  const root=fixture(t,{'tsconfig.json':JSON.stringify({compilerOptions:{baseUrl:'.',paths:{'@app/*':['src/*']}}}),
    'src/index.ts':"import '@app/bridge';",'src/bridge.ts':"export * from './moderation-ai-advisory';",'src/moderation-ai-advisory.ts':'export const ai=1;'});
  assert.throws(()=>assertModerationAIDisconnected(root),/Moderation AI reachable/);
});
test('does not turn an unresolvable dynamic import into a successful check',t=>{
  const root=fixture(t,{'index.ts':"const selected='moderation-ai-transport'; import('./'+selected);"});
  assert.throws(()=>assertModerationAIDisconnected(root,'index.ts'),/Unresolved dynamic module/);
});
