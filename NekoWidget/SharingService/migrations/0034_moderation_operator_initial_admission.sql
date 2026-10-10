-- Trusted local initial-admission writer. Empty migration: no identity, role,
-- authority, activation, admission, session, route or gate is provisioned.
-- 0017 guards remain unchanged. This bridge adds durable 0033 ceremony, full
-- role-set and authority-set binding; SQL administrators remain trusted.
CREATE TABLE moderation_operator_initial_enrollment_bindings (
 enrollment_request_id TEXT PRIMARY KEY REFERENCES moderation_operator_enrollment_requests(enrollment_request_id) ON DELETE RESTRICT,
 ceremony_id TEXT NOT NULL UNIQUE REFERENCES moderation_operator_enrollment_ceremony_possessions(ceremony_id) ON DELETE RESTRICT,
 installation_scope_sha256 TEXT NOT NULL CHECK(length(installation_scope_sha256)=64 AND installation_scope_sha256 NOT GLOB '*[^0-9a-f]*'),
 authority_set_sha256 TEXT NOT NULL CHECK(length(authority_set_sha256)=64 AND authority_set_sha256 NOT GLOB '*[^0-9a-f]*'),
 role_snapshot_sha256 TEXT NOT NULL CHECK(length(role_snapshot_sha256)=64 AND role_snapshot_sha256 NOT GLOB '*[^0-9a-f]*'),
 roles_json TEXT NOT NULL CHECK(json_valid(roles_json) AND json_type(roles_json)='array'),
 authorities_json TEXT NOT NULL CHECK(json_valid(authorities_json) AND json_type(authorities_json)='array')
) STRICT;
CREATE TABLE moderation_operator_initial_enrollment_attempts (
 enrollment_request_id TEXT PRIMARY KEY REFERENCES moderation_operator_initial_enrollment_bindings(enrollment_request_id) ON DELETE RESTRICT,
 attempt_id TEXT NOT NULL UNIQUE CHECK(length(attempt_id)=36),
 attempted_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;
-- An attempt alone may still be running. Only an explicit terminal failure or
-- expiry permits a new ceremony to supersede its unadmitted credential staging.
CREATE TABLE moderation_operator_initial_enrollment_failures (
 enrollment_request_id TEXT PRIMARY KEY REFERENCES moderation_operator_initial_enrollment_attempts(enrollment_request_id) ON DELETE RESTRICT,
 attempt_id TEXT NOT NULL UNIQUE REFERENCES moderation_operator_initial_enrollment_attempts(attempt_id) ON DELETE RESTRICT,
 failed_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE VIEW moderation_operator_initial_enrollment_current AS
 SELECT b.* FROM moderation_operator_initial_enrollment_bindings b
 JOIN moderation_operator_enrollment_requests q USING(enrollment_request_id)
 JOIN moderation_operator_enrollment_ceremonies c USING(ceremony_id)
 JOIN moderation_operator_enrollment_ceremony_registrations r USING(ceremony_id)
 JOIN moderation_operator_enrollment_ceremony_possessions p USING(ceremony_id)
 WHERE c.issued_at<=unixepoch() AND c.expires_at>unixepoch() AND c.access_issued_at<=unixepoch() AND c.access_expires_at>unixepoch()
 AND q.requested_at<=unixepoch() AND q.expires_at>unixepoch() AND q.expires_at=c.expires_at
 AND NOT EXISTS(SELECT 1 FROM moderation_operator_enrollment_admissions)
 AND NOT EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_failures WHERE enrollment_request_id=q.enrollment_request_id)
 AND NOT EXISTS(SELECT 1 FROM moderation_operator_access_sessions WHERE operator_id=c.operator_id OR access_session_sha256=c.access_session_sha256)
 AND EXISTS(SELECT 1 FROM moderation_operator_subject_identities i WHERE i.operator_id=c.operator_id AND i.access_subject_hmac_key_version=c.access_subject_hmac_key_version AND i.access_subject_hmac=c.access_subject_hmac)
 AND NOT EXISTS(SELECT 1 FROM moderation_operator_subject_identities i WHERE i.operator_id=c.operator_id AND i.access_subject_hmac_key_version>c.access_subject_hmac_key_version)
 AND EXISTS(SELECT 1 FROM moderation_operator_state_events WHERE operator_id=c.operator_id AND event_type='activated')
 AND NOT EXISTS(SELECT 1 FROM moderation_operator_state_events WHERE operator_id=c.operator_id AND event_type='revoked')
 AND EXISTS(SELECT 1 FROM moderation_operator_credentials k WHERE k.credential_id_sha256=r.credential_id_sha256 AND k.operator_id=c.operator_id AND k.public_key_cose=r.public_key_cose AND k.registration_sign_count=r.registration_sign_count)
 AND NOT EXISTS(SELECT 1 FROM moderation_operator_credentials k
  WHERE k.operator_id=c.operator_id AND k.credential_id_sha256<>r.credential_id_sha256
   AND (NOT EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_bindings old_b
     JOIN moderation_operator_enrollment_requests old_q USING(enrollment_request_id)
     JOIN moderation_operator_enrollment_ceremonies old_c USING(ceremony_id)
     JOIN moderation_operator_enrollment_ceremony_registrations old_r USING(ceremony_id)
     JOIN moderation_operator_enrollment_ceremony_possessions old_p USING(ceremony_id)
     WHERE old_q.target_credential_id_sha256=k.credential_id_sha256 AND old_c.operator_id=k.operator_id
      AND old_r.credential_id_sha256=k.credential_id_sha256 AND old_r.public_key_cose=k.public_key_cose
      AND old_r.registration_sign_count=k.registration_sign_count AND old_p.credential_id_sha256=k.credential_id_sha256)
    OR EXISTS(SELECT 1 FROM moderation_operator_enrollment_requests old_q WHERE old_q.target_credential_id_sha256=k.credential_id_sha256
     AND (NOT EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_bindings old_b WHERE old_b.enrollment_request_id=old_q.enrollment_request_id)
       OR EXISTS(SELECT 1 FROM moderation_operator_enrollment_admissions old_a WHERE old_a.enrollment_request_id=old_q.enrollment_request_id)
       OR (old_q.expires_at>unixepoch() AND NOT EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_failures f WHERE f.enrollment_request_id=old_q.enrollment_request_id))))))
 AND EXISTS(SELECT 1 FROM moderation_operator_credential_events WHERE credential_id_sha256=r.credential_id_sha256 AND event_type='registered')
 AND NOT EXISTS(SELECT 1 FROM moderation_operator_credential_events WHERE credential_id_sha256=r.credential_id_sha256 AND event_type='revoked')
 AND json_array_length(b.roles_json) BETWEEN 1 AND 5
 AND (SELECT COUNT(DISTINCT value) FROM json_each(b.roles_json))=json_array_length(b.roles_json)
 AND EXISTS(SELECT 1 FROM json_each(b.roles_json) WHERE value='security_admin')
 AND NOT EXISTS(SELECT 1 FROM json_each(b.roles_json) j WHERE j.type<>'text' OR j.value NOT IN ('triage','evidence_reviewer','privacy_approver','auditor','security_admin')
   OR NOT EXISTS(SELECT 1 FROM moderation_operator_role_events g WHERE g.operator_id=c.operator_id AND g.role_code=j.value AND g.event_type='granted')
   OR EXISTS(SELECT 1 FROM moderation_operator_role_events x WHERE x.operator_id=c.operator_id AND x.role_code=j.value AND x.event_type='revoked'))
 AND NOT EXISTS(SELECT 1 FROM moderation_operator_role_events g WHERE g.operator_id=c.operator_id AND g.event_type='granted'
   AND NOT EXISTS(SELECT 1 FROM moderation_operator_role_events x WHERE x.operator_id=g.operator_id AND x.role_code=g.role_code AND x.event_type='revoked')
   AND NOT EXISTS(SELECT 1 FROM json_each(b.roles_json) j WHERE j.value=g.role_code))
 AND json_array_length(b.authorities_json)=2
 AND (SELECT COUNT(DISTINCT json_extract(value,'$.keyID')) FROM json_each(b.authorities_json))=2
 AND NOT EXISTS(SELECT 1 FROM json_each(b.authorities_json) j WHERE NOT EXISTS(
   SELECT 1 FROM moderation_operator_enrollment_offline_authorities a
   WHERE a.offline_authority_key_id=json_extract(j.value,'$.keyID') AND a.authority_policy_revision=json_extract(j.value,'$.revision')
    AND a.authority_public_key_fingerprint_sha256=json_extract(j.value,'$.publicKeyFingerprintSHA256') AND a.authorized_at=json_extract(j.value,'$.authorizedAt')
    AND a.authorized_at<=c.issued_at
    AND NOT EXISTS(SELECT 1 FROM moderation_operator_enrollment_offline_authorities n WHERE n.offline_authority_key_id=a.offline_authority_key_id AND n.authority_policy_revision>a.authority_policy_revision)))
 AND NOT EXISTS(SELECT 1 FROM moderation_operator_enrollment_offline_authorities a
   WHERE NOT EXISTS(SELECT 1 FROM moderation_operator_enrollment_offline_authorities n WHERE n.offline_authority_key_id=a.offline_authority_key_id AND n.authority_policy_revision>a.authority_policy_revision)
   AND NOT EXISTS(SELECT 1 FROM json_each(b.authorities_json) j WHERE json_extract(j.value,'$.keyID')=a.offline_authority_key_id));

