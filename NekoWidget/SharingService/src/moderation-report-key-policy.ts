/** Existing installations retain their reviewed legacy behavior. An explicit
 * owner cloud scope accepts only the key whose decryptor was adopted there. */
export async function currentModerationReportKey(db:D1Database,keyID:string):Promise<boolean>{
 const row=await db.prepare(`SELECT (NOT EXISTS(SELECT 1 FROM moderation_owner_scope_installation)
  OR EXISTS(SELECT 1 FROM moderation_owner_current_scope_adoptions s
   JOIN moderation_owner_current_policies p ON p.owner_operator_id=s.target_operator_id AND p.credential_id_sha256=s.target_credential_id_sha256
   JOIN moderation_operator_enrollment_admissions a ON a.enrollment_admission_id=p.enrollment_admission_id AND a.enrollment_request_id=s.enrollment_request_id
   WHERE json_extract(s.transcript_json,'$.target.moderationKeyId')=?)) AS allowed`).bind(keyID).first<{allowed:number}>();
 return row?.allowed===1;
}
