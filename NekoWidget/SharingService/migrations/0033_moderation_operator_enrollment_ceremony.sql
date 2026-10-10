-- Local trusted-host ceremony only: no operator, role, admission or route is created.
-- Raw browser responses, challenge bytes, credential IDs, Access JWTs/subjects and
-- private keys are absent. Public COSE and digest-only receipts are retained.
-- As with 0017, a database administrator is inside the trusted computing base;
-- SQL records verified results, it does not itself verify signatures or hashes.
-- Each attempt is committed separately BEFORE cryptography. A failed result
-- transaction cannot roll back that attempt. Losing a response requires a new
-- ceremony; challenge bytes cannot be recovered from this database.

CREATE TABLE moderation_operator_enrollment_ceremonies (
 ceremony_id TEXT NOT NULL PRIMARY KEY CHECK (length(ceremony_id)=36 AND length(CAST(ceremony_id AS BLOB))=36 AND substr(ceremony_id,9,1)='-' AND substr(ceremony_id,14,2)='-4' AND substr(ceremony_id,19,1)='-' AND substr(ceremony_id,20,1) GLOB '[89ab]' AND substr(ceremony_id,24,1)='-' AND length(replace(ceremony_id,'-',''))=32 AND ceremony_id NOT GLOB '*[^0-9a-f-]*'),
 operator_id TEXT NOT NULL  CHECK (length(operator_id)=36 AND length(CAST(operator_id AS BLOB))=36 AND substr(operator_id,9,1)='-' AND substr(operator_id,14,2)='-4' AND substr(operator_id,19,1)='-' AND substr(operator_id,20,1) GLOB '[89ab]' AND substr(operator_id,24,1)='-' AND length(replace(operator_id,'-',''))=32 AND operator_id NOT GLOB '*[^0-9a-f-]*'),
 access_subject_hmac TEXT NOT NULL  CHECK (length(access_subject_hmac)=64 AND length(CAST(access_subject_hmac AS BLOB))=64 AND access_subject_hmac NOT GLOB '*[^0-9a-f]*'),
 access_subject_hmac_key_version INTEGER NOT NULL CHECK(access_subject_hmac_key_version BETWEEN 1 AND 2147483647),
 access_session_sha256 TEXT NOT NULL  CHECK (length(access_session_sha256)=64 AND length(CAST(access_session_sha256 AS BLOB))=64 AND access_session_sha256 NOT GLOB '*[^0-9a-f]*'),
 access_key_id TEXT NOT NULL CHECK(length(access_key_id) BETWEEN 1 AND 256),
 access_issued_at INTEGER NOT NULL,
 access_expires_at INTEGER NOT NULL,
 installation_scope_sha256 TEXT NOT NULL  CHECK (length(installation_scope_sha256)=64 AND length(CAST(installation_scope_sha256 AS BLOB))=64 AND installation_scope_sha256 NOT GLOB '*[^0-9a-f]*'),
 authority_set_sha256 TEXT NOT NULL  CHECK (length(authority_set_sha256)=64 AND length(CAST(authority_set_sha256 AS BLOB))=64 AND authority_set_sha256 NOT GLOB '*[^0-9a-f]*'),
 expected_origin TEXT NOT NULL CHECK(length(expected_origin) BETWEEN 1 AND 512),
 expected_rp_id TEXT NOT NULL CHECK(length(expected_rp_id) BETWEEN 1 AND 253),
 registration_challenge_id TEXT NOT NULL UNIQUE CHECK (length(registration_challenge_id)=36 AND length(CAST(registration_challenge_id AS BLOB))=36 AND substr(registration_challenge_id,9,1)='-' AND substr(registration_challenge_id,14,2)='-4' AND substr(registration_challenge_id,19,1)='-' AND substr(registration_challenge_id,20,1) GLOB '[89ab]' AND substr(registration_challenge_id,24,1)='-' AND length(replace(registration_challenge_id,'-',''))=32 AND registration_challenge_id NOT GLOB '*[^0-9a-f-]*'),
 registration_challenge_sha256 TEXT NOT NULL UNIQUE CHECK (length(registration_challenge_sha256)=64 AND length(CAST(registration_challenge_sha256 AS BLOB))=64 AND registration_challenge_sha256 NOT GLOB '*[^0-9a-f]*'),
 issued_at INTEGER NOT NULL DEFAULT (unixepoch()),
 expires_at INTEGER NOT NULL,
 CHECK(access_issued_at<=issued_at AND access_expires_at>issued_at),
 CHECK(expires_at>issued_at AND expires_at<=issued_at+900 AND expires_at<access_expires_at)
) STRICT;

