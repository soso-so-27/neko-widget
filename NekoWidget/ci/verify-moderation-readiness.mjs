import {createHash,createPublicKey,verify} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root=path.resolve(import.meta.dirname,'../..');
export const codePaths=Object.freeze([
 '.github/workflows/testflight.yml',
 'NekoWidget/ci/moderation_readiness.py','NekoWidget/ci/verify-moderation-readiness.mjs','NekoWidget/ci/write-moderation-release-metadata.py',
 'NekoWidget/ci/internal_report_release.py','NekoWidget/ci/release-testflight.py',
 'NekoWidget/ci/verify-moderation-upload-payload.py','NekoWidget/ci/verify-signed-artifact-contents.py',
 'NekoWidget/Shared/Sharing/SharingAPIConfiguration.swift','NekoWidget/NekoWidget/Views/FamilyWindowView.swift',
 'NekoWidget/NekoWidget/Info.plist','NekoWidget/NekoWidgetShareExtension/Info.plist','NekoWidget/NekoWidgetWidget/Info.plist',
 'NekoWidget/SharingService/scripts/check-staging-runtime.mjs','NekoWidget/SharingService/scripts/staging-runtime-check-lib.mjs',
 'NekoWidget/SharingService/migrations/0035_moderation_owner_scope_adoption.sql','NekoWidget/SharingService/migrations/0036_moderation_owner_report_key.sql',
 'NekoWidget/SharingService/migrations/0037_moderation_enrollment_counter_floor.sql',
 'NekoWidget/SharingService/migrations/0049_moderation_review_duration.sql',
 'NekoWidget/SharingService/src/moderation-owner-scope-adoption.ts','NekoWidget/SharingService/src/moderation-operator-identity.ts',
 'NekoWidget/SharingService/src/moderation-owner-local.ts','NekoWidget/SharingService/src/moderation-owner-console.ts',
 'NekoWidget/SharingService/src/moderation-report-key-policy.ts','NekoWidget/SharingService/src/moments.ts',
 'NekoWidget/SharingService/scripts/moderation-operator-staging-start.mjs','NekoWidget/SharingService/scripts/moderation-operator-local-server.mjs',
 'NekoWidget/SharingService/scripts/moderation-owner-r2-transport.mjs','NekoWidget/SharingService/scripts/moderation-owner-key-check-broker-windows.ps1',
 'NekoWidget/SharingService/scripts/moderation-owner-key-check-client-windows.ps1','NekoWidget/SharingService/scripts/moderation-staging-keygen-windows-security.ps1'
]);
const authorities=Object.freeze({
 'neko-local-bootstrap-authority-01':'Wd0rcX9WM66ONRHlSrJSwvuDDsnUw8vm5SO3fyJJeuE',
 'neko-local-bootstrap-authority-02':'J5CFzPEMN9OKUe5wc6yGV3l8Me770LAG7rZh-qSwVcg'
});
export function canonical(value){
 if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
 if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';
 return JSON.stringify(value);
}
export const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
export async function codeHashes(){return Object.fromEntries(await Promise.all(codePaths.map(async p=>[p,hash((await readFile(path.join(root,p),'utf8')).replaceAll('\r\n','\n'))])))}
const requireValue=(ok,message)=>{if(!ok)throw Error(message)};
const exact=(value,fields)=>requireValue(value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).sort().join(',')===[...fields].sort().join(','),'unexpected_fields');
const hex=value=>typeof value==='string'&&/^[0-9a-f]{64}$/u.test(value);
export async function verifyReadiness(evidence,policy,now=Date.now()){
 exact(evidence,['payload','signatures']);const p=evidence.payload;
 exact(p,['schema','purpose','issuedAtMs','expiresAtMs','policyRevision','keyID','publicKeySHA256','trustManifestRevision','trustManifestSHA256','target','scopeSHA256','v1ReportCount','unresolvedReportObjects','reportIntakeEnabled','reportKeyPolicyTriggers','nativeCustodyVerified','backupRestoreVerified','v1HistoricalIntakeVerified','productionApproved','cloudImage','readReceiptSHA256','sourceSnapshotSHA256','readPhases','resolution','recipientReadVerified','realUserPhotoVerified','evidenceSHA256','codeSHA256']);
 const firstConnection=p.purpose==='testflight-owner-first-connection';
 const uiContinuation=p.purpose==='testflight-owner-report-ui-continuation';
 requireValue(p.schema==='jp.nekowidget.moderation-owner-v2-readiness.v1'&&(firstConnection||uiContinuation),'unsupported_purpose');
 requireValue(Number.isSafeInteger(p.issuedAtMs)&&Number.isSafeInteger(p.expiresAtMs)&&p.issuedAtMs<=now+30000&&now<p.expiresAtMs&&p.expiresAtMs>p.issuedAtMs&&p.expiresAtMs-p.issuedAtMs<=86400000,'stale_readiness');
 requireValue(p.keyID==='moderation-v2'&&policy.clientKeyId===p.keyID&&policy.v2ClientReleaseAllowed===true&&hex(p.publicKeySHA256)&&p.publicKeySHA256===policy.clientPublicKeySha256&&p.policyRevision===policy.revision&&p.trustManifestRevision===policy.trustManifestRevision&&p.trustManifestSHA256===policy.trustManifestSha256,'rollout_binding_mismatch');
 exact(p.target,['accountID','databaseID','serviceIdentity','reportBucket','origin','rpId','apiOrigin']);
 const target={accountID:'829a34ef925a39d81b0e9e08800d7c7f',databaseID:'cb3b2386-3a6f-4253-b918-8aafed9ff735',serviceIdentity:'neko-window-sharing-staging',reportBucket:'neko-window-sharing-staging-moderation-private',origin:'https://neko-operator.trade-solo.com',rpId:'neko-operator.trade-solo.com',apiOrigin:'https://neko-window-sharing-staging.nakanishisoya.workers.dev'};
 requireValue(canonical(p.target)===canonical(target),'target_mismatch');
 requireValue(p.scopeSHA256==='1fa03eb65a5fc3002e6fb48824d1814eb60390e57c8e40852c5586c3071fdf9a','owner_adoption_mismatch');
 // Preserve the original intake-OFF admission boundary. A separately signed
 // UI continuation records an already enabled intake; it cannot enable it.
 requireValue(p.v1ReportCount===0&&p.unresolvedReportObjects===0&&p.reportIntakeEnabled===uiContinuation&&p.reportKeyPolicyTriggers===2&&p.nativeCustodyVerified===true&&p.backupRestoreVerified===false&&p.v1HistoricalIntakeVerified===false&&p.productionApproved===false&&p.recipientReadVerified===false&&p.realUserPhotoVerified===false,'readiness_boundary_mismatch');
 exact(p.cloudImage,['complete','width','height','visible']);
 requireValue(p.cloudImage.complete===true&&p.cloudImage.width===1&&p.cloudImage.height===1&&p.cloudImage.visible===true&&canonical(p.readPhases)===canonical(['started','disclosure_ready'])&&p.resolution==='no_action','cloud_drill_incomplete');
 requireValue([p.scopeSHA256,p.readReceiptSHA256,p.sourceSnapshotSHA256].every(hex),'invalid_evidence_binding');
 exact(p.evidenceSHA256,['cloudObservation','photoScreenshot','decisionScreenshot','custodyProbe','scopeApply','keyPolicyApply']);
 requireValue(Object.values(p.evidenceSHA256).every(hex),'invalid_evidence_hash');
 exact(p.codeSHA256,codePaths);requireValue(Object.values(p.codeSHA256).every(hex),'invalid_code_hash');
 requireValue(canonical(p.codeSHA256)===canonical(await codeHashes()),'reviewed_code_changed');
 requireValue(Array.isArray(evidence.signatures)&&evidence.signatures.length===2,'two_signatures_required');
 const seen=new Set();
 for(const s of evidence.signatures){
  exact(s,['keyID','revision','signatureBase64url']);requireValue(s.revision===1&&Object.hasOwn(authorities,s.keyID)&&!seen.has(s.keyID)&&typeof s.signatureBase64url==='string'&&/^[A-Za-z0-9_-]{86}$/u.test(s.signatureBase64url),'invalid_authority');seen.add(s.keyID);
  const signature=Buffer.from(s.signatureBase64url,'base64url');requireValue(signature.length===64&&signature.toString('base64url')===s.signatureBase64url,'invalid_signature_encoding');
  const key=createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),Buffer.from(authorities[s.keyID],'base64url')]),format:'der',type:'spki'});
  requireValue(verify(null,Buffer.from(canonical(p),'ascii'),key,signature),'invalid_signature');
 }
 return {verified:true,purpose:p.purpose,publicKeySHA256:p.publicKeySHA256,expiresAtMs:p.expiresAtMs};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{let input='';for await(const chunk of process.stdin){input+=chunk;if(input.length>65536)throw Error('input_too_large')};const value=JSON.parse(input);exact(value,['policy','evidence']);console.log(JSON.stringify(await verifyReadiness(value.evidence,value.policy)))}
 catch(e){console.error(e.message);process.exitCode=1}
}
