import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {build} from 'esbuild';
import {validateStagingOwnerConfig,openStagingOwnerBindings,productionOwnerScope} from '../scripts/moderation-operator-staging-start.mjs';
import {validateProductionOwnerConfig} from '../scripts/moderation-operator-production-start.mjs';

const config=()=>({schemaVersion:1,mode:'owner-staging',localConfigurationFile:path.join(tmpdir(),'synthetic-local.json'),
 runtimeDirectory:path.join(tmpdir(),'synthetic-operator-runtime'),port:18799,keyDirectory:path.join(tmpdir(),'synthetic-keys'),
 pipeName:'neko-owner-key-check-10000000-0000-4000-8000-000000000001',caseHmacKeyFile:path.join(tmpdir(),'synthetic-case-key'),
 brokerRecordFile:path.join(tmpdir(),'synthetic-broker.json'),verificationCaseReferences:[],
 scope:{accountID:'1'.repeat(32),databaseID:'10000000-0000-4000-8000-000000000002',serviceIdentity:'synthetic-staging',
 reportBucket:'synthetic-moderation',accessIssuer:'https://synthetic.cloudflareaccess.com',accessAudience:'2'.repeat(64),
 origin:'https://synthetic.invalid',rpId:'synthetic.invalid',moderationKeyId:'moderation-v2',publicKeySHA256:'3'.repeat(64)}});

test('existing startup configuration never implicitly enables group operations',()=>{
 assert.equal(validateStagingOwnerConfig(config()).groupModerationEnabled,undefined);
 assert.throws(()=>validateStagingOwnerConfig({...config(),groupModerationEnabled:true}));
 for(const enabled of [false,true])assert.equal(validateStagingOwnerConfig({...config(),schemaVersion:2,groupModerationEnabled:enabled}).groupModerationEnabled,enabled);
 for(const enabled of ['YES',1,null,undefined])assert.throws(()=>validateStagingOwnerConfig({...config(),schemaVersion:2,groupModerationEnabled:enabled}));
 assert.throws(()=>validateStagingOwnerConfig({...config(),schemaVersion:3,groupModerationEnabled:true}));
});

test('production requires its exact database, bucket, Access audience and origin; staging cannot target them',async()=>{
 const production=()=>({...config(),schemaVersion:2,mode:'owner-production',groupModerationEnabled:true,scope:{...config().scope,...productionOwnerScope}});
 assert.equal(validateProductionOwnerConfig(production()).mode,'owner-production');
 assert.throws(()=>validateProductionOwnerConfig(config()));
 assert.throws(()=>validateProductionOwnerConfig({...production(),schemaVersion:1}));
 for(const field of Object.keys(productionOwnerScope)){
  const c=production();c.scope[field]=config().scope[field];
  assert.throws(()=>validateProductionOwnerConfig(c),field);
  await assert.rejects(openStagingOwnerBindings(c),undefined,field+' fails before opening remote bindings');
 }
 for(const field of ['databaseID','serviceIdentity','reportBucket','accessAudience','origin','rpId']){
  const c=config();c.scope[field]=productionOwnerScope[field];assert.throws(()=>validateStagingOwnerConfig(c),field);
 }
});

test('the emitted operator page contains executable JavaScript and a restricted document policy',async()=>{
 const result=await build({entryPoints:[path.resolve(import.meta.dirname,'../src/group-moderation-console.ts')],bundle:true,format:'esm',platform:'node',write:false});
 const module=await import('data:text/javascript;base64,'+Buffer.from(result.outputFiles[0].text).toString('base64'));
 const response=module.groupModerationConsole(),html=await response.text(),scripts=[...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/gu)];
 assert.equal(scripts.length,1);assert.doesNotThrow(()=>new Function(scripts[0][1]));
 assert.equal(response.headers.get('Cache-Control'),'no-store');
 assert.match(response.headers.get('Content-Security-Policy'),/connect-src 'self'; frame-ancestors 'none'/u);
 assert.doesNotMatch(html,/https:\/\/|data:image|privateKeyBytes|objectKey/u);
});