CREATE TRIGGER moderation_operator_initial_binding_validate BEFORE INSERT ON moderation_operator_initial_enrollment_bindings
BEGIN
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_bindings WHERE enrollment_request_id=NEW.enrollment_request_id OR ceremony_id=NEW.ceremony_id)
  OR NOT EXISTS(SELECT 1 FROM moderation_operator_enrollment_requests q
    JOIN moderation_operator_enrollment_ceremonies c ON c.ceremony_id=NEW.ceremony_id
    JOIN moderation_operator_enrollment_ceremony_registrations r USING(ceremony_id)
    JOIN moderation_operator_enrollment_ceremony_possessions p USING(ceremony_id)
    WHERE q.enrollment_request_id=NEW.enrollment_request_id AND q.enrollment_kind='initial_bootstrap'
     AND q.request_schema_version=1 AND q.target_operator_id=c.operator_id
     AND q.target_access_subject_hmac_key_version=c.access_subject_hmac_key_version AND q.target_access_subject_hmac=c.access_subject_hmac
     AND q.target_credential_id_sha256=r.credential_id_sha256 AND q.target_public_key_cose_sha256=r.public_key_cose_sha256
     AND q.target_public_key_cose_snapshot=r.public_key_cose AND q.target_registration_sign_count=r.registration_sign_count
     AND q.attestation_evidence_sha256=r.registration_sha256 AND q.attestation_policy_revision=1 AND q.authenticator_aaguid_sha256=r.authenticator_aaguid_sha256
     AND q.expires_at=c.expires_at AND NEW.installation_scope_sha256=c.installation_scope_sha256 AND NEW.authority_set_sha256=c.authority_set_sha256)
  THEN RAISE(ABORT,'initial enrollment binding unavailable') END);
