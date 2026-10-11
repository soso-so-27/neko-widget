import {env} from 'cloudflare:workers';
import {reset,applyD1Migrations,type D1Migration} from 'cloudflare:test';
import {beforeEach,it,expect} from 'vitest';
import {fixture} from './fixtures/moderation-operator';
import {base64urlEncode,sha256} from '../src/encoding';
import {actorSQL,guard} from '../src/moderation-operator-identity';
import {currentModerationReportKey} from '../src/moderation-report-key-policy';
import {admitOwnerScopeAdoption,canonicalScopeBytes,readOwnerScopeAdoption,type OwnerScopeAdoption,type ScopeApproval} from '../src/moderation-owner-scope-adoption';
const db=(env as unknown as {DB:D1Database}).DB;
const migrate=async()=>{await reset();await applyD1Migrations(db,(env as unknown as {TEST_MIGRATIONS:D1Migration[]}).TEST_MIGRATIONS)};
beforeEach(migrate);
async function setup(){
 const f=await fixture(),hash=async(b:Uint8Array)=>[...await sha256(b)].map(n=>n.toString(16).padStart(2,'0')).join('');
 const row=await db.prepare(`SELECT q.*,a.enrollment_admission_id,a.admission_provenance_sha256 FROM moderation_operator_enrollment_requests q JOIN moderation_operator_enrollment_admissions a USING(enrollment_request_id)`).first<Record<string,unknown>>();
 const keys=await Promise.all([1,2].map(async i=>{
  const pair=await crypto.subtle.generateKey('Ed25519',true,['sign','verify']) as CryptoKeyPair;
  const publicKey=new Uint8Array(await crypto.subtle.exportKey('raw',pair.publicKey));
  return {pair,authority:{keyID:'SCOPE_OFFLINE_'+i,revision:1,publicKeyBase64url:base64urlEncode(publicKey),publicKeyFingerprintSHA256:await hash(publicKey),authorizedAt:1}};
 }));
 const t:OwnerScopeAdoption={domain:'NW.MODERATION-OWNER.SCOPE-ADOPTION.v1',requestID:crypto.randomUUID(),admissionID:crypto.randomUUID(),approvedUntil:Math.floor(Date.now()/1000)+600,
  authorities:keys.map(k=>({keyID:k.authority.keyID,revision:1,publicKeyFingerprintSHA256:k.authority.publicKeyFingerprintSHA256})),
  target:{accountID:'1'.repeat(32),databaseID:crypto.randomUUID(),serviceIdentity:'test-staging',reportBucket:'test-staging-reports',accessIssuer:f.local.access.issuer,accessAudience:f.local.access.audience,origin:f.local.origin,rpId:f.local.rpId,moderationKeyId:'moderation-v2',publicKeySHA256:'2'.repeat(64)},
  source:{databaseID:crypto.randomUUID(),admissionID:row!.enrollment_admission_id as string,provenanceSHA256:row!.admission_provenance_sha256 as string,
   operatorID:f.operatorId,subjectHmac:row!.target_access_subject_hmac as string,subjectHmacKeyVersion:1,credentialSHA256:f.credentialDigest,
   publicKeyCoseBase64url:base64urlEncode(new Uint8Array(row!.target_public_key_cose_snapshot as number[])),registrationSignCount:0,counterFloor:7,
   attestationEvidenceSHA256:row!.attestation_evidence_sha256 as string,attestationPolicyRevision:1,aaguidSHA256:row!.authenticator_aaguid_sha256 as string,roles:['security_admin','triage']}};
 const approvals:ScopeApproval[]=await Promise.all(keys.map(async k=>{
  const sig=new Uint8Array(await crypto.subtle.sign('Ed25519',k.pair.privateKey,new Uint8Array(canonicalScopeBytes(t)).buffer));
  return {keyID:k.authority.keyID,revision:1,signatureBase64url:base64urlEncode(sig),signatureSHA256:await hash(sig)};
 }));
 await migrate();return {f,t,approvals,authorities:keys.map(k=>k.authority)};
}
it('creates a distinct target admission with two scope signatures and truthful separate counter floor',async()=>{
 const {f,t,approvals,authorities}=await setup();
 const admitted=await admitOwnerScopeAdoption(db,t,approvals,authorities);
 expect(await currentModerationReportKey(db,'moderation-v2')).toBe(true);
 expect(await currentModerationReportKey(db,'moderation-v1')).toBe(false);
 expect((await readOwnerScopeAdoption(db,t.target,authorities)).canonicalSHA256).toBe(admitted.canonicalSHA256);
 const actor=await db.prepare(actorSQL).bind(t.source.subjectHmac,1).first<{sign_count:number;operator_id:string;credential_id_sha256:string;enrollment_admission_id:string;public_key_cose:number[]}>();
 expect(actor!.sign_count).toBe(7);expect(actor!.enrollment_admission_id).toBe(t.admissionID);
 expect(await db.prepare('SELECT registration_sign_count FROM moderation_operator_credentials').first()).toEqual({registration_sign_count:0});
 expect(await db.prepare('SELECT COUNT(*) AS n FROM moderation_operator_enrollment_ceremonies').first()).toEqual({n:0});
 await expect(admitOwnerScopeAdoption(db,t,approvals,authorities)).rejects.toThrow();
 await expect(readOwnerScopeAdoption(db,{...t.target,reportBucket:'another-report-bucket'},authorities)).rejects.toThrow();
 await db.prepare('INSERT INTO moderation_owner_scope_adoption_revocations(enrollment_request_id) VALUES(?)').bind(t.requestID).run();
 await expect(db.prepare('DELETE FROM moderation_owner_scope_adoption_revocations').run()).rejects.toThrow();
 await expect(db.prepare('UPDATE moderation_owner_scope_adoption_revocations SET revoked_at=revoked_at+1').run()).rejects.toThrow();
 expect(await db.prepare(actorSQL).bind(t.source.subjectHmac,1).first()).toBeNull();
 expect(await currentModerationReportKey(db,'moderation-v2')).toBe(false);
 await expect(readOwnerScopeAdoption(db,t.target,authorities)).rejects.toThrow();
 void f;void guard;
});
it('rejects changed target, mismatched signature, expired approval and extra roles without target grants',async()=>{
 const {t,approvals,authorities}=await setup();
 for(const changed of [{...t,target:{...t.target,databaseID:crypto.randomUUID()}},{...t,approvedUntil:1},{...t,source:{...t.source,roles:['security_admin','triage','auditor']}}]){
  await expect(admitOwnerScopeAdoption(db,changed,approvals,authorities)).rejects.toThrow();
  expect(await db.prepare('SELECT COUNT(*) AS n FROM moderation_operators').first()).toEqual({n:0});
 }
});
