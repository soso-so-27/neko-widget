import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import http from 'node:http';
import {createHash,generateKeyPairSync,sign,randomBytes} from 'node:crypto';
import {promisify} from 'node:util';
import {execFile,spawn} from 'node:child_process';
import {build} from 'esbuild';
import {validateLocalOperatorConfig,openLocalOperatorBindings} from '../scripts/moderation-operator-local-start.mjs';
import {startLoopbackOperatorServer} from '../scripts/moderation-operator-local-server.mjs';

const origin='https://operator.synthetic.invalid';
const issuer='https://synthetic-operator.cloudflareaccess.com';
const audience='2'.repeat(64);
const service=path.resolve(import.meta.dirname,'..');
const run=promisify(execFile);
let directory,authenticator;
const rsa=generateKeyPairSync('rsa',{modulusLength:2048});
const jwk=rsa.publicKey.export({format:'jwk'});
function token(changes={}) {
  const now=Math.floor(Date.now()/1000);
  const encode=o=>Buffer.from(JSON.stringify(o)).toString('base64url');
  const input=encode({alg:'RS256',kid:'a'.repeat(64),typ:'JWT'})+'.'+encode({iss:issuer,aud:[audience],sub:'11111111-1111-4111-8111-111111111111',type:'app',iat:now,nbf:now,exp:now+600,...changes});
  return input+'.'+sign('sha256',Buffer.from(input),rsa.privateKey).toString('base64url');
}
function config() {
  const authorities=[1,2].map(n=>{const b=Buffer.alloc(32,n);return {keyID:`synthetic-key-${n}`,revision:1,authorizedAt:1,publicKeyBase64url:b.toString('base64url'),publicKeyFingerprintSHA256:createHash('sha256').update(b).digest('hex')};});
  return {schemaVersion:1,mode:'local',origin,rpId:new URL(origin).hostname,port:4317,runtimeDirectory:path.join(directory,'state'),
    access:{issuer,audience,subjectHmacKeyFile:path.join(directory,'subject-hmac.bin'),subjectHmacKeyVersion:1},
    enrollment:{operatorID:'11111111-1111-4111-8111-111111111111',scope:{accountID:'1'.repeat(32),databaseID:'22222222-2222-4222-8222-222222222222',serviceIdentity:'operator-local',accessIssuer:issuer,accessAudience:audience,expectedOrigin:origin,expectedRPID:new URL(origin).hostname},activeRoles:['triage'],authorities}};
}
before(async()=>{
  directory=await mkdtemp(path.join(tmpdir(),'neko-operator-startup-test-'));
  const bundle=await build({entryPoints:[path.join(service,'src/moderation-operator-auth.ts')],bundle:true,platform:'node',format:'esm',write:false});
  const modulePath=path.join(directory,'auth.mjs');await writeFile(modulePath,bundle.outputFiles[0].contents);
  const {authenticateCloudflareAccessRequest,ModerationAccessJwksCache}=await import(pathToFileURL(modulePath));
  const options={issuer,audience,subjectHmacKey:randomBytes(32),subjectHmacKeyVersion:1,cache:new ModerationAccessJwksCache(),fetchImpl:async()=>new Response(JSON.stringify({keys:[{...jwk,kid:'a'.repeat(64),alg:'RS256',use:'sig'}]}),{headers:{'Content-Type':'application/json'}})};
  authenticator=request=>authenticateCloudflareAccessRequest(request,options);
});
after(async()=>{
  const parent=path.resolve(tmpdir());const relative=path.relative(parent,directory);
  assert.ok(relative.startsWith('neko-operator-startup-test-')&&!relative.includes(path.sep));
  await rm(directory,{recursive:true,force:true});
});
async function request(server,route,options={}) {
  const method=options.method??'POST';
  const headers={host:`127.0.0.1:${server.port}`,origin,'cf-access-jwt-assertion':token(),...options.headers};
  return new Promise((resolve,reject)=>{
    const req=http.request({hostname:'127.0.0.1',port:server.port,path:route,method,headers},res=>{
      const chunks=[];res.on('data',c=>chunks.push(c));res.on('end',()=>resolve({status:res.statusCode,body:Buffer.concat(chunks).toString('utf8')}));
    });req.on('error',reject);req.end(options.body);
  });
}
test('configuration fixes local mode, exact HTTPS origin/RP/Access, external storage and reviewed authorities',()=>{
  const c=config();const snapshot=validateLocalOperatorConfig(c);c.enrollment.activeRoles.length=0;assert.deepEqual(snapshot.enrollment.activeRoles,['triage']);
  for(const mutate of [c=>c.mode='production',c=>c.remoteBindings=true,c=>c.origin='http://operator.synthetic.invalid',c=>c.rpId='synthetic.invalid',c=>c.port=0,c=>c.runtimeDirectory=service,c=>c.access.subjectHmacKeyFile='relative.bin',c=>c.enrollment.scope.accessAudience='3'.repeat(64),c=>c.enrollment.authorities[0].publicKeyFingerprintSHA256='4'.repeat(64),c=>c.enrollment.activeRoles.push('triage'),c=>c.enrollment.authorities[1]=c.enrollment.authorities[0]]) {
    const c=config();mutate(c);assert.throws(()=>validateLocalOperatorConfig(c));
  }
});
test('actual signed Access reaches fixed canonical handler; invalid, missing and wrong audience stay closed',async()=>{
  let calls=0;
  const server=await startLoopbackOperatorServer({origin,port:0,authenticate:authenticator,handler:async request=>{calls++;assert.equal(request.url,origin+'/operator/console');assert.equal(request.headers.get('x-forwarded-host'),null);return new Response('accepted');}});
  try {
    for(const jwt of ['', 'invalid', token({aud:['3'.repeat(64)]}),token({exp:1})]) assert.equal((await request(server,'/operator/console',{method:'GET',headers:{'cf-access-jwt-assertion':jwt}})).status,401);
    assert.equal(calls,0);
    assert.equal((await request(server,'/operator/console',{method:'GET',headers:{'x-forwarded-host':'evil.invalid','x-forwarded-proto':'http'}})).status,200);
    assert.equal(calls,1);
  } finally {await server.close();}
});
test('wrong Host, duplicate credential/Origin, foreign Origin and alternate paths cannot dispatch',async()=>{
  let calls=0;const server=await startLoopbackOperatorServer({origin,port:0,authenticate:authenticator,handler:async()=>{calls++;return new Response('bad');}});
  try {
    for(const [route,headers] of [['/operator/console',{host:'foreign.invalid'}],['/operator/console',{origin:'https://evil.invalid'}],['/operator/console',{'cf-access-jwt-assertion':[token(),token()]}],['/operator/console',{origin:[origin,origin]}],['/operator/console?scope=live',{}],['/operator/../operator/console',{}],['//operator/console',{}],['/public',{}]]) assert.notEqual((await request(server,route,{headers})).status,200);
    assert.equal(calls,0);
  } finally {await server.close();}
});
test('oversized authenticated bodies stop before dispatch; health discloses no operator or case data',async()=>{
  let calls=0;const server=await startLoopbackOperatorServer({origin,port:0,authenticate:authenticator,handler:async()=>{calls++;return new Response('bad');}});
  try {
    assert.equal((await request(server,'/operator/console',{body:'x'.repeat(32769)})).status,413);
    assert.equal(calls,0);
    const health=await request(server,'/health',{method:'GET',headers:{'cf-access-jwt-assertion':''}});
    assert.equal(health.status,200);assert.deepEqual(JSON.parse(health.body),{mode:'local',remoteBindings:false,frontDoorRequired:true,ownerReviewConfigured:false});
  } finally {await server.close();}
});
test('client disconnect aborts the handler and close releases pending requests',async()=>{
  let observed;let started;const pending=new Promise(resolve=>started=resolve);
  const server=await startLoopbackOperatorServer({origin,port:0,authenticate:authenticator,handler:async r=>{observed=r.signal;started();await new Promise(resolve=>r.signal.addEventListener('abort',resolve,{once:true}));return new Response('aborted');}});
  const req=http.request({hostname:'127.0.0.1',port:server.port,path:'/operator/console',method:'GET',headers:{host:`127.0.0.1:${server.port}`,'cf-access-jwt-assertion':token()}});req.on('error',()=>{});req.end();
  await pending;req.destroy();await server.close();assert.equal(observed.aborted,true);
});
test('shutdown retains dependencies until an already dispatched operation settles even if it ignores cancellation',async()=>{
  let begin,release,completed=false,closed=false;
  const started=new Promise(resolve=>begin=resolve);const finish=new Promise(resolve=>release=resolve);
  const server=await startLoopbackOperatorServer({origin,port:0,authenticate:authenticator,handler:async()=>{begin();await finish;completed=true;return new Response('completed');}});
  const req=http.request({hostname:'127.0.0.1',port:server.port,path:'/operator/console',headers:{host:`127.0.0.1:${server.port}`,'cf-access-jwt-assertion':token()}});req.on('error',()=>{});req.end();
  await started;const closing=server.close().then(()=>closed=true);
  await new Promise(resolve=>setImmediate(resolve));assert.equal(closed,false);
  release();await closing;assert.equal(completed,true);
});
test('communication deadline closes the socket while dependencies stay alive for a handler ignoring cancellation',async()=>{
  let begin,release,closed=false;
  const started=new Promise(resolve=>begin=resolve);const finish=new Promise(resolve=>release=resolve);
  const server=await startLoopbackOperatorServer({origin,port:0,requestTimeoutMilliseconds:100,authenticate:authenticator,handler:async()=>{begin();await finish;return new Response('late');}});
  const disconnected=new Promise(resolve=>{
    const req=http.request({hostname:'127.0.0.1',port:server.port,path:'/operator/console',headers:{host:`127.0.0.1:${server.port}`,'cf-access-jwt-assertion':token()}});req.on('error',resolve);req.end();
  });
  await started;await disconnected;const closing=server.close().then(()=>closed=true);
  await new Promise(resolve=>setImmediate(resolve));assert.equal(closed,false);release();await closing;
});
test('real CLI initializes only fresh local schema without grants, rechecks it and refuses reuse',async()=>{
  const c=config();const configPath=path.join(directory,'connection.json');
  const available=http.createServer();await new Promise(resolve=>available.listen(0,'127.0.0.1',resolve));
  c.port=available.address().port;await new Promise(resolve=>available.close(resolve));
  await writeFile(configPath,JSON.stringify(c));await writeFile(c.access.subjectHmacKeyFile,randomBytes(32));
  const cli=path.join(service,'scripts/moderation-operator-local-start.mjs');
  const result=await run(process.execPath,[cli,'--config',configPath,'--init-local-db'],{cwd:service,timeout:60000});
  assert.deepEqual(JSON.parse(result.stdout),{localDatabaseInitialized:true,remoteBindings:false,operatorGrantsCreated:false});
  await writeFile(path.join(c.runtimeDirectory,'.dev.vars'),'UNEXPECTED_SECRET=must-not-load\n');
  await writeFile(path.join(c.runtimeDirectory,'.env'),'UNEXPECTED_SECRET=must-not-load\n');
  const proxy=await openLocalOperatorBindings(c);
  try {
    assert.deepEqual(Object.keys(proxy.env),['DB']);
    const counts=await proxy.env.DB.prepare('SELECT (SELECT count(*) FROM moderation_operators) AS operators, (SELECT count(*) FROM moderation_operator_role_events) AS roles, (SELECT count(*) FROM moderation_operator_enrollment_offline_authorities) AS authorities').first();
    assert.deepEqual(counts,{operators:0,roles:0,authorities:0});
  } finally {await proxy.dispose();}
  const checked=await run(process.execPath,[cli,'--config',configPath,'--check'],{cwd:service,timeout:30000});
  assert.deepEqual(JSON.parse(checked.stdout),{configurationValid:true,schemaReady:true,operatorGrantsCreated:false,liveOperationVerified:false,remoteBindings:false});
  const child=spawn(process.execPath,[cli,'--config',configPath,'--serve'],{cwd:service,stdio:['ignore','pipe','pipe']});
  const closed=new Promise(resolve=>child.once('close',resolve));
  try {
    const ready=await new Promise((resolve,reject)=>{
      let output='';const timer=setTimeout(()=>reject(Error('startup readiness timeout')),15000);
      child.once('error',error=>{clearTimeout(timer);reject(error);});
      child.once('exit',()=>{clearTimeout(timer);reject(Error('startup exited before ready'));});
      child.stdout.on('data',chunk=>{output+=chunk;if(output.includes('\n')){clearTimeout(timer);resolve(JSON.parse(output.trim()));}});
    });
    assert.equal(ready.listening,`http://127.0.0.1:${c.port}`);
    const health=await fetch(ready.listening+'/health');assert.equal(health.status,200);assert.equal((await health.json()).schemaReady,true);
    const denied=await fetch(ready.listening+'/operator/console');assert.equal(denied.status,401);
  } finally {child.kill('SIGTERM');await closed;}
  // Windows child.kill terminates the fixture process. Graceful draining itself
  // is exercised separately with the actual exported server and accepted work.
  await assert.rejects(()=>run(process.execPath,[cli,'--config',configPath,'--init-local-db'],{cwd:service}),e=>e.stderr.trim()==='local_runtime_directory_not_empty');
});
test('the incomplete checked-in template produces a read-only plan instead of creating keys, DB or grants',async()=>{
  const result=await run(process.execPath,[path.join(service,'scripts/moderation-operator-local-start.mjs'),'--config',path.join(service,'operator.connection.example.json'),'--plan'],{cwd:service});
  const plan=JSON.parse(result.stdout);assert.equal(plan.configurationValid,false);assert.equal(plan.startsServer,false);assert.equal(plan.createsGrants,false);
});