END;
CREATE TRIGGER moderation_operator_initial_binding_current AFTER INSERT ON moderation_operator_initial_enrollment_bindings
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_current WHERE enrollment_request_id=NEW.enrollment_request_id)
  THEN RAISE(ABORT,'initial enrollment target unavailable') END);
END;
CREATE TRIGGER moderation_operator_initial_attempt_validate BEFORE INSERT ON moderation_operator_initial_enrollment_attempts
BEGIN
 SELECT (CASE WHEN NEW.attempted_at<>unixepoch() OR EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_attempts WHERE enrollment_request_id=NEW.enrollment_request_id OR attempt_id=NEW.attempt_id)
  OR NOT EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_current WHERE enrollment_request_id=NEW.enrollment_request_id)
  THEN RAISE(ABORT,'initial enrollment attempt unavailable') END);
END;
CREATE TRIGGER moderation_operator_initial_failure_validate BEFORE INSERT ON moderation_operator_initial_enrollment_failures
BEGIN
 SELECT (CASE WHEN NEW.failed_at<>unixepoch()
  OR EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_failures WHERE enrollment_request_id=NEW.enrollment_request_id OR attempt_id=NEW.attempt_id)
  OR EXISTS(SELECT 1 FROM moderation_operator_enrollment_admissions WHERE enrollment_request_id=NEW.enrollment_request_id)
  OR NOT EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_attempts WHERE enrollment_request_id=NEW.enrollment_request_id AND attempt_id=NEW.attempt_id)
  THEN RAISE(ABORT,'initial enrollment terminal failure unavailable') END);
