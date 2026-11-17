import { encodeCanonicalFields } from './protocol';

export async function familyPhotoModerationSHA(value:Uint8Array):Promise<string> {
 return [...new Uint8Array(await crypto.subtle.digest('SHA-256',new Uint8Array(value).buffer))].map(x=>x.toString(16).padStart(2,'0')).join('');
}
export async function familyPhotoCaseReference(reportId:string,key:Uint8Array):Promise<string> {
 if(!/^[A-Za-z0-9_-]{22}$/u.test(reportId)||key.byteLength!==32)throw Error('group_case_reference_invalid');
 const imported=await crypto.subtle.importKey('raw',new Uint8Array(key).buffer,{name:'HMAC',hash:'SHA-256'},false,['sign']);
 const bytes=encodeCanonicalFields(['NW3.FAMILY-PHOTO.MODERATION-OPERATOR.CASE-REFERENCE','1',reportId]);
 return [...new Uint8Array(await crypto.subtle.sign('HMAC',imported,new Uint8Array(bytes).buffer))].map(x=>x.toString(16).padStart(2,'0')).join('');
}
export interface FamilyPhotoModerationSource {
 schema:'jp.nekowidget.family-photo-moderation-review-source.v1';caseReferenceHmac:string;caseReferenceHmacKeyVersion:1;objectKey:string;
 metadata:{schema:'jp.nekowidget.family-photo-moderation-export.v1';protocolVersion:1;envelopeDomain:'NW3.FAMILY-PHOTO.MODERATION-REPORT';
 algorithm:'X25519-HKDF-SHA256-CHACHA20POLY1305';reportId:string;familyId:string;assetId:string;reporterPersonId:string;
 reasonCode:string;moderationKeyId:'moderation-v2';ciphertextSize:number;ciphertextSHA256:string;committedAt:number;contentExpiresAt:number};
}
export const familyPhotoSourceSQL=`SELECT r.* FROM family_photo_reports r JOIN family_photo_moderation_cases c ON c.report_id=r.report_id
 WHERE c.case_reference=? AND c.key_version=1 AND r.state='committed' AND r.content_expires_at>unixepoch()`;
export async function readFamilyPhotoModerationSource(db:D1Database,reference:string):Promise<FamilyPhotoModerationSource> {
 const r=await db.prepare(familyPhotoSourceSQL).bind(reference).first<{report_id:string;family_id:string;asset_id:string;reporter_person_id:string;
 reason_code:string;moderation_key_id:string;ciphertext_size:number;ciphertext_sha256:string;object_key:string;committed_at:number;content_expires_at:number}>();
 if(!r||r.moderation_key_id!=='moderation-v2')throw Error('group_source_unavailable');
 return {schema:'jp.nekowidget.family-photo-moderation-review-source.v1',caseReferenceHmac:reference,caseReferenceHmacKeyVersion:1,objectKey:r.object_key,
 metadata:{schema:'jp.nekowidget.family-photo-moderation-export.v1',protocolVersion:1,envelopeDomain:'NW3.FAMILY-PHOTO.MODERATION-REPORT',
 algorithm:'X25519-HKDF-SHA256-CHACHA20POLY1305',reportId:r.report_id,familyId:r.family_id,assetId:r.asset_id,reporterPersonId:r.reporter_person_id,
 reasonCode:r.reason_code,moderationKeyId:'moderation-v2',ciphertextSize:r.ciphertext_size,ciphertextSHA256:r.ciphertext_sha256,
 committedAt:r.committed_at,contentExpiresAt:r.content_expires_at}};
}
export async function familyPhotoSourceSHA(source:FamilyPhotoModerationSource):Promise<string> {
 const m=source.metadata;
 return familyPhotoModerationSHA(new TextEncoder().encode(JSON.stringify([source.schema,source.caseReferenceHmacKeyVersion,source.caseReferenceHmac,
 source.objectKey,m.schema,m.protocolVersion,m.envelopeDomain,m.algorithm,m.reportId,m.familyId,m.assetId,m.reporterPersonId,
 m.reasonCode,m.moderationKeyId,m.ciphertextSize,m.ciphertextSHA256,m.committedAt,m.contentExpiresAt])));
}
