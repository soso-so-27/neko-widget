import { base64urlDecode, base64urlEncode, sha256, verifyEd25519 } from './encoding';
import type { LocalEnrollmentOfflineAuthority } from './moderation-operator-enrollment-canonical';

/** Offline administration only. Never imported by the public Worker or selected
 * by an HTTP request. Two authorities approve a NEW target grant, attesting a
 * current source admission; no source ceremony/admission is copied to target. */
export interface OwnerReportScope {
 accountID:string; databaseID:string; serviceIdentity:string; reportBucket:string;
 accessIssuer:string; accessAudience:string; origin:string; rpId:string;
 moderationKeyId:'moderation-v2'; publicKeySHA256:string;
}
export interface OwnerScopeSource {
 databaseID:string; admissionID:string; provenanceSHA256:string;
 operatorID:string; subjectHmac:string; subjectHmacKeyVersion:number;
 credentialSHA256:string; publicKeyCoseBase64url:string; registrationSignCount:number; counterFloor:number;
 attestationEvidenceSHA256:string; attestationPolicyRevision:number; aaguidSHA256:string;
 roles:readonly string[];
}
export interface OwnerScopeAdoption {
 domain:'NW.MODERATION-OWNER.SCOPE-ADOPTION.v1'; requestID:string; admissionID:string;
 approvedUntil:number; source:OwnerScopeSource; target:OwnerReportScope;
 authorities:readonly {keyID:string;revision:number;publicKeyFingerprintSHA256:string}[];
}
export interface ScopeApproval {keyID:string;revision:number;signatureBase64url:string;signatureSHA256:string}
const hex=/^[0-9a-f]{64}$/u, uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const fail=():never=>{throw Error('owner_scope_adoption_unavailable')};
function exact(o:unknown,keys:readonly string[]):asserts o is Record<string,unknown>{
 if(!o||Object.getPrototypeOf(o)!==Object.prototype||Reflect.ownKeys(o).length!==keys.length
  ||keys.some(k=>!Object.hasOwn(o,k)||!('value' in Object.getOwnPropertyDescriptor(o,k)!)))fail();
}
function integer(n:unknown,min=0,max=4294967295):asserts n is number {if(!Number.isSafeInteger(n)||(n as number)<min||(n as number)>max)fail()}
export function canonicalScopeBytes(value:unknown):Uint8Array {
 const walk=(v:unknown):unknown=>{
  if(v===null||typeof v==='string'||typeof v==='boolean')return v;
  if(typeof v==='number'){integer(v);return v}
  if(Array.isArray(v))return v.map(walk);
  if(v&&Object.getPrototypeOf(v)===Object.prototype)return Object.fromEntries(Object.keys(v).sort().map(k=>[k,walk((v as Record<string,unknown>)[k])]));
  return fail();
 };
 return new TextEncoder().encode(JSON.stringify(walk(value)));
}
export async function scopeDigest(value:unknown):Promise<string>{return [...await sha256(canonicalScopeBytes(value))].map(v=>v.toString(16).padStart(2,'0')).join('')}
export function validateOwnerReportScope(value:OwnerReportScope):OwnerReportScope {
 exact(value,['accountID','databaseID','serviceIdentity','reportBucket','accessIssuer','accessAudience','origin','rpId','moderationKeyId','publicKeySHA256']);
 if(!/^[0-9a-f]{32}$/u.test(value.accountID)||!uuid.test(value.databaseID)
  ||!/^[a-z0-9][a-z0-9-]{0,62}$/u.test(value.serviceIdentity)||!/^[a-z0-9][a-z0-9-]{2,62}$/u.test(value.reportBucket)
  ||!/^https:\/\/[a-z0-9-]+\.cloudflareaccess\.com$/u.test(value.accessIssuer)
  ||!hex.test(value.accessAudience)||!hex.test(value.publicKeySHA256)||value.moderationKeyId!=='moderation-v2')fail();
 const origin=new URL(value.origin);if(origin.protocol!=='https:'||origin.origin!==value.origin||origin.hostname!==value.rpId)fail();
 return Object.freeze({...value});
}
export function validateScopeAdoption(value:OwnerScopeAdoption):OwnerScopeAdoption {
 exact(value,['domain','requestID','admissionID','approvedUntil','source','target','authorities']);
 if(value.domain!=='NW.MODERATION-OWNER.SCOPE-ADOPTION.v1'||!uuid.test(value.requestID)||!uuid.test(value.admissionID)||value.requestID===value.admissionID)fail();
 integer(value.approvedUntil,1);const target=validateOwnerReportScope(value.target),s=value.source;
 exact(s,['databaseID','admissionID','provenanceSHA256','operatorID','subjectHmac','subjectHmacKeyVersion','credentialSHA256','publicKeyCoseBase64url','registrationSignCount','counterFloor','attestationEvidenceSHA256','attestationPolicyRevision','aaguidSHA256','roles']);
 if(!uuid.test(s.databaseID)||s.databaseID===target.databaseID||!uuid.test(s.admissionID)||!uuid.test(s.operatorID)
  ||![s.provenanceSHA256,s.subjectHmac,s.credentialSHA256,s.attestationEvidenceSHA256,s.aaguidSHA256].every(x=>hex.test(x)))fail();
 integer(s.subjectHmacKeyVersion,1,2147483647);integer(s.attestationPolicyRevision,1,2147483647);
 integer(s.registrationSignCount);integer(s.counterFloor,s.registrationSignCount);
 const cose=base64urlDecode(s.publicKeyCoseBase64url);if(cose.byteLength<32||cose.byteLength>2048)fail();
 if(!Array.isArray(s.roles)||JSON.stringify([...s.roles].sort())!=='["security_admin","triage"]')fail();
 if(!Array.isArray(value.authorities)||value.authorities.length!==2)fail();
 for(const a of value.authorities){exact(a,['keyID','revision','publicKeyFingerprintSHA256']);integer(a.revision,1,2147483647);if(!/^[A-Za-z0-9._-]{8,64}$/u.test(a.keyID)||!hex.test(a.publicKeyFingerprintSHA256))fail()}
 return Object.freeze({...value,authorities:Object.freeze(value.authorities.map(a=>Object.freeze({...a}))),target,source:Object.freeze({...s,roles:Object.freeze([...s.roles])})});
}
export async function verifyScopeAdoption(value:OwnerScopeAdoption,approvals:readonly ScopeApproval[],authorities:readonly LocalEnrollmentOfflineAuthority[]) {
 const transcript=validateScopeAdoption(value),bytes=canonicalScopeBytes(transcript);
 if(!Array.isArray(approvals)||approvals.length!==2||authorities.length!==2
  ||new Set(authorities.map(a=>a.keyID)).size!==2||new Set(authorities.map(a=>a.publicKeyBase64url)).size!==2)fail();
 if(await scopeDigest([...transcript.authorities].sort((a,b)=>a.keyID.localeCompare(b.keyID)))!==await scopeDigest(authorities.map(a=>({keyID:a.keyID,revision:a.revision,publicKeyFingerprintSHA256:a.publicKeyFingerprintSHA256})).sort((a,b)=>a.keyID.localeCompare(b.keyID))))fail();
 for(const a of authorities){
  const matched=approvals.filter(p=>p.keyID===a.keyID&&p.revision===a.revision);if(matched.length!==1)fail();
  exact(matched[0],['keyID','revision','signatureBase64url','signatureSHA256']);
  const signature=base64urlDecode(matched[0]!.signatureBase64url,64),key=base64urlDecode(a.publicKeyBase64url,32);
  const hash=async(b:Uint8Array)=>[...await sha256(b)].map(v=>v.toString(16).padStart(2,'0')).join('');
  if(await hash(key)!==a.publicKeyFingerprintSHA256||await hash(signature)!==matched[0]!.signatureSHA256
   ||!await verifyEd25519(a.publicKeyBase64url,matched[0]!.signatureBase64url,bytes))fail();
 }
 return {transcript,canonicalSHA256:await scopeDigest(transcript),scopeSHA256:await scopeDigest(transcript.target),
  provenanceSHA256:await scopeDigest({domain:'NW.MODERATION-OWNER.SCOPE-ADMISSION.v1',transcript,approvals:[...approvals].sort((a,b)=>a.keyID.localeCompare(b.keyID))})};
}
export async function admitOwnerScopeAdoption(db:D1Database,value:OwnerScopeAdoption,approvals:readonly ScopeApproval[],authorities:readonly LocalEnrollmentOfflineAuthority[]) {
 const verified=await verifyScopeAdoption(value,approvals,authorities),t=verified.transcript,s=t.source;
 const cose=base64urlDecode(s.publicKeyCoseBase64url),coseSHA=[...await sha256(cose)].map(v=>v.toString(16).padStart(2,'0')).join('');
 const statements=[db.prepare(`SELECT json(CASE WHEN NOT EXISTS(SELECT 1 FROM moderation_operators)
   AND NOT EXISTS(SELECT 1 FROM moderation_owner_scope_installation) AND ?>unixepoch() AND ?<=unixepoch()+900 THEN 'true' ELSE 'denied' END)`)
   .bind(t.approvedUntil,t.approvedUntil),
  db.prepare('INSERT INTO moderation_owner_scope_installation(singleton,scope_sha256) VALUES(1,?)').bind(verified.scopeSHA256),
  db.prepare('INSERT INTO moderation_operators(operator_id) VALUES(?)').bind(s.operatorID),
  db.prepare('INSERT INTO moderation_operator_subject_identities(operator_id,access_subject_hmac_key_version,access_subject_hmac) VALUES(?,?,?)').bind(s.operatorID,s.subjectHmacKeyVersion,s.subjectHmac),
  db.prepare("INSERT INTO moderation_operator_state_events(operator_id,event_type) VALUES(?,'activated')").bind(s.operatorID),
  ...s.roles.map(role=>db.prepare("INSERT INTO moderation_operator_role_events(operator_id,role_code,event_type) VALUES(?,?,'granted')").bind(s.operatorID,role)),
  db.prepare('INSERT INTO moderation_operator_credentials(credential_id_sha256,operator_id,public_key_cose,registration_sign_count) VALUES(?,?,?,?)').bind(s.credentialSHA256,s.operatorID,cose,s.registrationSignCount),
  db.prepare("INSERT INTO moderation_operator_credential_events(credential_id_sha256,event_type) VALUES(?,'registered')").bind(s.credentialSHA256),
  ...authorities.map(a=>db.prepare('INSERT INTO moderation_operator_enrollment_offline_authorities(offline_authority_key_id,authority_policy_revision,authority_public_key_fingerprint_sha256) VALUES(?,?,?)').bind(a.keyID,a.revision,a.publicKeyFingerprintSHA256)),
  db.prepare(`INSERT INTO moderation_operator_enrollment_requests(enrollment_request_id,enrollment_kind,request_schema_version,canonical_request_sha256,target_operator_id,
   target_access_subject_hmac_key_version,target_access_subject_hmac,target_credential_id_sha256,target_public_key_cose_sha256,target_public_key_cose_snapshot,
   target_registration_sign_count,attestation_evidence_sha256,attestation_policy_revision,authenticator_aaguid_sha256,expires_at)
   VALUES(?,'initial_bootstrap',1,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(t.requestID,verified.canonicalSHA256,s.operatorID,s.subjectHmacKeyVersion,s.subjectHmac,s.credentialSHA256,coseSHA,cose,s.registrationSignCount,s.attestationEvidenceSHA256,s.attestationPolicyRevision,s.aaguidSHA256,t.approvedUntil),
  db.prepare(`INSERT INTO moderation_owner_scope_adoptions(enrollment_request_id,scope_sha256,source_database_id,source_admission_id,source_provenance_sha256,counter_floor,transcript_json,approvals_json,approved_until)
   VALUES(?,?,?,?,?,?,?,?,?)`).bind(t.requestID,verified.scopeSHA256,s.databaseID,s.admissionID,s.provenanceSHA256,s.counterFloor,JSON.stringify(t),JSON.stringify(approvals),t.approvedUntil),
  ...approvals.map(p=>db.prepare(`INSERT INTO moderation_operator_enrollment_offline_approvals(enrollment_request_id,offline_authority_key_id,authority_policy_revision,authority_public_key_fingerprint_sha256,authority_signature_sha256)
   VALUES(?,?,?,?,?)`).bind(t.requestID,p.keyID,p.revision,authorities.find(a=>a.keyID===p.keyID)!.publicKeyFingerprintSHA256,p.signatureSHA256)),
  db.prepare('INSERT INTO moderation_operator_enrollment_admissions(enrollment_admission_id,enrollment_request_id,admission_provenance_sha256) VALUES(?,?,?)').bind(t.admissionID,t.requestID,verified.provenanceSHA256),
  db.prepare('INSERT INTO moderation_owner_policies(policy_revision,owner_operator_id,enrollment_admission_id,session_rowid_floor) VALUES(1,?,?,0)').bind(s.operatorID,t.admissionID),
  db.prepare("SELECT json(CASE WHEN EXISTS(SELECT 1 FROM moderation_owner_current_scope_adoptions WHERE enrollment_request_id=?) THEN 'true' ELSE 'denied' END)").bind(t.requestID),
 ];
 // A single atomic batch. An uncertain network outcome is recovered ONLY by
 // readOwnerScopeAdoption; this function never retries writes.
 await db.batch(statements);return verified;
}
export async function readOwnerScopeAdoption(db:D1Database,scope:OwnerReportScope,authorities:readonly LocalEnrollmentOfflineAuthority[]) {
 const row=await db.prepare(`SELECT s.transcript_json,s.approvals_json,q.canonical_request_sha256,a.admission_provenance_sha256
   FROM moderation_owner_current_scope_adoptions s JOIN moderation_operator_enrollment_requests q USING(enrollment_request_id)
   JOIN moderation_operator_enrollment_admissions a USING(enrollment_request_id) WHERE s.scope_sha256=?`)
  .bind(await scopeDigest(validateOwnerReportScope(scope))).first<{transcript_json:string;approvals_json:string;canonical_request_sha256:string;admission_provenance_sha256:string}>();
 if(!row)return fail();const verified=await verifyScopeAdoption(JSON.parse(row.transcript_json),JSON.parse(row.approvals_json),authorities);
 if(verified.canonicalSHA256!==row.canonical_request_sha256||verified.provenanceSHA256!==row.admission_provenance_sha256
  ||verified.scopeSHA256!==await scopeDigest(scope))fail();return verified;
}