CREATE TABLE moderation_operator_enrollment_ceremony_attempts (
 ceremony_id TEXT NOT NULL REFERENCES moderation_operator_enrollment_ceremonies(ceremony_id) ON DELETE RESTRICT,
 phase TEXT NOT NULL CHECK(phase IN ('registration','possession')),
 attempt_id TEXT NOT NULL UNIQUE CHECK (length(attempt_id)=36 AND length(CAST(attempt_id AS BLOB))=36 AND substr(attempt_id,9,1)='-' AND substr(attempt_id,14,2)='-4' AND substr(attempt_id,19,1)='-' AND substr(attempt_id,20,1) GLOB '[89ab]' AND substr(attempt_id,24,1)='-' AND length(replace(attempt_id,'-',''))=32 AND attempt_id NOT GLOB '*[^0-9a-f-]*'),
 challenge_id TEXT NOT NULL UNIQUE CHECK (length(challenge_id)=36 AND length(CAST(challenge_id AS BLOB))=36 AND substr(challenge_id,9,1)='-' AND substr(challenge_id,14,2)='-4' AND substr(challenge_id,19,1)='-' AND substr(challenge_id,20,1) GLOB '[89ab]' AND substr(challenge_id,24,1)='-' AND length(replace(challenge_id,'-',''))=32 AND challenge_id NOT GLOB '*[^0-9a-f-]*'),
 challenge_sha256 TEXT NOT NULL UNIQUE CHECK (length(challenge_sha256)=64 AND length(CAST(challenge_sha256 AS BLOB))=64 AND challenge_sha256 NOT GLOB '*[^0-9a-f]*'),
 attempted_at INTEGER NOT NULL DEFAULT (unixepoch()),
 PRIMARY KEY(ceremony_id,phase)
) STRICT;

CREATE TABLE moderation_operator_enrollment_ceremony_registrations (
 ceremony_id TEXT PRIMARY KEY REFERENCES moderation_operator_enrollment_ceremonies(ceremony_id) ON DELETE RESTRICT,
 attempt_id TEXT NOT NULL UNIQUE REFERENCES moderation_operator_enrollment_ceremony_attempts(attempt_id) ON DELETE RESTRICT,
 registration_sha256 TEXT NOT NULL UNIQUE CHECK (length(registration_sha256)=64 AND length(CAST(registration_sha256 AS BLOB))=64 AND registration_sha256 NOT GLOB '*[^0-9a-f]*'),
 credential_id_sha256 TEXT NOT NULL  CHECK (length(credential_id_sha256)=64 AND length(CAST(credential_id_sha256 AS BLOB))=64 AND credential_id_sha256 NOT GLOB '*[^0-9a-f]*'),
 public_key_cose BLOB NOT NULL CHECK(length(public_key_cose) BETWEEN 32 AND 2048),
 public_key_cose_sha256 TEXT NOT NULL  CHECK (length(public_key_cose_sha256)=64 AND length(CAST(public_key_cose_sha256 AS BLOB))=64 AND public_key_cose_sha256 NOT GLOB '*[^0-9a-f]*'),
 registration_sign_count INTEGER NOT NULL CHECK(registration_sign_count BETWEEN 0 AND 4294967295),
 authenticator_aaguid_sha256 TEXT NOT NULL  CHECK (length(authenticator_aaguid_sha256)=64 AND length(CAST(authenticator_aaguid_sha256 AS BLOB))=64 AND authenticator_aaguid_sha256 NOT GLOB '*[^0-9a-f]*'),
 attestation_policy TEXT NOT NULL CHECK(attestation_policy='es256-single-device-none-or-packed-self-v1'),
 attestation_format TEXT NOT NULL CHECK(attestation_format IN ('none','packed')),
 self_attestation_verified INTEGER NOT NULL CHECK(self_attestation_verified IN (0,1)),
 possession_challenge_id TEXT NOT NULL UNIQUE CHECK (length(possession_challenge_id)=36 AND length(CAST(possession_challenge_id AS BLOB))=36 AND substr(possession_challenge_id,9,1)='-' AND substr(possession_challenge_id,14,2)='-4' AND substr(possession_challenge_id,19,1)='-' AND substr(possession_challenge_id,20,1) GLOB '[89ab]' AND substr(possession_challenge_id,24,1)='-' AND length(replace(possession_challenge_id,'-',''))=32 AND possession_challenge_id NOT GLOB '*[^0-9a-f-]*'),
 possession_challenge_sha256 TEXT NOT NULL UNIQUE CHECK (length(possession_challenge_sha256)=64 AND length(CAST(possession_challenge_sha256 AS BLOB))=64 AND possession_challenge_sha256 NOT GLOB '*[^0-9a-f]*'),
 verified_at INTEGER NOT NULL DEFAULT (unixepoch()),
 CHECK(self_attestation_verified=(attestation_format='packed'))
) STRICT;

