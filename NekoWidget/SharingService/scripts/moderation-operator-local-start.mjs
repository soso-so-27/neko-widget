import {readFile,writeFile,mkdir,readdir,realpath} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {promisify} from 'node:util';
import {execFile} from 'node:child_process';
import {createHash} from 'node:crypto';
import {build} from 'esbuild';
import {getPlatformProxy} from 'wrangler';
import {startLoopbackOperatorServer} from './moderation-operator-local-server.mjs';

// This dedicated local process emits only the safe JSON status below.
process.env.WRANGLER_LOG='none';

const service=path.resolve(import.meta.dirname,'..');
const repo=path.resolve(service,'../..');
const run=promisify(execFile);
const invalid=() => {throw Error('invalid_local_operator_config');};
const exact=(o,keys) => {if (!o || typeof o !== 'object' || Array.isArray(o) || Object.keys(o).length !== keys.length || keys.some(k=>!Object.hasOwn(o,k))) invalid();};
const text=(s,pattern) => {if (typeof s!=='string' || !pattern.test(s)) invalid();return s;};
const integer=(n,max=2147483647) => {if(!Number.isSafeInteger(n)||n<1||n>max) invalid();return n;};
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const hex=/^[0-9a-f]{64}$/u;
const inside=(root,p)=>{const relative=path.relative(root,p);return relative===''||(!relative.startsWith('..'+path.sep)&&relative!=='..'&&!path.isAbsolute(relative));};

/** Configuration is local trusted administration, never a browser input.
 * No token, role creation, authority private key, remote DB or deployment option. */
export function validateLocalOperatorConfig(value) {
  exact(value,['schemaVersion','mode','origin','rpId','port','runtimeDirectory','access','enrollment']);
  if(value.schemaVersion!==1||value.mode!=='local') invalid();
  const origin=new URL(value.origin);
  if(origin.protocol!=='https:'||origin.origin!==value.origin||origin.hostname!==value.rpId||origin.username||origin.password) invalid();
  integer(value.port,65535);
  if(!path.isAbsolute(value.runtimeDirectory)||inside(repo,path.resolve(value.runtimeDirectory))) invalid();
  exact(value.access,['issuer','audience','subjectHmacKeyFile','subjectHmacKeyVersion']);
  text(value.access.issuer,/^https:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.cloudflareaccess\.com$/u);
  text(value.access.audience,hex);integer(value.access.subjectHmacKeyVersion);
  if(!path.isAbsolute(value.access.subjectHmacKeyFile)) invalid();
  exact(value.enrollment,['operatorID','scope','activeRoles','authorities']);
  text(value.enrollment.operatorID,uuid);
  const s=value.enrollment.scope;
  exact(s,['accountID','databaseID','serviceIdentity','accessIssuer','accessAudience','expectedOrigin','expectedRPID']);
  text(s.accountID,/^[0-9a-f]{32}$/u);text(s.databaseID,uuid);text(s.serviceIdentity,/^[a-z0-9][a-z0-9-]{0,62}$/u);
  if(s.accessIssuer!==value.access.issuer||s.accessAudience!==value.access.audience||s.expectedOrigin!==value.origin||s.expectedRPID!==value.rpId) invalid();
  const roles=value.enrollment.activeRoles;
  if(!Array.isArray(roles)||!roles.length||new Set(roles).size!==roles.length||roles.some(r=>!['triage','evidence_reviewer','privacy_approver','auditor','security_admin'].includes(r))) invalid();
  const authorities=value.enrollment.authorities;
  if(!Array.isArray(authorities)||authorities.length!==2) invalid();
  for(const a of authorities){
    exact(a,['keyID','revision','publicKeyBase64url','publicKeyFingerprintSHA256','authorizedAt']);
    text(a.keyID,/^[A-Za-z0-9._-]{8,64}$/u);integer(a.revision);integer(a.authorizedAt);
    text(a.publicKeyBase64url,/^[A-Za-z0-9_-]{43}$/u);text(a.publicKeyFingerprintSHA256,hex);
    const publicKey=Buffer.from(a.publicKeyBase64url,'base64url');
    if(publicKey.length!==32||publicKey.toString('base64url')!==a.publicKeyBase64url||createHash('sha256').update(publicKey).digest('hex')!==a.publicKeyFingerprintSHA256) invalid();
  }
  if(authorities[0].keyID===authorities[1].keyID||authorities[0].publicKeyBase64url===authorities[1].publicKeyBase64url) invalid();
  return structuredClone(value);
}

