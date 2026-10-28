import { test } from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import { createHash, randomBytes } from "node:crypto";
import { createLocalOwnerReviewHost } from "../scripts/moderation-owner-review-host.mjs";
import { moderationReviewSourceBinding } from "../scripts/moderation-bound-review-lib.mjs";
import { deriveRawModerationPublicKey } from "../scripts/moderation-report-lib.mjs";
import { createSyntheticModerationBundle, SYNTHETIC_CANONICAL_JPEG } from "../scripts/moderation-staging-drill-lib.mjs";
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const moduleURL = source => 'data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source)).toString('base64');
const browserURL=moduleURL(await readFile(new URL('../src/moderation-owner-browser.ts',import.meta.url),'utf8'));
const consoleSource=await readFile(new URL('../src/moderation-owner-console.ts',import.meta.url),'utf8');
assert.equal(consoleSource.split('"./moderation-owner-browser"').length,2);
const {localModerationOwnerConsole}=await import(moduleURL(consoleSource.replace('"./moderation-owner-browser"',JSON.stringify(browserURL))));
const ownerHTML=await localModerationOwnerConsole(true).text();
const ownerScript=/<script nonce="[^"]+">([\s\S]+)<\/script>/u.exec(ownerHTML)[1];

async function ownerPage(active=false,reviewHeader=true){
 let clock=1791800000000,nextTimer=0,signatures=0,completed=false;
 const timers=new Map(),calls=[];
 const elements=new Map([...ownerHTML.matchAll(/id="([^"]+)"/gu)].map(m=>[m[1],{disabled:false,checked:false,hidden:/\bhidden(?:[ >])/u.test(m.input.slice(m.index,m.input.indexOf('>',m.index))),dataset:{},listeners:{},addEventListener(type,fn){this.listeners[type]=fn},removeAttribute(name){delete this[name]},async decode(){}}]));
 const radios=[{value:'hide',checked:true},{value:'no_action',checked:false}].map(r=>({...r,listeners:{},addEventListener(type,fn){this.listeners[type]=fn}}));
 for(const radio of radios){radio._checked=radio.checked;Object.defineProperty(radio,'checked',{get(){return this._checked},set(value){this._checked=value;if(value)for(const peer of radios)if(peer!==this)peer._checked=false}})}
 const document={hidden:false,listeners:{},getElementById:id=>elements.get(id),querySelectorAll:()=>radios,querySelector:s=>s.includes(':checked')?radios.find(r=>r.checked):radios.find(r=>s.includes('value='+r.value)),addEventListener(type,fn){this.listeners[type]=fn}};
 const window={PublicKeyCredential:function(){},listeners:{},addEventListener(type,fn){this.listeners[type]=fn}};
 const ref='a'.repeat(64),digest='b'.repeat(64),receipt='11111111-1111-4111-8111-111111111111';
 const context={document,window,location:{hostname:'operator.synthetic.invalid',pathname:'/operator/owner/console/'+ref+'/1'},Date:{now:()=>clock},AbortController,AbortSignal,Uint8Array,Number,atob,btoa,
  URL:{createObjectURL:()=> 'blob:synthetic-owner',revokeObjectURL(){}},
  setTimeout(fn,ms){const id=++nextTimer;timers.set(id,{fn,at:clock+ms});return id},clearTimeout(id){timers.delete(id)},
  navigator:{credentials:{async get(){signatures++;return {id:'AQ',rawId:Uint8Array.of(1).buffer,type:'public-key',getClientExtensionResults:()=>({}),response:{clientDataJSON:Uint8Array.of(1).buffer,authenticatorData:Uint8Array.of(2).buffer,signature:Uint8Array.of(3).buffer}}}}},
  async fetch(path,options){
   calls.push(path);
   if(path.endsWith('/state'))return Response.json({caseReferenceHmac:ref,revision:completed?1:0,targetAvailable:active,canNoAction:!completed,canRelease:false,...(completed?{operation:'no_action'}:{})});
   if(path.includes('/assertions/')){
    if(path.includes('/content-read/'))return new Response(SYNTHETIC_CANONICAL_JPEG,{headers:{'Content-Type':'image/jpeg','X-Moderation-Read-Receipt':receipt,'X-Moderation-Source-SHA256':digest,'X-Moderation-Expires-At':String((clock+60000)/1000),...(reviewHeader?{'X-Moderation-Review-Expires-At':String((clock+3600000)/1000)}:{})}});
    completed=true;return Response.json({caseReferenceHmac:ref,operation:'no_action',revision:1,reply:'available_in_app',recipientViewed:false});
   }
   const purpose=path.endsWith('/content-read')?'content_read':'no_action';
   return Response.json({caseReferenceHmac:ref,purpose,operation:purpose,rpId:'operator.synthetic.invalid',userVerification:'required',expiresAt:(clock+300000)/1000,sourceSHA256:digest,challengeId:receipt,challenge:Buffer.alloc(32,1).toString('base64url'),assertionPath:path+'/assertions/'+receipt,bindingSHA256:'c'.repeat(64),expectedRevision:0});
  }};
 vm.runInNewContext(ownerScript,context);await new Promise(setImmediate);
 return {elements,radios,calls,get signatures(){return signatures},async click(id){assert.equal(elements.get(id).disabled,false);await elements.get(id).listeners.click()},confirm(){elements.get('confirmed').checked=true;elements.get('confirmed').listeners.change()},advance(ms){const target=clock+ms;for(const [id,t] of [...timers].sort((a,b)=>a[1].at-b[1].at)){if(t.at<=target&&timers.has(id)){clock=t.at;timers.delete(id);t.fn()}}clock=target},leave(){document.hidden=true;document.listeners.visibilitychange()}};
}

for(const active of [false,true])test(`human review outlasts both the read lease and original authentication challenge (active=${active})`,async()=>{
 const p=await ownerPage(active);await p.click('open');p.advance(301000);
 assert.equal(p.elements.get('photo').hidden,false);assert.equal(p.elements.get('decision').hidden,false);
 assert.equal(p.signatures,1);assert.equal(p.calls.filter(x=>x.includes('/no_action/')).length,0);
 // Merely waiting does not sign or submit anything. Confirmation uses a new signature.
 if(active){p.radios[1].checked=true;p.radios[1].listeners.change()}
 p.confirm();await p.click('finish');assert.equal(p.signatures,2);
 assert.equal(p.calls.filter(x=>x.includes('/no_action/')&&x.includes('/assertions/')).length,1);
 assert.match(p.elements.get('status').textContent,/対応を保存しました/u);
 assert.equal(p.elements.get('photo').src,undefined);
});
test('explicit close, leaving, and the existing session/report expiry each clear photo and decision without a write',async()=>{
 for(const close of ['button','leave','expiry']){
  const p=await ownerPage();await p.click('open');p.confirm();p.advance(301000);
  if(close==='button')await p.click('close-photo');else if(close==='leave')p.leave();else p.advance(3600000);
  assert.equal(p.elements.get('photo').src,undefined);assert.equal(p.elements.get('photo').hidden,true);
  assert.equal(p.elements.get('close-photo').hidden,true);assert.equal(p.elements.get('decision').hidden,true);
  assert.equal(p.elements.get('confirmed').checked,false);assert.equal(p.elements.get('finish').disabled,true);
  assert.equal(p.signatures,1);assert.equal(p.calls.filter(x=>x.includes('/no_action/')).length,0);
 }
});
test('an older server without a review lifetime cannot accidentally enable unbounded display',async()=>{
 const p=await ownerPage(false,false);await p.click('open');
 assert.equal(p.elements.get('photo').src,undefined);assert.equal(p.elements.get('decision').hidden,true);
 assert.equal(p.elements.get('finish').disabled,true);
});
function fixture() {
  const privateKeyBytes = randomBytes(32), raw = deriveRawModerationPublicKey(privateKeyBytes);
  const bundle = createSyntheticModerationBundle(raw);
  const ref = { caseReferenceHmac: "a".repeat(64), caseReferenceHmacKeyVersion: 1 };
  const source = { schema: "jp.nekowidget.moderation-review-source.v1", ...ref,
    objectKey: "reports/owner-synthetic", metadata: { ...bundle.metadata } };
  const abort = new AbortController(), phases = []; let reads = 0, fetches = 0;
  const adapters = { async readCiphertext() { fetches++; return bundle.envelopeBytes; },
    async readReviewedKey() { return { privateKeyBytes, companionPublicKeyBytes: Buffer.from(raw.toString("base64url")),
      reviewedKeyId: "moderation-v1", expectedPublicKeySHA256: hash(raw) }; } };
  const input = { source, sourceSHA256: moderationReviewSourceBinding(source, ref).sourceSHA256,
    signal: abort.signal, async readCurrentSource() { reads++; return source; }, async audit(phase) { phases.push(phase); } };
  return { adapters, input, abort, phases, get reads() { return reads; }, get fetches() { return fetches; } };
}
test("owner host composes real encryption and returns an owned JPEG only after both audits", async () => {
  const f=fixture(), host=createLocalOwnerReviewHost(f.adapters);
  const jpeg=await host(f.input);
  assert.deepEqual(Buffer.from(jpeg),SYNTHETIC_CANONICAL_JPEG);
  assert.deepEqual(f.phases,["started","disclosure_ready"]);assert.ok(f.reads>=4);assert.equal(f.fetches,1);
  jpeg.fill(0);assert.notEqual(SYNTHETIC_CANONICAL_JPEG[0],0);
});
test("another exact source digest is rejected before fetching ciphertext", async()=>{
  const f=fixture();f.input.sourceSHA256="0".repeat(64);
  await assert.rejects(createLocalOwnerReviewHost(f.adapters)(f.input),{message:"owner_review_unavailable"});
  assert.equal(f.fetches,0);
});
test("parent cancellation before invocation releases no image or object request",async()=>{
  const f=fixture();f.abort.abort();
  await assert.rejects(createLocalOwnerReviewHost(f.adapters)(f.input));assert.equal(f.fetches,0);
});
test("revocation during a slow key read prevents the JPEG sink",async()=>{
  const f=fixture(), original=f.adapters.readReviewedKey;
  f.adapters.readReviewedKey=async()=>{const key=await original();f.abort.abort();return key};
  await assert.rejects(createLocalOwnerReviewHost(f.adapters)(f.input));assert.deepEqual(f.phases,["started"]);
});
test("failed disclosure audit prevents output",async()=>{
  const f=fixture();f.input.audit=async phase=>{f.phases.push(phase);if(phase==='disclosure_ready')throw Error('db unavailable')};
  await assert.rejects(createLocalOwnerReviewHost(f.adapters)(f.input));assert.deepEqual(f.phases,["started","disclosure_ready"]);
});
