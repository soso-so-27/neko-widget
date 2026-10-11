-- An explicit trusted, offline-approved scope adoption. This creates NO grant,
-- authority, policy, credential, gate, or copied ceremony. The writer verifies
-- both Ed25519 signatures; SQL administration remains in the trusted boundary.
CREATE TABLE moderation_owner_scope_installation (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 scope_sha256 TEXT NOT NULL CHECK(length(scope_sha256)=64 AND scope_sha256 NOT GLOB '*[^0-9a-f]*')
) STRICT;
CREATE TABLE moderation_owner_scope_adoption_revocations (
 enrollment_request_id TEXT PRIMARY KEY REFERENCES moderation_owner_scope_adoptions(enrollment_request_id),
 revoked_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TRIGGER moderation_owner_scope_revocation_no_update BEFORE UPDATE ON moderation_owner_scope_adoption_revocations
BEGIN SELECT RAISE(ABORT,'scope revocation is immutable'); END;
CREATE TRIGGER moderation_owner_scope_revocation_no_delete BEFORE DELETE ON moderation_owner_scope_adoption_revocations
BEGIN SELECT RAISE(ABORT,'scope revocation is immutable'); END;
CREATE TABLE moderation_owner_scope_adoptions (
 enrollment_request_id TEXT PRIMARY KEY REFERENCES moderation_operator_enrollment_requests(enrollment_request_id),
 scope_sha256 TEXT NOT NULL,
 source_database_id TEXT NOT NULL CHECK(length(source_database_id)=36),
 source_admission_id TEXT NOT NULL CHECK(length(source_admission_id)=36),
 source_provenance_sha256 TEXT NOT NULL CHECK(length(source_provenance_sha256)=64),
 counter_floor INTEGER NOT NULL CHECK(counter_floor BETWEEN 0 AND 4294967295),
 transcript_json TEXT NOT NULL CHECK(json_valid(transcript_json)),
 approvals_json TEXT NOT NULL CHECK(json_valid(approvals_json) AND json_array_length(approvals_json)=2),
 approved_until INTEGER NOT NULL,
 recorded_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TRIGGER moderation_owner_scope_installation_no_update BEFORE UPDATE ON moderation_owner_scope_installation
BEGIN SELECT RAISE(ABORT,'scope installation is immutable'); END;
CREATE TRIGGER moderation_owner_scope_installation_no_delete BEFORE DELETE ON moderation_owner_scope_installation
BEGIN SELECT RAISE(ABORT,'scope installation is immutable'); END;
CREATE TRIGGER moderation_owner_scope_adoption_no_update BEFORE UPDATE ON moderation_owner_scope_adoptions
BEGIN SELECT RAISE(ABORT,'scope adoption is immutable'); END;
CREATE TRIGGER moderation_owner_scope_adoption_no_delete BEFORE DELETE ON moderation_owner_scope_adoptions
BEGIN SELECT RAISE(ABORT,'scope adoption is immutable'); END;
CREATE TRIGGER moderation_owner_scope_adoption_insert BEFORE INSERT ON moderation_owner_scope_adoptions
BEGIN
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch() OR NEW.approved_until<=unixepoch()
  OR NEW.approved_until>unixepoch()+900
  OR NOT EXISTS(SELECT 1 FROM moderation_owner_scope_installation WHERE scope_sha256=NEW.scope_sha256)
  OR EXISTS(SELECT 1 FROM moderation_operator_enrollment_admissions)
  OR EXISTS(SELECT 1 FROM moderation_owner_scope_adoptions)
 THEN RAISE(ABORT,'scope adoption unavailable') END);
END;
CREATE VIEW moderation_owner_current_scope_adoptions AS
SELECT s.*,q.target_operator_id,q.target_credential_id_sha256
FROM moderation_owner_scope_adoptions s
JOIN moderation_owner_scope_installation i ON i.scope_sha256=s.scope_sha256
JOIN moderation_operator_enrollment_requests q USING(enrollment_request_id)
JOIN moderation_operator_enrollment_admissions a USING(enrollment_request_id)
WHERE a.admitted_at<=s.approved_until
 AND (SELECT COUNT(*) FROM moderation_operator_enrollment_offline_approvals p WHERE p.enrollment_request_id=q.enrollment_request_id)=2
 AND NOT EXISTS(SELECT 1 FROM json_each(s.approvals_json) j WHERE NOT EXISTS(
   SELECT 1 FROM moderation_operator_enrollment_offline_approvals p
   JOIN moderation_operator_enrollment_offline_authorities k ON k.offline_authority_key_id=p.offline_authority_key_id
    AND k.authority_policy_revision=p.authority_policy_revision
    AND k.authority_public_key_fingerprint_sha256=p.authority_public_key_fingerprint_sha256
   WHERE p.enrollment_request_id=q.enrollment_request_id
    AND p.offline_authority_key_id=json_extract(j.value,'$.keyID')
    AND p.authority_policy_revision=json_extract(j.value,'$.revision')
    AND p.authority_signature_sha256=json_extract(j.value,'$.signatureSHA256')
    AND k.authority_policy_revision=(SELECT MAX(authority_policy_revision) FROM moderation_operator_enrollment_offline_authorities WHERE offline_authority_key_id=k.offline_authority_key_id)))
 AND NOT EXISTS(SELECT 1 FROM moderation_owner_scope_adoption_revocations r WHERE r.enrollment_request_id=s.enrollment_request_id);
CREATE TRIGGER moderation_owner_scope_admission_guard BEFORE INSERT ON moderation_operator_enrollment_admissions
WHEN EXISTS(SELECT 1 FROM moderation_owner_scope_installation)
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM moderation_owner_scope_adoptions s
  WHERE s.enrollment_request_id=NEW.enrollment_request_id AND s.approved_until>unixepoch())
 THEN RAISE(ABORT,'scope admission requires new scope evidence') END);
END;
-- Keep original registration counters truthful. Transferred counters are a
-- separate floor and every new proof still uses the existing verified counter.
DROP VIEW moderation_operator_credential_counters;
CREATE VIEW moderation_operator_credential_counters AS
SELECT credential_id_sha256, MAX(sign_count) AS sign_count FROM (
 SELECT credential_id_sha256,registration_sign_count AS sign_count FROM moderation_operator_credentials
 UNION ALL SELECT credential_id_sha256,authenticator_sign_count FROM moderation_operator_challenge_consumptions
 UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM moderation_owner_challenge_consumptions r JOIN moderation_owner_challenges c USING(challenge_id)
 UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM moderation_resolution_consumptions r JOIN moderation_resolution_challenges c USING(challenge_id)
 UNION ALL SELECT q.target_credential_id_sha256,s.counter_floor FROM moderation_owner_scope_adoptions s JOIN moderation_operator_enrollment_requests q USING(enrollment_request_id)
) GROUP BY credential_id_sha256;
