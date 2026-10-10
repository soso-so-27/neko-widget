import {test} from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {build} from 'esbuild';

const compiled=await build({entryPoints:[new URL('../src/moderation-operator-enrollment-console.ts',import.meta.url).pathname.replace(/^\/(?:([A-Za-z]:))/,'$1')],bundle:true,platform:'node',format:'esm',write:false});
const {localModerationEnrollmentConsole}=await import('data:text/javascript;base64,'+Buffer.from(compiled.outputFiles[0].text).toString('base64'));
const html=await localModerationEnrollmentConsole().text();
const script=/<script nonce="[^"]+">([\s\S]+)<\/script>/u.exec(html)[1];
const ceremonyID='11111111-1111-4111-8111-111111111111',requestID='22222222-2222-4222-8222-222222222222';
const expiresAt=Math.floor(Date.now()/1000)+600;
const request={kind:'unadmitted-local-initial-enrollment-request',ceremonyID,requestID,canonicalRequestSHA256:'a'.repeat(64),expiresAt,enrollmentAdmissionAuthorized:false,approvalTranscripts:[{keyID:'test-one',revision:1,transcriptBase64url:'AQ'},{keyID:'test-two',revision:1,transcriptBase64url:'Ag'}]};
const challenge=phase=>({phase,ceremonyID,challengeID:'33333333-3333-4333-8333-333333333333',challenge:Buffer.alloc(32,1).toString('base64url'),userID:Buffer.alloc(32,2).toString('base64url'),rpId:'operator.synthetic.invalid',expiresAt,enrollmentAdmissionAuthorized:false});
const credential=()=>({id:'AQ',rawId:Uint8Array.of(1).buffer,type:'public-key',getClientExtensionResults:()=>({}),response:{clientDataJSON:Uint8Array.of(1).buffer,attestationObject:Uint8Array.of(2).buffer,authenticatorData:Uint8Array.of(3).buffer,signature:Uint8Array.of(4).buffer}});
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};}
function page({fragment='',fetchImpl,createImpl}={}){
  const elements=new Map([...html.matchAll(/id="([^"]+)"/gu)].map(m=>[m[1],{id:m[1],disabled:false,hidden:/\bhidden(?:[ >])/u.test(m.input.slice(m.index,m.input.indexOf('>',m.index))),value:'',textContent:'',className:'',listeners:{},addEventListener(type,fn){this.listeners[type]=fn;}}]));
  const document={hidden:false,listeners:{},getElementById:id=>elements.get(id),querySelectorAll:selector=>selector==='button'?[...elements.values()].filter(e=>['start','possession','check','download','admit'].includes(e.id)):[],addEventListener(type,fn){this.listeners[type]=fn;}};
  const window={PublicKeyCredential:function(){},listeners:{},addEventListener(type,fn){this.listeners[type]=fn;}};
  const location={hostname:'operator.synthetic.invalid',hash:fragment};
  const calls=[],timers=new Map();let timerID=0,createCalls=0,getCalls=0;
  const context={document,window,location,history:{replaceState(_s,_t,value){location.hash=value;}},AbortController,AbortSignal,TextEncoder,Uint8Array,atob,btoa,Blob,URL,
    setTimeout(fn){timers.set(++timerID,fn);return timerID;},clearTimeout(id){timers.delete(id);},
    navigator:{credentials:{async create(){createCalls++;return createImpl?createImpl():credential();},async get(){getCalls++;return credential();}}},
    async fetch(path,options){calls.push({path,options});if(fetchImpl)return fetchImpl(path,options);if(path.endsWith('/start'))return Response.json(challenge('registration'),{status:202});if(path.endsWith('/registration'))return Response.json(challenge('possession'),{status:202});if(path.endsWith('/possession'))return Response.json(request,{status:202});if(path.endsWith('/status'))return Response.json({status:'pending',request});throw Error('unexpected mutation');}}
  vm.runInNewContext(script,context);
  return {elements,document,window,location,calls,timers,get createCalls(){return createCalls;},get getCalls(){return getCalls;},
    click:async id=>{const element=elements.get(id);assert.equal(element.disabled,false);assert.equal(element.hidden,false);await element.listeners.click();},
    leave:()=>{document.hidden=true;document.listeners.visibilitychange();},return:()=>{document.hidden=false;document.listeners.visibilitychange();}};
}
test('leaving an untouched page never locks the only start action or sends a request',async()=>{
  const p=page();p.leave();p.return();p.window.listeners.pagehide();
  assert.equal(p.elements.get('start').disabled,false);assert.equal(p.elements.get('start').hidden,false);assert.equal(p.calls.length,0);
});
test('idle possession survives switching screens in the same document and still requires an explicit assertion',async()=>{
  const p=page();await p.click('start');assert.match(p.location.hash,/^#ceremony=/u);assert.equal(p.elements.get('check').hidden,true);p.leave();p.return();
  assert.equal(p.elements.get('possession').hidden,false);assert.equal(p.elements.get('possession').disabled,false);assert.equal(p.getCalls,0);assert.equal(p.calls.length,2);
  await p.click('possession');assert.equal(p.getCalls,1);assert.equal(p.calls.length,3);assert.equal(p.elements.get('approval').hidden,false);assert.equal(p.location.hash,'#request='+requestID);
});
test('copying approval from another screen clears text but preserves the same pending form without any request',async()=>{
  const p=page();await p.click('start');await p.click('possession');p.elements.get('signatures').value='test-approval';p.leave();p.return();
  assert.equal(p.elements.get('signatures').value,'');assert.equal(p.elements.get('approval').hidden,false);assert.equal(p.calls.length,3);
  assert.equal(p.location.hash,'#request='+requestID);assert.equal(p.elements.get('requestHash').textContent,request.canonicalRequestSHA256);
  await p.click('check');assert.equal(p.calls.length,4);assert.ok(p.calls[3].path.endsWith('/status'));assert.equal(p.elements.get('approval').hidden,false);assert.equal(p.elements.get('signatures').value,'');
});

test('reloading the exact pending request restores its form by status without repeating either authenticator',async()=>{
  const p=page({fragment:'#request='+requestID});await p.click('check');p.leave();p.return();
  assert.equal(p.elements.get('approval').hidden,false);assert.equal(p.location.hash,'#request='+requestID);
  assert.equal(p.createCalls,0);assert.equal(p.getCalls,0);assert.equal(p.calls.length,1);assert.ok(p.calls[0].path.endsWith('/status'));
});
test('an interrupted start ignores late responses, never opens an authenticator or retries a write',async()=>{
  const wait=deferred();const p=page({fetchImpl:()=>wait.promise});const pending=p.click('start');p.leave();p.return();wait.resolve(Response.json(challenge('registration'),{status:202}));await pending;
  assert.equal(p.createCalls,0);assert.equal(p.calls.length,1);assert.equal(p.elements.get('start').disabled,true);assert.equal(p.elements.get('reopen').hidden,false);
});
test('an interrupted authenticator cannot post its late registration proof',async()=>{
  const wait=deferred();const p=page({createImpl:()=>wait.promise});const pending=p.click('start');
  while(p.createCalls===0)await new Promise(resolve=>setImmediate(resolve));p.leave();p.return();wait.resolve(credential());await pending;
  assert.equal(p.calls.length,1);assert.equal(p.elements.get('check').hidden,false);assert.match(p.location.hash,/^#ceremony=/u);
});
test('an unknown early ceremony has an explicit reopen route after read-only recovery',async()=>{
  const p=page({fragment:'#ceremony='+ceremonyID,fetchImpl:()=>Response.json({status:'not_found'})});
  assert.equal(p.elements.get('start').hidden,true);await p.click('check');assert.equal(p.calls.length,1);assert.equal(p.elements.get('reopen').hidden,false);
});
test('a missing login offers reopening without an unnecessary logout and uses Access AJAX semantics',async()=>{
  const p=page({fetchImpl:()=>Response.json({error:'operator_authentication_failed'},{status:401})});await p.click('start');p.leave();p.return();
  assert.equal(p.createCalls,0);assert.equal(p.elements.get('reopen').hidden,false);assert.equal(p.elements.get('refresh').hidden,true);assert.equal(p.calls[0].options.headers['X-Requested-With'],'XMLHttpRequest');assert.equal(p.calls.length,1);
});
test('short-session guidance remains usable after a switch and distinguishes an absent cookie',async()=>{
  const p=page({fetchImpl:()=>Response.json({error:'operator_session_refresh_required'},{status:409})});await p.click('start');const text=p.elements.get('status').textContent;p.leave();p.return();
  assert.equal(p.createCalls,0);assert.equal(p.elements.get('refresh').hidden,false);assert.equal(p.elements.get('reopen').hidden,false);assert.equal(p.elements.get('status').textContent,text);assert.match(text,/No Access cookie found/u);
});
test('expiry discards an idle possession challenge and prevents reuse',async()=>{
  const p=page();await p.click('start');const expire=[...p.timers.values()][0];expire();
  assert.equal(p.elements.get('possession').hidden,true);assert.equal(p.getCalls,0);assert.equal(p.calls.length,2);assert.equal(p.elements.get('check').hidden,false);
});

test('expiry still hides pending approval fields and wipes text even when tab switching preserves progress',async()=>{
  const p=page();await p.click('start');await p.click('possession');p.leave();p.return();p.elements.get('signatures').value='test-approval';
  const expire=[...p.timers.values()][0];expire();
  assert.equal(p.elements.get('approval').hidden,true);assert.equal(p.elements.get('signatures').value,'');assert.equal(p.calls.length,3);
});
test('a lost admission response is recovered as a receipt without resending its signature',async()=>{
  const wait=deferred();let posted=false;
  const receipt={kind:'locally-admitted-initial-operator',ceremonyID,requestID,canonicalRequestSHA256:'a'.repeat(64),admissionID:'55555555-5555-4555-8555-555555555555',admissionProvenanceSHA256:'b'.repeat(64),admittedAt:Math.floor(Date.now()/1000),realHumanVerified:false,hardwareProvenanceVerified:false};
  const p=page({fragment:'#request='+requestID,fetchImpl:path=>{
    if(path.endsWith('/admit')){posted=true;return wait.promise;}
    return Response.json({status:posted?'admitted':'pending',request,...(posted?{receipt}:{})});
  }});
  await p.click('check');p.elements.get('signatures').value='{"approvals":[]}';const pending=p.click('admit');p.leave();p.return();wait.resolve(Response.json(receipt));await pending;
  assert.equal(p.elements.get('complete').hidden,true);assert.equal(p.elements.get('signatures').value,'');await p.click('check');
  assert.equal(p.elements.get('complete').hidden,false);assert.equal(p.calls.filter(c=>c.path.endsWith('/admit')).length,1);assert.equal(p.elements.get('reopen').hidden,true);
  p.leave();p.return();assert.equal(p.elements.get('complete').hidden,false);assert.equal(p.calls.length,3);
});
