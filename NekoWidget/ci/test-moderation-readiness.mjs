import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {verifyReadiness,canonical,codeHashes} from './verify-moderation-readiness.mjs';

const evidence=JSON.parse(await readFile(new URL('./moderation-v2-readiness.json',import.meta.url),'utf8'));
const policy=JSON.parse(await readFile(new URL('./moderation-client-rollout-policy.json',import.meta.url),'utf8'));
// Test the signed artifact at its issue time. The production CLI always uses
// the actual clock; tests remain useful after this one release window expires.
const observed=evidence.payload.issuedAtMs+1;
test('the recorded release is accepted only for its reviewed code',async()=>{
 // This is a historical signed release, not permission to ship every future PR.
 // Keep the real production verifier fail-closed after any reviewed input changes.
 if(canonical(evidence.payload.codeSHA256)===canonical(await codeHashes())){
  assert.equal((await verifyReadiness(evidence,policy,observed)).verified,true);
 }else{
  await assert.rejects(verifyReadiness(evidence,policy,observed),/reviewed_code_changed/);
 }
});
test('rejects stale evidence, a different key/policy/target, changed evidence, unsigned permission and tampered code',async()=>{
 await assert.rejects(verifyReadiness(evidence,policy,evidence.payload.expiresAtMs),/stale_readiness/);
 for(const mutate of [
  p=>p.payload.target.reportBucket='ordinary-media',
  p=>p.payload.keyID='moderation-v1',
  p=>p.payload.scopeSHA256='0'.repeat(64),
  p=>p.payload.reportIntakeEnabled=!p.payload.reportIntakeEnabled,
  p=>p.payload.purpose='public-release',
  p=>p.payload.purpose=p.payload.purpose==='testflight-owner-first-connection'?'testflight-owner-report-ui-continuation':'testflight-owner-first-connection',
  p=>p.payload.v1ReportCount=1,
  p=>p.payload.nativeCustodyVerified=false,
  p=>p.payload.codeSHA256['NekoWidget/SharingService/src/moments.ts']='0'.repeat(64),
  p=>p.payload.evidenceSHA256.cloudObservation='0'.repeat(64),
  p=>p.signatures.pop(),
  p=>p.signatures[1]={...p.signatures[0]},
  p=>p.signatures[0].revision=2,
  p=>p.signatures[0].signatureBase64url='A'.repeat(86)
 ]){const changed=structuredClone(evidence);mutate(changed);await assert.rejects(verifyReadiness(changed,policy,observed));}
 await assert.rejects(verifyReadiness(evidence,{...policy,v2ClientReleaseAllowed:false},observed),/rollout_binding_mismatch/);
 await assert.rejects(verifyReadiness(evidence,{...policy,clientPublicKeySha256:'0'.repeat(64)},observed),/rollout_binding_mismatch/);
});
