import {readFile,writeFile,mkdir} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {build} from 'esbuild';
import {getPlatformProxy} from 'wrangler';
import {validateLocalOperatorConfig} from './moderation-operator-local-start.mjs';
import {createOwnerR2Transport,verifyWindowsKeyCustody} from './moderation-owner-r2-transport.mjs';
import {createGroupOwnerR2Transport} from './group-moderation-r2-transport.mjs';
import {startLoopbackOperatorServer} from './moderation-operator-local-server.mjs';
process.env.WRANGLER_LOG='none';process.env.WRANGLER_SEND_METRICS='false';
const service=path.resolve(import.meta.dirname,'..'),repo=path.resolve(service,'../..');
const fail=()=>{throw Error('invalid_staging_owner_config')};
const exact=(o,keys)=>{if(!o||Object.getPrototypeOf(o)!==Object.prototype||Reflect.ownKeys(o).length!==keys.length||keys.some(k=>!Object.hasOwn(o,k)))fail()};
const inside=(root,p)=>{const r=path.relative(root,p);return r===''||r==='..'||r.startsWith('..'+path.sep)?r==='':!path.isAbsolute(r)};
export const productionOwnerScope=Object.freeze({
 accountID:'829a34ef925a39d81b0e9e08800d7c7f',databaseID:'f0622d76-41d5-4af2-87c4-54f0ebc4015f',
 serviceIdentity:'neko-window-sharing-production',reportBucket:'neko-window-sharing-production-moderation-private',
 accessIssuer:'https://shrill-wind-26d2.cloudflareaccess.com',
 accessAudience:'fe39782502a92dcd9a7c716dc5b0940a5cd64aaefcff26130fc4bfd2a4079b74',
 origin:'https://operator.nekonomado.com',rpId:'operator.nekonomado.com',
});
export function validateStagingOwnerConfig(value){
 exact(value,['schemaVersion','mode','localConfigurationFile','runtimeDirectory','port','scope','keyDirectory','pipeName','caseHmacKeyFile','brokerRecordFile','verificationCaseReferences',...(value?.schemaVersion===2?['groupModerationEnabled']:[])]);
 if(![1,2].includes(value.schemaVersion)||(value.schemaVersion===2&&typeof value.groupModerationEnabled!=='boolean')||!['owner-staging','owner-production'].includes(value.mode)||!Number.isInteger(value.port)||value.port<1||value.port>65535
  ||!/^neko-owner-key-check-[0-9a-f-]{36}$/u.test(value.pipeName))fail();
 if(!Array.isArray(value.verificationCaseReferences)||value.verificationCaseReferences.length>1||value.verificationCaseReferences.some(v=>!/^[0-9a-f]{64}$/u.test(v)))fail();
 for(const name of ['localConfigurationFile','runtimeDirectory','keyDirectory','caseHmacKeyFile','brokerRecordFile'])if(!path.isAbsolute(value[name]))fail();
 if(inside(repo,path.resolve(value.runtimeDirectory)))fail();
 exact(value.scope,['accountID','databaseID','serviceIdentity','reportBucket','accessIssuer','accessAudience','origin','rpId','moderationKeyId','publicKeySHA256']);
 if(!/^[0-9a-f]{32}$/u.test(value.scope.accountID)||!/^[0-9a-f-]{36}$/u.test(value.scope.databaseID)
  ||!/^[a-z0-9-]{1,63}$/u.test(value.scope.serviceIdentity)||!/^[a-z0-9-]{3,63}$/u.test(value.scope.reportBucket)
  ||value.scope.moderationKeyId!=='moderation-v2'||!/^[0-9a-f]{64}$/u.test(value.scope.publicKeySHA256))fail();
 if(value.mode==='owner-production'){
  if(value.schemaVersion!==2||Object.entries(productionOwnerScope).some(([key,expected])=>value.scope[key]!==expected))fail();
 }else if(['databaseID','serviceIdentity','reportBucket','accessAudience','origin','rpId'].some(key=>value.scope[key]===productionOwnerScope[key]))fail();
 return structuredClone(value);
}
export async function openStagingOwnerBindings(config){
 config=validateStagingOwnerConfig(config);
 const generated={name:'neko-operator-report-bridge',account_id:config.scope.accountID,compatibility_date:'2026-08-17',workers_dev:false,preview_urls:false,
  d1_databases:[{binding:'REPORT_DB',database_name:config.scope.serviceIdentity,database_id:config.scope.databaseID,remote:true}],
  r2_buckets:[{binding:'REPORT_MEDIA',bucket_name:config.scope.reportBucket,remote:true}]};
 await mkdir(config.runtimeDirectory,{recursive:true});
 const file=path.join(config.runtimeDirectory,`wrangler.${config.mode}.json`),empty=path.join(config.runtimeDirectory,`${config.mode}.vars.empty`);
 // No inherited credentials, .dev.vars, extra buckets, services, routes or cron.
 for(const key of Object.keys(process.env))if(/^(?:CLOUDFLARE_|CF_|AWS_)/u.test(key))delete process.env[key];
 await writeFile(file,JSON.stringify(generated));await writeFile(empty,'');
 const proxy=await getPlatformProxy({configPath:file,envFiles:[empty],persist:false,remoteBindings:true});
 if(Object.keys(proxy.env).sort().join(',')!=='REPORT_DB,REPORT_MEDIA'){await proxy.dispose();fail()}
 return proxy;
}
export async function main(args,expectedMode){
 if(args.length!==3||args[0]!=='--config'||!path.isAbsolute(args[1])||!['--check','--serve'].includes(args[2]))fail();
 const config=validateStagingOwnerConfig(JSON.parse(await readFile(args[1],'utf8')));
 if(expectedMode!==undefined&&config.mode!==expectedMode)fail();
 const original=validateLocalOperatorConfig(JSON.parse(await readFile(config.localConfigurationFile,'utf8')));
 if(config.scope.origin!==original.origin||config.scope.rpId!==original.rpId||config.scope.accessIssuer!==original.access.issuer
  ||config.scope.accessAudience!==original.access.audience||config.scope.databaseID===original.enrollment.scope.databaseID)fail();
 const proxy=await openStagingOwnerBindings(config);let server,subjectKey,caseKey;
 try{
  const bundle=await build({entryPoints:[path.join(service,'src/moderation-operator-host-local.ts'),path.join(service,'src/moderation-owner-scope-adoption.ts'),
   path.join(service,'src/moderation-operator-auth.ts'),path.join(service,'src/moderation-operator-identity.ts'),path.join(service,'src/moderation-operator-case-reference.ts')],
   bundle:true,platform:'node',format:'esm',write:false,outdir:'bundle',outExtension:{'.js':'.mjs'}});
  for(const f of bundle.outputFiles)await writeFile(path.join(config.runtimeDirectory,path.basename(f.path)),f.contents);
  const module=async name=>import(pathToFileURL(path.join(config.runtimeDirectory,name+'.mjs')).href+'?v='+Date.now());
  const {readOwnerScopeAdoption}=await module('moderation-owner-scope-adoption');
  const {createLocalModerationOperatorHost}=await module('moderation-operator-host-local');
  const {authenticateCloudflareAccessRequest,ModerationAccessJwksCache}=await module('moderation-operator-auth');
  const {actorSQL,guard,admitSession}=await module('moderation-operator-identity');
  const {deriveModerationOperatorCaseReference}=await module('moderation-operator-case-reference');
  const db=proxy.env.REPORT_DB,assertScope=()=>readOwnerScopeAdoption(db,config.scope,original.enrollment.authorities);
  const adoption=await assertScope();
  if(adoption.transcript.source.operatorID!==original.enrollment.operatorID||adoption.transcript.source.subjectHmacKeyVersion!==original.access.subjectHmacKeyVersion)fail();
  // A genuine current custody proof before the HTTP listener starts. No cache.
  await verifyWindowsKeyCustody({pipeName:config.pipeName,publicKeySHA256:config.scope.publicKeySHA256,keyDirectory:config.keyDirectory,brokerRecordFile:config.brokerRecordFile},AbortSignal.timeout(20000));
  subjectKey=new Uint8Array(await readFile(original.access.subjectHmacKeyFile));caseKey=new Uint8Array(await readFile(config.caseHmacKeyFile));
  if(subjectKey.length!==32||caseKey.length!==32)fail();
  const access={issuer:original.access.issuer,audience:original.access.audience,subjectHmacKey:subjectKey,subjectHmacKeyVersion:original.access.subjectHmacKeyVersion,cache:new ModerationAccessJwksCache()};
  // Local stderr gets only fixed phase names and elapsed time. No credential,
  // case identity, source, key, picture or exception text is logged.
  const onReviewFailure=event=>console.error(JSON.stringify(event));
  const localHost=createLocalModerationOperatorHost({environment:'local',runtimeEnabled:'YES',db,origin:original.origin,rpId:original.rpId,access,
   ...(config.groupModerationEnabled===true?{group:{runtimeEnabled:'YES',caseHmacKey:caseKey,
    reviewEvidence:createGroupOwnerR2Transport({bucket:proxy.env.REPORT_MEDIA,keyDirectory:config.keyDirectory,publicKeySHA256:config.scope.publicKeySHA256,pipeName:config.pipeName,brokerRecordFile:config.brokerRecordFile,assertScope,onReviewFailure})}}:{}),
   enrollment:{...original.enrollment,scope:{accountID:config.scope.accountID,databaseID:config.scope.databaseID,serviceIdentity:config.scope.serviceIdentity,
    accessIssuer:access.issuer,accessAudience:access.audience,expectedOrigin:original.origin,expectedRPID:original.rpId}},
   syntheticCaseReferences:config.verificationCaseReferences,
   reviewEvidence:createOwnerR2Transport({bucket:proxy.env.REPORT_MEDIA,keyDirectory:config.keyDirectory,publicKeySHA256:config.scope.publicKeySHA256,pipeName:config.pipeName,brokerRecordFile:config.brokerRecordFile,assertScope,onReviewFailure})});
  const unavailable=()=>new Response(JSON.stringify({error:config.mode==='owner-production'?'owner_production_unavailable':'owner_staging_unavailable'}),{status:503,headers:{'Cache-Control':'no-store','Content-Type':'application/json'}});
  const handler=async request=>{
   try{
    await assertScope();const url=new URL(request.url);
    // Scope adoption reuses a reviewed existing key. Public registration cannot
    // create a second credential or silently change this fixed installation.
    if(url.pathname==='/operator/enrollment'||url.pathname.startsWith('/operator/v1/enrollment/'))return new Response(null,{status:303,headers:{Location:'/operator/console','Cache-Control':'no-store'}});
    const identity=await authenticateCloudflareAccessRequest(request,access);
    const actor=await db.prepare(actorSQL).bind(identity.operatorSubjectHmac,identity.subjectHmacKeyVersion).first();
    if(!actor||actor.operator_id!==original.enrollment.operatorID)return new Response(null,{status:403});
    await db.batch([guard(db,identity,actor),admitSession(db,identity,actor)]);
    if(url.pathname.startsWith('/operator/v1/cases/read')){
     const rows=await db.prepare(`SELECT m.report_id FROM moderation_cases m JOIN moment_reports r ON r.id=m.report_id
      JOIN moment_report_tombstones t ON t.report_id=r.id WHERE r.state='committed' AND r.closed_at IS NULL
      AND r.content_expires_at>unixepoch() AND t.content_deleted_at IS NULL
      AND NOT EXISTS(SELECT 1 FROM moderation_operator_versioned_case_references c WHERE c.report_id=r.id)
      AND NOT EXISTS(SELECT 1 FROM moment_object_deletions d WHERE d.object_key=r.object_key OR (d.object_type='report' AND d.owner_id=r.id)) LIMIT 50`).all();
     for(const row of rows.results){
      const reference=await deriveModerationOperatorCaseReference({reportId:row.report_id,caseReferenceHmacKeyVersion:1},caseKey);
      await db.batch([guard(db,identity,actor),db.prepare(`INSERT INTO moderation_operator_versioned_case_references(report_id,case_reference_hmac,case_reference_hmac_key_version,derivation_protocol_version,derivation_domain)
       SELECT ?,?,1,1,'NW.MODERATION-OPERATOR.CASE-REFERENCE' WHERE EXISTS(SELECT 1 FROM moment_reports r JOIN moment_report_tombstones t ON t.report_id=r.id
        WHERE r.id=? AND r.state='committed' AND r.closed_at IS NULL AND r.content_expires_at>unixepoch() AND t.content_deleted_at IS NULL)
       AND NOT EXISTS(SELECT 1 FROM moderation_operator_versioned_case_references WHERE report_id=?)`).bind(row.report_id,reference.caseReferenceHmac,row.report_id,row.report_id)]);
     }
    }
    const response=await localHost(request);await assertScope();return response;
   }catch{return unavailable()}
  };
  const ready={remoteBindings:true,evidenceMode:config.mode+'-r2',ownerReviewConfigured:true,scopeVerified:true,operatorGrantsCreated:false,liveOperationVerified:false};
  if(args[2]==='--check'){console.log(JSON.stringify({configurationValid:true,...ready}));return}
  // Native storage custody measured ~9s per check, twice per disclosure, plus
  // current D1 guards. Preserve the owner handler's finite 60s disclosure bound.
  server=await startLoopbackOperatorServer({origin:original.origin,port:config.port,requestTimeoutMilliseconds:60000,handler,authenticate:request=>authenticateCloudflareAccessRequest(request,access),ready});
  console.log(JSON.stringify({listening:`http://127.0.0.1:${server.port}`,browserURL:original.origin+'/operator/console',...ready}));
  await new Promise(resolve=>{process.once('SIGINT',resolve);process.once('SIGTERM',resolve)});
 }finally{if(server)await server.close();subjectKey?.fill(0);caseKey?.fill(0);await proxy.dispose()}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main(process.argv.slice(2)).catch(()=>{console.error('owner_staging_startup_failed');process.exitCode=1});