CREATE TABLE moderation_operator_enrollment_ceremony_possessions (
 ceremony_id TEXT PRIMARY KEY REFERENCES moderation_operator_enrollment_ceremony_registrations(ceremony_id) ON DELETE RESTRICT,
 attempt_id TEXT NOT NULL UNIQUE REFERENCES moderation_operator_enrollment_ceremony_attempts(attempt_id) ON DELETE RESTRICT,
 credential_id_sha256 TEXT NOT NULL  CHECK (length(credential_id_sha256)=64 AND length(CAST(credential_id_sha256 AS BLOB))=64 AND credential_id_sha256 NOT GLOB '*[^0-9a-f]*'),
 verified_assertion_sha256 TEXT NOT NULL UNIQUE CHECK (length(verified_assertion_sha256)=64 AND length(CAST(verified_assertion_sha256 AS BLOB))=64 AND verified_assertion_sha256 NOT GLOB '*[^0-9a-f]*'),
 authenticator_sign_count INTEGER NOT NULL CHECK(authenticator_sign_count BETWEEN 0 AND 4294967295),
 verified_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE TRIGGER moderation_enrollment_ceremony_insert BEFORE INSERT ON moderation_operator_enrollment_ceremonies
BEGIN
 SELECT (CASE WHEN NEW.issued_at<>unixepoch()
  OR EXISTS(SELECT 1 FROM moderation_operator_enrollment_ceremonies WHERE ceremony_id=NEW.ceremony_id OR registration_challenge_id=NEW.registration_challenge_id OR registration_challenge_sha256=NEW.registration_challenge_sha256)
  OR EXISTS(SELECT 1 FROM moderation_operator_enrollment_ceremony_registrations WHERE possession_challenge_id=NEW.registration_challenge_id OR possession_challenge_sha256=NEW.registration_challenge_sha256)
  THEN RAISE(ABORT,'enrollment ceremony unavailable') END);
END;

CREATE TRIGGER moderation_enrollment_attempt_insert BEFORE INSERT ON moderation_operator_enrollment_ceremony_attempts
BEGIN
 SELECT (CASE WHEN NEW.attempted_at<>unixepoch()
  OR EXISTS(SELECT 1 FROM moderation_operator_enrollment_ceremony_attempts WHERE (ceremony_id=NEW.ceremony_id AND phase=NEW.phase) OR attempt_id=NEW.attempt_id OR challenge_id=NEW.challenge_id OR challenge_sha256=NEW.challenge_sha256)
  OR NOT EXISTS(SELECT 1 FROM moderation_operator_enrollment_ceremonies c LEFT JOIN moderation_operator_enrollment_ceremony_registrations r ON r.ceremony_id=c.ceremony_id
    WHERE c.ceremony_id=NEW.ceremony_id AND c.issued_at<=unixepoch() AND c.expires_at>unixepoch()
     AND ((NEW.phase='registration' AND NEW.challenge_id=c.registration_challenge_id AND NEW.challenge_sha256=c.registration_challenge_sha256)
      OR (NEW.phase='possession' AND NEW.challenge_id=r.possession_challenge_id AND NEW.challenge_sha256=r.possession_challenge_sha256)))
  THEN RAISE(ABORT,'enrollment attempt unavailable') END);
END;

CREATE TRIGGER moderation_enrollment_registration_insert BEFORE INSERT ON moderation_operator_enrollment_ceremony_registrations
BEGIN
 SELECT (CASE WHEN NEW.verified_at<>unixepoch()
  OR EXISTS(SELECT 1 FROM moderation_operator_enrollment_ceremony_registrations WHERE ceremony_id=NEW.ceremony_id OR attempt_id=NEW.attempt_id OR registration_sha256=NEW.registration_sha256 OR possession_challenge_id=NEW.possession_challenge_id OR possession_challenge_sha256=NEW.possession_challenge_sha256)
  OR EXISTS(SELECT 1 FROM moderation_operator_enrollment_ceremonies WHERE registration_challenge_id=NEW.possession_challenge_id OR registration_challenge_sha256=NEW.possession_challenge_sha256)
  OR NOT EXISTS(SELECT 1 FROM moderation_operator_enrollment_ceremonies c JOIN moderation_operator_enrollment_ceremony_attempts a ON a.ceremony_id=c.ceremony_id
    WHERE c.ceremony_id=NEW.ceremony_id AND a.attempt_id=NEW.attempt_id AND a.phase='registration'
     AND c.issued_at<=unixepoch() AND c.expires_at>unixepoch())
  THEN RAISE(ABORT,'enrollment registration unavailable') END);
END;

-- Keep all four existing counter sources; only successful possession adds a
-- fifth source. The immutable original registration count is never rewritten.
DROP VIEW moderation_operator_credential_counters;
CREATE VIEW moderation_operator_credential_counters AS
 SELECT credential_id_sha256,MAX(sign_count) AS sign_count FROM (
  SELECT credential_id_sha256,registration_sign_count AS sign_count FROM moderation_operator_credentials
  UNION ALL SELECT credential_id_sha256,authenticator_sign_count FROM moderation_operator_challenge_consumptions
  UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM moderation_owner_challenge_consumptions r JOIN moderation_owner_challenges c USING(challenge_id)
  UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM moderation_resolution_consumptions r JOIN moderation_resolution_challenges c USING(challenge_id)
  UNION ALL SELECT credential_id_sha256,authenticator_sign_count FROM moderation_operator_enrollment_ceremony_possessions
 ) GROUP BY credential_id_sha256;

CREATE TRIGGER moderation_enrollment_possession_insert BEFORE INSERT ON moderation_operator_enrollment_ceremony_possessions
BEGIN
 SELECT (CASE WHEN NEW.verified_at<>unixepoch()
  OR EXISTS(SELECT 1 FROM moderation_operator_enrollment_ceremony_possessions WHERE ceremony_id=NEW.ceremony_id OR attempt_id=NEW.attempt_id OR verified_assertion_sha256=NEW.verified_assertion_sha256)
  OR NOT EXISTS(SELECT 1 FROM moderation_operator_enrollment_ceremonies c JOIN moderation_operator_enrollment_ceremony_registrations r ON r.ceremony_id=c.ceremony_id
    JOIN moderation_operator_enrollment_ceremony_attempts a ON a.ceremony_id=c.ceremony_id
    WHERE c.ceremony_id=NEW.ceremony_id AND a.attempt_id=NEW.attempt_id AND a.phase='possession'
     AND c.issued_at<=unixepoch() AND c.expires_at>unixepoch() AND r.credential_id_sha256=NEW.credential_id_sha256
     AND ((NEW.authenticator_sign_count=0 AND r.registration_sign_count=0 AND COALESCE((SELECT sign_count FROM moderation_operator_credential_counters WHERE credential_id_sha256=NEW.credential_id_sha256),0)=0)
       OR NEW.authenticator_sign_count>MAX(r.registration_sign_count,COALESCE((SELECT sign_count FROM moderation_operator_credential_counters WHERE credential_id_sha256=NEW.credential_id_sha256),0))))
  THEN RAISE(ABORT,'enrollment possession unavailable') END);
END;

CREATE TRIGGER moderation_enrollment_ceremony_no_update BEFORE UPDATE ON moderation_operator_enrollment_ceremonies
BEGIN
 SELECT RAISE(ABORT,'enrollment ceremony evidence is immutable');
END;

CREATE TRIGGER moderation_enrollment_ceremony_no_delete BEFORE DELETE ON moderation_operator_enrollment_ceremonies
BEGIN
 SELECT RAISE(ABORT,'enrollment ceremony evidence is immutable');
END;

CREATE TRIGGER moderation_enrollment_attempt_no_update BEFORE UPDATE ON moderation_operator_enrollment_ceremony_attempts
BEGIN
 SELECT RAISE(ABORT,'enrollment ceremony evidence is immutable');
END;

CREATE TRIGGER moderation_enrollment_attempt_no_delete BEFORE DELETE ON moderation_operator_enrollment_ceremony_attempts
BEGIN
 SELECT RAISE(ABORT,'enrollment ceremony evidence is immutable');
END;

CREATE TRIGGER moderation_enrollment_registration_no_update BEFORE UPDATE ON moderation_operator_enrollment_ceremony_registrations
BEGIN
 SELECT RAISE(ABORT,'enrollment ceremony evidence is immutable');
END;

CREATE TRIGGER moderation_enrollment_registration_no_delete BEFORE DELETE ON moderation_operator_enrollment_ceremony_registrations
BEGIN
 SELECT RAISE(ABORT,'enrollment ceremony evidence is immutable');
END;

CREATE TRIGGER moderation_enrollment_possession_no_update BEFORE UPDATE ON moderation_operator_enrollment_ceremony_possessions
BEGIN
 SELECT RAISE(ABORT,'enrollment ceremony evidence is immutable');
END;

CREATE TRIGGER moderation_enrollment_possession_no_delete BEFORE DELETE ON moderation_operator_enrollment_ceremony_possessions
BEGIN
 SELECT RAISE(ABORT,'enrollment ceremony evidence is immutable');
END;
