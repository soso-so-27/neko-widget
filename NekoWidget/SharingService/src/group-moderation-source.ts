import { encodeCanonicalFields } from './protocol';

export async function groupModerationSHA(value:Uint8Array):Promise<string> {
 return [...new Uint8Array(await crypto.subtle.digest('SHA-256',new Uint8Array(value).buffer))].map(x=>x.toString(16).padStart(2,'0')).join('');
}
export async function groupCaseReference(reportId:string,key:Uint8Array):Promise<string> {
 if(!/^[A-Za-z0-9_-]{22}$/u.test(reportId)||key.byteLength!==32)throw Error('group_case_reference_invalid');
 const imported=await crypto.subtle.importKey('raw',new Uint8Array(key).buffer,{name:'HMAC',hash:'SHA-256'},false,['sign']);
 const bytes=encodeCanonicalFields(['NW3.MODERATION-OPERATOR.CASE-REFERENCE','1',reportId]);
 return [...new Uint8Array(await crypto.subtle.sign('HMAC',imported,new Uint8Array(bytes).buffer))].map(x=>x.toString(16).padStart(2,'0')).join('');
}
export interface GroupModerationSource {
 schema:'jp.nekowidget.group-moderation-review-source.v1';caseReferenceHmac:string;caseReferenceHmacKeyVersion:1;objectKey:string;
 metadata:{schema:'jp.nekowidget.group-moderation-export.v1';protocolVersion:3;envelopeDomain:'NW3.MODERATION-REPORT';
 algorithm:'X25519-HKDF-SHA256-CHACHA20POLY1305';reportId:string;windowId:string;momentId:string;reporterParticipantId:string;
 reasonCode:string;moderationKeyId:'moderation-v2';ciphertextSize:number;ciphertextSHA256:string;committedAt:number;contentExpiresAt:number};
}
export const groupSourceSQL=`SELECT r.* FROM group_reports r JOIN group_moderation_cases c ON c.report_id=r.id
 WHERE c.case_reference=? AND c.key_version=1 AND r.state='committed' AND r.content_expires_at>unixepoch()
 AND NOT EXISTS(SELECT 1 FROM group_report_object_deletions d WHERE d.report_id=r.id OR d.object_key=r.object_key)`;
export async function readGroupModerationSource(db:D1Database,reference:string):Promise<GroupModerationSource> {
 const r=await db.prepare(groupSourceSQL).bind(reference).first<{id:string;space_id:string;moment_id:string;reporter_participant_id:string;
 reason_code:string;moderation_key_id:string;ciphertext_size:number;ciphertext_sha256:string;object_key:string;committed_at:number;content_expires_at:number}>();
 if(!r||r.moderation_key_id!=='moderation-v2')throw Error('group_source_unavailable');
 return {schema:'jp.nekowidget.group-moderation-review-source.v1',caseReferenceHmac:reference,caseReferenceHmacKeyVersion:1,objectKey:r.object_key,
 metadata:{schema:'jp.nekowidget.group-moderation-export.v1',protocolVersion:3,envelopeDomain:'NW3.MODERATION-REPORT',
 algorithm:'X25519-HKDF-SHA256-CHACHA20POLY1305',reportId:r.id,windowId:r.space_id,momentId:r.moment_id,reporterParticipantId:r.reporter_participant_id,
 reasonCode:r.reason_code,moderationKeyId:'moderation-v2',ciphertextSize:r.ciphertext_size,ciphertextSHA256:r.ciphertext_sha256,
 committedAt:r.committed_at,contentExpiresAt:r.content_expires_at}};
}
export async function groupSourceSHA(source:GroupModerationSource):Promise<string> {
 const m=source.metadata;
 return groupModerationSHA(new TextEncoder().encode(JSON.stringify([source.schema,source.caseReferenceHmacKeyVersion,source.caseReferenceHmac,
 source.objectKey,m.schema,m.protocolVersion,m.envelopeDomain,m.algorithm,m.reportId,m.windowId,m.momentId,m.reporterParticipantId,
 m.reasonCode,m.moderationKeyId,m.ciphertextSize,m.ciphertextSHA256,m.committedAt,m.contentExpiresAt])));
}
