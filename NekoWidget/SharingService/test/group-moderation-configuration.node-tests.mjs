import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {build} from 'esbuild';
import {validateStagingOwnerConfig} from '../scripts/moderation-operator-staging-start.mjs';

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

test('the emitted operator page contains executable JavaScript and a restricted document policy',async()=>{
 const result=await build({entryPoints:[path.resolve(import.meta.dirname,'../src/group-moderation-console.ts')],bundle:true,format:'esm',platform:'node',write:false});
 const module=await import('data:text/javascript;base64,'+Buffer.from(result.outputFiles[0].text).toString('base64'));
 const response=module.groupModerationConsole(),html=await response.text(),scripts=[...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/gu)];
 assert.equal(scripts.length,1);assert.doesNotThrow(()=>new Function(scripts[0][1]));
 assert.equal(response.headers.get('Cache-Control'),'no-store');
 assert.match(response.headers.get('Content-Security-Policy'),/connect-src 'self'; frame-ancestors 'none'/u);
 assert.doesNotMatch(html,/https:\/\/|data:image|privateKeyBytes|objectKey/u);
});