async function initialize(config,configPath) {
  // One fresh local installation only; existing data is never overwritten or migrated here.
  await mkdir(config.runtimeDirectory,{recursive:true});
  if((await readdir(config.runtimeDirectory)).length) throw Error('local_runtime_directory_not_empty');
  if(inside(repo,await realpath(config.runtimeDirectory))) invalid();
  const wranglerPath=path.join(config.runtimeDirectory,'wrangler.local.json');
  const manifest={schemaVersion:1,databaseID:config.enrollment.scope.databaseID,configPath:path.resolve(configPath)};
  await writeFile(path.join(config.runtimeDirectory,'installation.json'),JSON.stringify(manifest,null,2),{flag:'wx'});
  await writeFile(path.join(config.runtimeDirectory,'vars.empty'),'',{flag:'wx'});
  await writeFile(wranglerPath,JSON.stringify({name:'neko-operator-local',compatibility_date:'2026-08-17',workers_dev:false,preview_urls:false,
    d1_databases:[{binding:'DB',database_name:'neko-operator-local',database_id:manifest.databaseID,remote:false,migrations_dir:path.join(service,'migrations')}]}));
  const processEnv={...process.env,WRANGLER_SEND_METRICS:'false'};
  for(const name of Object.keys(processEnv)) if(/^(?:CLOUDFLARE_|CF_|AWS_)/u.test(name)) delete processEnv[name];
  await run(process.execPath,[path.join(service,'node_modules/wrangler/bin/wrangler.js'),'d1','migrations','apply','neko-operator-local',
    '--local','--config',wranglerPath,'--persist-to',path.join(config.runtimeDirectory,'state')],
    {cwd:config.runtimeDirectory,env:processEnv,timeout:60000,maxBuffer:1048576});
  // CLI output stays off terminal: it may include SQL and machine paths.
  const proxy=await openLocalOperatorBindings(config);await proxy.dispose();
  console.log(JSON.stringify({localDatabaseInitialized:true,remoteBindings:false,operatorGrantsCreated:false}));
}

export async function openLocalOperatorBindings(config) {
  const manifest=JSON.parse(await readFile(path.join(config.runtimeDirectory,'installation.json'),'utf8'));
  if(manifest.schemaVersion!==1||manifest.databaseID!==config.enrollment.scope.databaseID||inside(repo,await realpath(config.runtimeDirectory))) invalid();
  // Do not trust a mutable Wrangler file to add remote bindings, crons, routes or vars.
  const expected={name:'neko-operator-local',compatibility_date:'2026-08-17',workers_dev:false,preview_urls:false,
    d1_databases:[{binding:'DB',database_name:'neko-operator-local',database_id:manifest.databaseID,remote:false,migrations_dir:path.join(service,'migrations')}]};
  const wranglerPath=path.join(config.runtimeDirectory,'wrangler.local.json');
  if(JSON.stringify(JSON.parse(await readFile(wranglerPath,'utf8')))!==JSON.stringify(expected)) invalid();
  // Wrangler treats envFiles:[] as eligible for .dev.vars. A nonempty explicit
  // list of one checked empty file prevents that fallback and .env discovery.
  const emptyFile=path.join(config.runtimeDirectory,'vars.empty');
  if(await readFile(emptyFile,'utf8')!==''||['true','1'].includes(process.env.CLOUDFLARE_INCLUDE_PROCESS_ENV?.toLowerCase())) invalid();
  const proxy=await getPlatformProxy({configPath:wranglerPath,envFiles:[emptyFile],persist:{path:path.join(config.runtimeDirectory,'state','v3')},remoteBindings:false});
  try {
    if(Object.keys(proxy.env).length!==1||!Object.hasOwn(proxy.env,'DB')) invalid();
    const row=await proxy.env.DB.prepare("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name IN ('moderation_operator_subject_identities','moderation_operator_enrollment_admissions','moderation_owner_decisions')").first();
    if(row?.n!==3) throw Error('local_operator_schema_not_ready');
    return proxy;
  } catch(error){await proxy.dispose();throw error;}
}