END;
CREATE TRIGGER moderation_operator_initial_approval_guard BEFORE INSERT ON moderation_operator_enrollment_offline_approvals
WHEN EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_bindings WHERE enrollment_request_id=NEW.enrollment_request_id)
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_current v JOIN moderation_operator_initial_enrollment_attempts a USING(enrollment_request_id)
  WHERE v.enrollment_request_id=NEW.enrollment_request_id)
  THEN RAISE(ABORT,'initial enrollment approval unavailable') END);
END;
CREATE TRIGGER moderation_operator_initial_admission_guard BEFORE INSERT ON moderation_operator_enrollment_admissions
WHEN EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_bindings WHERE enrollment_request_id=NEW.enrollment_request_id)
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM moderation_operator_initial_enrollment_current v JOIN moderation_operator_initial_enrollment_attempts a USING(enrollment_request_id)
  WHERE v.enrollment_request_id=NEW.enrollment_request_id
   AND (SELECT COUNT(*) FROM moderation_operator_enrollment_offline_approvals x WHERE x.enrollment_request_id=v.enrollment_request_id)=2
   AND NOT EXISTS(SELECT 1 FROM json_each(v.authorities_json) j WHERE NOT EXISTS(
    SELECT 1 FROM moderation_operator_enrollment_offline_approvals x WHERE x.enrollment_request_id=v.enrollment_request_id
     AND x.offline_authority_key_id=json_extract(j.value,'$.keyID') AND x.authority_policy_revision=json_extract(j.value,'$.revision')
     AND x.authority_public_key_fingerprint_sha256=json_extract(j.value,'$.publicKeyFingerprintSHA256'))))
  THEN RAISE(ABORT,'initial enrollment final boundary unavailable') END);
END;

CREATE TRIGGER moderation_operator_initial_binding_no_update BEFORE UPDATE ON moderation_operator_initial_enrollment_bindings
BEGIN SELECT RAISE(ABORT,'initial enrollment evidence is immutable'); END;

CREATE TRIGGER moderation_operator_initial_binding_no_delete BEFORE DELETE ON moderation_operator_initial_enrollment_bindings
BEGIN SELECT RAISE(ABORT,'initial enrollment evidence is immutable'); END;

CREATE TRIGGER moderation_operator_initial_attempt_no_update BEFORE UPDATE ON moderation_operator_initial_enrollment_attempts
BEGIN SELECT RAISE(ABORT,'initial enrollment evidence is immutable'); END;

CREATE TRIGGER moderation_operator_initial_attempt_no_delete BEFORE DELETE ON moderation_operator_initial_enrollment_attempts
BEGIN SELECT RAISE(ABORT,'initial enrollment evidence is immutable'); END;

CREATE TRIGGER moderation_operator_initial_failure_no_update BEFORE UPDATE ON moderation_operator_initial_enrollment_failures
BEGIN SELECT RAISE(ABORT,'initial enrollment evidence is immutable'); END;

CREATE TRIGGER moderation_operator_initial_failure_no_delete BEFORE DELETE ON moderation_operator_initial_enrollment_failures
BEGIN SELECT RAISE(ABORT,'initial enrollment evidence is immutable'); END;
