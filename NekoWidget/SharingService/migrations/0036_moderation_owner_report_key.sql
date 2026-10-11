-- Once an explicit owner scope is installed, new ciphertext must use its
-- reviewed key. Keep cleanup and existing content readable when grants revoke.
CREATE TRIGGER moderation_owner_report_key_insert BEFORE INSERT ON moment_reports
WHEN EXISTS(SELECT 1 FROM moderation_owner_scope_installation)
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM moderation_owner_current_scope_adoptions s
  JOIN moderation_owner_current_policies p ON p.owner_operator_id=s.target_operator_id AND p.credential_id_sha256=s.target_credential_id_sha256
  JOIN moderation_operator_enrollment_admissions a ON a.enrollment_admission_id=p.enrollment_admission_id AND a.enrollment_request_id=s.enrollment_request_id
  WHERE json_extract(s.transcript_json,'$.target.moderationKeyId')=NEW.moderation_key_id)
 THEN RAISE(ABORT,'current report key required') END);
END;
CREATE TRIGGER moderation_owner_report_key_upload_commit BEFORE UPDATE OF state ON moment_reports
WHEN NEW.state IN ('uploaded','committed') AND EXISTS(SELECT 1 FROM moderation_owner_scope_installation)
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM moderation_owner_current_scope_adoptions s
  JOIN moderation_owner_current_policies p ON p.owner_operator_id=s.target_operator_id AND p.credential_id_sha256=s.target_credential_id_sha256
  JOIN moderation_operator_enrollment_admissions a ON a.enrollment_admission_id=p.enrollment_admission_id AND a.enrollment_request_id=s.enrollment_request_id
  WHERE json_extract(s.transcript_json,'$.target.moderationKeyId')=NEW.moderation_key_id)
 THEN RAISE(ABORT,'current report key required') END);
END;