export async function main(args) {
  if(args.length!==3||args[0]!=='--config'||!path.isAbsolute(args[1])||!['--plan','--check','--init-local-db','--serve'].includes(args[2])) throw Error('usage: --config ABSOLUTE_PATH --plan|--check|--init-local-db|--serve');
  const raw=JSON.parse(await readFile(args[1],'utf8'));
  if(args[2]==='--plan') {
    let configurationValid=false;try{validateLocalOperatorConfig(raw);configurationValid=true;}catch{}
    console.log(JSON.stringify({configurationValid,mode:'local',remoteBindings:false,startsServer:false,createsGrants:false,
      requires:['HTTPS Access front door forwarding Host to 127.0.0.1:port','Actual Access issuer and audience','Existing subject HMAC key file (32 raw bytes) and version','Reviewed operator ID, installation scope and existing active roles','Two reviewed offline authority public keys','Fresh isolated local DB initialization'],
      liveOperationVerified:false}));return;
  }
  const config=validateLocalOperatorConfig(raw);
  const key=new Uint8Array(await readFile(config.access.subjectHmacKeyFile));
  if(key.length!==32) invalid();
  if(args[2]==='--init-local-db'){try{return await initialize(config,args[1]);}finally{key.fill(0);}}
  const proxy=await openLocalOperatorBindings(config);
  let server;
  try {
    const bundle=await build({entryPoints:[path.join(service,'src/moderation-operator-host-local.ts'),path.join(service,'src/moderation-operator-auth.ts')],
      bundle:true,platform:'node',format:'esm',write:false,outdir:'bundle',outExtension:{'.js':'.mjs'}});
    for(const file of bundle.outputFiles) await writeFile(path.join(config.runtimeDirectory,path.basename(file.path)),file.contents);
    const version='?v='+Date.now();
    const {createLocalModerationOperatorHost}=await import(pathToFileURL(path.join(config.runtimeDirectory,'moderation-operator-host-local.mjs')).href+version);
    const {authenticateCloudflareAccessRequest,ModerationAccessJwksCache}=await import(pathToFileURL(path.join(config.runtimeDirectory,'moderation-operator-auth.mjs')).href+version);
    const access={issuer:config.access.issuer,audience:config.access.audience,subjectHmacKey:key,subjectHmacKeyVersion:config.access.subjectHmacKeyVersion,cache:new ModerationAccessJwksCache()};
    const handler=createLocalModerationOperatorHost({environment:'local',runtimeEnabled:'YES',db:proxy.env.DB,origin:config.origin,rpId:config.rpId,access,enrollment:config.enrollment});
    const ready={schemaReady:true,operatorGrantsCreated:false,liveOperationVerified:false};
    if(args[2]==='--check'){console.log(JSON.stringify({configurationValid:true,...ready,remoteBindings:false}));return;}
    server=await startLoopbackOperatorServer({origin:config.origin,port:config.port,handler,
      authenticate:request=>authenticateCloudflareAccessRequest(request,access),ready});
    console.log(JSON.stringify({listening:`http://127.0.0.1:${server.port}`,browserURL:config.origin+'/operator/enrollment',...ready,frontDoorRequired:true}));
    await new Promise(resolve=>{process.once('SIGINT',resolve);process.once('SIGTERM',resolve);});
  } finally {if(server) await server.close();key.fill(0);await proxy.dispose();}
}

if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) main(process.argv.slice(2)).catch(error=>{
  // Do not echo tokens, SQL, config contents, private paths or underlying dependency errors.
  const safe=new Set(['invalid_local_operator_config','local_runtime_directory_not_empty','local_operator_schema_not_ready','local_migration_result_unconfirmed']);
  console.error(safe.has(error.message)?error.message:'local_operator_startup_failed');process.exitCode=1;
});
