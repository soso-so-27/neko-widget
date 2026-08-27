-- Fail-closed operator and credential enrollment provenance.
--
-- This migration adds no route, binding, runtime switch, deployment or
-- backfill. Rows created by migrations 0013-0016 remain legacy-unproven until
-- an explicit enrollment request is approved and admitted here. The digests
-- below are records of a future reviewed verifier's result; SQLite does not
-- claim to verify an offline signature, WebAuthn attestation, AAGUID or COSE
-- digest. Database administrators can forge rows and remain inside the trusted
-- computing base. Raw Access subjects/JWTs, email, name, userHandle, credential
-- IDs, attestation objects and certificates must never be persisted here.

CREATE TABLE moderation_operator_enrollment_requests (
    enrollment_request_id TEXT PRIMARY KEY CHECK (
      length(enrollment_request_id) = 36
      AND length(CAST(enrollment_request_id AS BLOB)) = 36
      AND lower(enrollment_request_id) = enrollment_request_id
      AND substr(enrollment_request_id, 9, 1) = '-'
      AND substr(enrollment_request_id, 14, 1) = '-'
      AND substr(enrollment_request_id, 15, 1) = '4'
      AND substr(enrollment_request_id, 19, 1) = '-'
      AND substr(enrollment_request_id, 20, 1) GLOB '[89ab]'
      AND substr(enrollment_request_id, 24, 1) = '-'
      AND length(replace(enrollment_request_id, '-', '')) = 32
      AND enrollment_request_id NOT GLOB '*[^0-9a-f-]*'
    ),
    enrollment_kind TEXT NOT NULL CHECK (
      enrollment_kind IN ('initial_bootstrap', 'enrollment', 'recovery')
    ),
    request_schema_version INTEGER NOT NULL CHECK (
      request_schema_version = 1
    ),
    canonical_request_sha256 TEXT NOT NULL UNIQUE CHECK (
      length(canonical_request_sha256) = 64
      AND length(CAST(canonical_request_sha256 AS BLOB)) = 64
      AND canonical_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    target_operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    target_access_subject_hmac_key_version INTEGER NOT NULL CHECK (
      target_access_subject_hmac_key_version BETWEEN 1 AND 2147483647
    ),
    target_access_subject_hmac TEXT NOT NULL CHECK (
      length(target_access_subject_hmac) = 64
      AND length(CAST(target_access_subject_hmac AS BLOB)) = 64
      AND target_access_subject_hmac NOT GLOB '*[^0-9a-f]*'
    ),
    target_credential_id_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_credentials(credential_id_sha256)
        ON DELETE RESTRICT,
    target_public_key_cose_sha256 TEXT NOT NULL CHECK (
      length(target_public_key_cose_sha256) = 64
      AND length(CAST(target_public_key_cose_sha256 AS BLOB)) = 64
      AND target_public_key_cose_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    -- The immutable public key is duplicated only to let D1 compare the exact
    -- credential row byte-for-byte. The future verifier must prove that the
    -- adjacent SHA-256 is the digest of this snapshot before insertion.
    target_public_key_cose_snapshot BLOB NOT NULL CHECK (
      length(target_public_key_cose_snapshot) BETWEEN 32 AND 2048
    ),
    target_registration_sign_count INTEGER NOT NULL CHECK (
      target_registration_sign_count BETWEEN 0 AND 4294967295
    ),
    attestation_evidence_sha256 TEXT NOT NULL CHECK (
      length(attestation_evidence_sha256) = 64
      AND length(CAST(attestation_evidence_sha256 AS BLOB)) = 64
      AND attestation_evidence_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    attestation_policy_revision INTEGER NOT NULL CHECK (
      attestation_policy_revision BETWEEN 1 AND 2147483647
    ),
    authenticator_aaguid_sha256 TEXT NOT NULL CHECK (
      length(authenticator_aaguid_sha256) = 64
      AND length(CAST(authenticator_aaguid_sha256 AS BLOB)) = 64
      AND authenticator_aaguid_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    superseded_enrollment_admission_id TEXT
        REFERENCES moderation_operator_enrollment_admissions(
          enrollment_admission_id
        ) ON DELETE RESTRICT,
    superseded_credential_id_sha256 TEXT
        REFERENCES moderation_operator_credentials(credential_id_sha256)
        ON DELETE RESTRICT,
    requested_at INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at INTEGER NOT NULL,
    FOREIGN KEY (
      target_operator_id, target_access_subject_hmac_key_version
    ) REFERENCES moderation_operator_subject_identities(
      operator_id, access_subject_hmac_key_version
    ) ON DELETE RESTRICT,
    FOREIGN KEY (
      target_access_subject_hmac_key_version,
      target_access_subject_hmac
    ) REFERENCES moderation_operator_subject_identities(
      access_subject_hmac_key_version, access_subject_hmac
    ) ON DELETE RESTRICT,
    CHECK (
      expires_at > requested_at
      AND expires_at <= requested_at + 900
    ),
    CHECK (
      (
        enrollment_kind = 'recovery'
        AND superseded_enrollment_admission_id IS NOT NULL
        AND superseded_credential_id_sha256 IS NOT NULL
        AND superseded_credential_id_sha256 <>
            target_credential_id_sha256
      ) OR (
        enrollment_kind <> 'recovery'
        AND superseded_enrollment_admission_id IS NULL
        AND superseded_credential_id_sha256 IS NULL
      )
    )
) STRICT;

CREATE INDEX moderation_operator_enrollment_requests_target
    ON moderation_operator_enrollment_requests(
      target_operator_id, requested_at, enrollment_request_id
    );

-- Offline bootstrap authorities are provisioned only through the reviewed,
-- offline database administration procedure. There is intentionally no
-- runtime route for this table. A fingerprint rotation appends a higher policy
-- revision; old authority rows remain available for immutable provenance.
CREATE TABLE moderation_operator_enrollment_offline_authorities (
    offline_authority_key_id TEXT NOT NULL CHECK (
      length(offline_authority_key_id) BETWEEN 8 AND 64
      AND length(CAST(offline_authority_key_id AS BLOB)) =
          length(offline_authority_key_id)
      AND offline_authority_key_id = trim(offline_authority_key_id)
      AND offline_authority_key_id NOT GLOB '*[^A-Za-z0-9._-]*'
    ),
    authority_policy_revision INTEGER NOT NULL CHECK (
      authority_policy_revision BETWEEN 1 AND 2147483647
    ),
    authority_public_key_fingerprint_sha256 TEXT NOT NULL UNIQUE CHECK (
      length(authority_public_key_fingerprint_sha256) = 64
      AND length(CAST(authority_public_key_fingerprint_sha256 AS BLOB)) = 64
      AND authority_public_key_fingerprint_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    authorized_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (offline_authority_key_id, authority_policy_revision)
) STRICT;

-- Bootstrap approval identifiers are public opaque key IDs. Only a digest of
-- each verified signature is retained; signature bytes and certificates are
-- deliberately absent.
CREATE TABLE moderation_operator_enrollment_offline_approvals (
    enrollment_request_id TEXT NOT NULL
        REFERENCES moderation_operator_enrollment_requests(
          enrollment_request_id
        ) ON DELETE RESTRICT,
    offline_authority_key_id TEXT NOT NULL CHECK (
      length(offline_authority_key_id) BETWEEN 8 AND 64
      AND length(CAST(offline_authority_key_id AS BLOB)) =
          length(offline_authority_key_id)
      AND offline_authority_key_id = trim(offline_authority_key_id)
      AND offline_authority_key_id NOT GLOB '*[^A-Za-z0-9._-]*'
    ),
    authority_policy_revision INTEGER NOT NULL CHECK (
      authority_policy_revision BETWEEN 1 AND 2147483647
    ),
    authority_public_key_fingerprint_sha256 TEXT NOT NULL CHECK (
      length(authority_public_key_fingerprint_sha256) = 64
      AND length(CAST(authority_public_key_fingerprint_sha256 AS BLOB)) = 64
      AND authority_public_key_fingerprint_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    authority_signature_sha256 TEXT NOT NULL UNIQUE CHECK (
      length(authority_signature_sha256) = 64
      AND length(CAST(authority_signature_sha256 AS BLOB)) = 64
      AND authority_signature_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    approved_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (enrollment_request_id, offline_authority_key_id),
    FOREIGN KEY (
      offline_authority_key_id, authority_policy_revision
    ) REFERENCES moderation_operator_enrollment_offline_authorities(
      offline_authority_key_id, authority_policy_revision
    ) ON DELETE RESTRICT
) STRICT;

-- Normal enrollment is approved by one different, already admitted security
-- administrator. Credential recovery is an exact replacement and requires two
-- distinct current security administrators. The signature digest is only admitted
-- after a future reviewed verifier has checked it; this schema records the
-- exact provenance but is neither a signature verifier nor a claim that a
-- WebAuthn approval assertion ceremony has completed.
CREATE TABLE moderation_operator_enrollment_admin_approvals (
    enrollment_request_id TEXT NOT NULL
        REFERENCES moderation_operator_enrollment_requests(
          enrollment_request_id
        ) ON DELETE RESTRICT,
    approver_operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    approver_admission_id TEXT NOT NULL
        REFERENCES moderation_operator_enrollment_admissions(
          enrollment_admission_id
        ) ON DELETE RESTRICT,
    approver_access_session_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_access_sessions(access_session_sha256)
        ON DELETE RESTRICT,
    approver_credential_id_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_credentials(credential_id_sha256)
        ON DELETE RESTRICT,
    approval_signature_sha256 TEXT NOT NULL UNIQUE CHECK (
      length(approval_signature_sha256) = 64
      AND length(CAST(approval_signature_sha256 AS BLOB)) = 64
      AND approval_signature_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    approved_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (enrollment_request_id, approver_operator_id)
) STRICT;

CREATE TABLE moderation_operator_enrollment_admissions (
    enrollment_admission_id TEXT PRIMARY KEY CHECK (
      length(enrollment_admission_id) = 36
      AND length(CAST(enrollment_admission_id AS BLOB)) = 36
      AND lower(enrollment_admission_id) = enrollment_admission_id
      AND substr(enrollment_admission_id, 9, 1) = '-'
      AND substr(enrollment_admission_id, 14, 1) = '-'
      AND substr(enrollment_admission_id, 15, 1) = '4'
      AND substr(enrollment_admission_id, 19, 1) = '-'
      AND substr(enrollment_admission_id, 20, 1) GLOB '[89ab]'
      AND substr(enrollment_admission_id, 24, 1) = '-'
      AND length(replace(enrollment_admission_id, '-', '')) = 32
      AND enrollment_admission_id NOT GLOB '*[^0-9a-f-]*'
    ),
    enrollment_request_id TEXT NOT NULL UNIQUE
        REFERENCES moderation_operator_enrollment_requests(
          enrollment_request_id
        ) ON DELETE RESTRICT,
    admission_provenance_sha256 TEXT NOT NULL UNIQUE CHECK (
      length(admission_provenance_sha256) = 64
      AND length(CAST(admission_provenance_sha256 AS BLOB)) = 64
      AND admission_provenance_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    admitted_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE INDEX moderation_operator_enrollment_admissions_request
    ON moderation_operator_enrollment_admissions(
      enrollment_request_id, admitted_at, enrollment_admission_id
    );

-- High-water marks prevent a session or challenge created under the pre-0017
-- rules from being relabeled as trusted after an enrollment admission. No
-- legacy row is linked or backfilled.
CREATE TABLE moderation_operator_enrollment_migration_fence (
    migration_version INTEGER PRIMARY KEY CHECK (migration_version = 17),
    access_session_rowid_high_water INTEGER NOT NULL CHECK (
      access_session_rowid_high_water >= 0
    ),
    challenge_rowid_high_water INTEGER NOT NULL CHECK (
      challenge_rowid_high_water >= 0
    ),
    reservation_rowid_high_water INTEGER NOT NULL CHECK (
      reservation_rowid_high_water >= 0
    ),
    installed_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

INSERT INTO moderation_operator_enrollment_migration_fence(
  migration_version, access_session_rowid_high_water,
  challenge_rowid_high_water, reservation_rowid_high_water, installed_at
)
SELECT
  17,
  COALESCE((SELECT MAX(rowid) FROM moderation_operator_access_sessions), 0),
  COALESCE((SELECT MAX(rowid) FROM moderation_operator_challenges), 0),
  COALESCE((SELECT MAX(rowid) FROM moderation_case_reservations), 0),
  unixepoch();

CREATE TRIGGER moderation_operator_enrollment_migration_fence_is_immutable
BEFORE UPDATE ON moderation_operator_enrollment_migration_fence
BEGIN SELECT RAISE(ABORT, 'operator enrollment migration fence is immutable'); END;

CREATE TRIGGER moderation_operator_enrollment_migration_fence_cannot_be_deleted
BEFORE DELETE ON moderation_operator_enrollment_migration_fence
BEGIN SELECT RAISE(ABORT, 'operator enrollment migration fence cannot be deleted'); END;

CREATE TRIGGER moderation_operator_enrollment_migration_fence_cannot_be_inserted
BEFORE INSERT ON moderation_operator_enrollment_migration_fence
BEGIN SELECT RAISE(ABORT, 'operator enrollment migration fence already exists'); END;

-- This view is a derived exact chain, not a cryptographic-verification claim.
-- It can contain only post-0017 sessions/challenges tied to an admission whose
-- immutable credential snapshot matches the existing credential row.
CREATE VIEW moderation_operator_enrollment_trusted_challenges AS
SELECT
  challenge.challenge_id AS challenge_id,
  challenge.operator_id AS operator_id,
  challenge.credential_id_sha256 AS credential_id_sha256,
  session.access_session_sha256 AS access_session_sha256,
  admission.enrollment_admission_id AS enrollment_admission_id
FROM moderation_operator_challenges AS challenge
JOIN moderation_operator_access_sessions AS session
  ON session.access_session_sha256 = challenge.access_session_sha256
JOIN moderation_operator_enrollment_requests AS request
  ON request.target_operator_id = challenge.operator_id
 AND request.target_access_subject_hmac_key_version =
     session.access_subject_hmac_key_version
 AND request.target_access_subject_hmac = session.access_subject_hmac
 AND request.target_credential_id_sha256 = challenge.credential_id_sha256
JOIN moderation_operator_enrollment_admissions AS admission
  ON admission.enrollment_request_id = request.enrollment_request_id
JOIN moderation_operator_credentials AS credential
  ON credential.credential_id_sha256 = request.target_credential_id_sha256
 AND credential.operator_id = request.target_operator_id
JOIN moderation_operator_enrollment_migration_fence AS fence
  ON fence.migration_version = 17
WHERE session.rowid > fence.access_session_rowid_high_water
  AND challenge.rowid > fence.challenge_rowid_high_water
  AND session.admitted_at >= admission.admitted_at
  AND challenge.issued_at >= session.admitted_at
  AND credential.registration_sign_count = request.target_registration_sign_count
  AND credential.public_key_cose = request.target_public_key_cose_snapshot;

CREATE TRIGGER moderation_operator_enrollment_requests_validate
BEFORE INSERT ON moderation_operator_enrollment_requests
BEGIN
    SELECT (CASE
      WHEN NEW.requested_at <> unixepoch()
      THEN RAISE(ABORT, 'enrollment request must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_requests
         WHERE enrollment_request_id = NEW.enrollment_request_id
            OR canonical_request_sha256 = NEW.canonical_request_sha256
      )
      THEN RAISE(ABORT, 'enrollment request cannot be replayed or replaced')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_subject_identities AS identity
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 =
               NEW.target_credential_id_sha256
           AND credential.operator_id = identity.operator_id
         WHERE identity.operator_id = NEW.target_operator_id
           AND identity.access_subject_hmac_key_version =
               NEW.target_access_subject_hmac_key_version
           AND identity.access_subject_hmac =
               NEW.target_access_subject_hmac
           AND credential.registration_sign_count =
               NEW.target_registration_sign_count
           AND credential.public_key_cose =
               NEW.target_public_key_cose_snapshot
      )
      THEN RAISE(ABORT, 'enrollment request target tuple does not exist')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.target_operator_id
           AND event_type = 'activated'
      ) OR EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.target_operator_id
           AND event_type = 'revoked'
      )
      THEN RAISE(ABORT, 'enrollment request target operator is not active')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_credential_events
         WHERE credential_id_sha256 = NEW.target_credential_id_sha256
           AND event_type = 'registered'
      ) OR EXISTS (
        SELECT 1 FROM moderation_operator_credential_events
         WHERE credential_id_sha256 = NEW.target_credential_id_sha256
           AND event_type = 'revoked'
      )
      THEN RAISE(ABORT, 'enrollment request target credential is not active')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_subject_identities AS newer
         WHERE newer.operator_id = NEW.target_operator_id
           AND newer.access_subject_hmac_key_version >
               NEW.target_access_subject_hmac_key_version
      )
      THEN RAISE(ABORT, 'enrollment request target alias is not current')
      WHEN NEW.enrollment_kind = 'initial_bootstrap' AND EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_admissions
      )
      THEN RAISE(ABORT, 'initial bootstrap is already complete')
      WHEN NEW.enrollment_kind = 'initial_bootstrap' AND NOT EXISTS (
        SELECT 1 FROM moderation_operator_role_events
         WHERE operator_id = NEW.target_operator_id
           AND role_code = 'security_admin' AND event_type = 'granted'
      )
      THEN RAISE(ABORT, 'initial bootstrap target must be a security admin')
      WHEN NEW.enrollment_kind = 'initial_bootstrap' AND EXISTS (
        SELECT 1 FROM moderation_operator_role_events
         WHERE operator_id = NEW.target_operator_id
           AND role_code = 'security_admin' AND event_type = 'revoked'
      )
      THEN RAISE(ABORT, 'initial bootstrap security admin is revoked')
      WHEN NEW.enrollment_kind = 'enrollment' AND EXISTS (
        SELECT 1
          FROM moderation_operator_enrollment_admissions AS admission
          JOIN moderation_operator_enrollment_requests AS request
            ON request.enrollment_request_id = admission.enrollment_request_id
         WHERE request.target_operator_id = NEW.target_operator_id
      )
      THEN RAISE(ABORT, 'operator is already enrolled; use recovery')
      WHEN NEW.enrollment_kind = 'recovery' AND NOT EXISTS (
        SELECT 1
          FROM moderation_operator_enrollment_admissions AS admission
          JOIN moderation_operator_enrollment_requests AS request
            ON request.enrollment_request_id = admission.enrollment_request_id
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 =
               NEW.superseded_credential_id_sha256
           AND credential.operator_id = NEW.target_operator_id
         WHERE admission.enrollment_admission_id =
               NEW.superseded_enrollment_admission_id
           AND request.target_operator_id = NEW.target_operator_id
           AND request.target_credential_id_sha256 =
               NEW.superseded_credential_id_sha256
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 =
                    NEW.superseded_credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_enrollment_admissions AS newer_admission
               JOIN moderation_operator_enrollment_requests AS newer_request
                 ON newer_request.enrollment_request_id =
                    newer_admission.enrollment_request_id
              WHERE newer_request.target_operator_id = NEW.target_operator_id
                AND newer_admission.rowid > admission.rowid
           )
      )
      THEN RAISE(ABORT, 'recovery requires current superseded credential')
    END);
END;

CREATE TRIGGER moderation_operator_enrollment_requests_are_append_only
BEFORE UPDATE ON moderation_operator_enrollment_requests
BEGIN SELECT RAISE(ABORT, 'enrollment requests are append-only'); END;

CREATE TRIGGER moderation_operator_enrollment_requests_cannot_be_deleted
BEFORE DELETE ON moderation_operator_enrollment_requests
BEGIN SELECT RAISE(ABORT, 'enrollment requests cannot be deleted'); END;

CREATE TRIGGER moderation_operator_enrollment_offline_authorities_validate
BEFORE INSERT ON moderation_operator_enrollment_offline_authorities
BEGIN
    SELECT (CASE
      WHEN NEW.authorized_at <> unixepoch()
      THEN RAISE(ABORT, 'offline authority must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_offline_authorities
         WHERE (offline_authority_key_id = NEW.offline_authority_key_id
                AND authority_policy_revision >=
                    NEW.authority_policy_revision)
            OR authority_public_key_fingerprint_sha256 =
               NEW.authority_public_key_fingerprint_sha256
      )
      THEN RAISE(ABORT, 'offline authority cannot be replayed or replaced')
    END);
END;

CREATE TRIGGER moderation_operator_enrollment_offline_authorities_are_append_only
BEFORE UPDATE ON moderation_operator_enrollment_offline_authorities
BEGIN SELECT RAISE(ABORT, 'offline authorities are append-only'); END;

CREATE TRIGGER moderation_operator_enrollment_offline_authorities_cannot_be_deleted
BEFORE DELETE ON moderation_operator_enrollment_offline_authorities
BEGIN SELECT RAISE(ABORT, 'offline authorities cannot be deleted'); END;

CREATE TRIGGER moderation_operator_enrollment_offline_approvals_validate
BEFORE INSERT ON moderation_operator_enrollment_offline_approvals
BEGIN
    SELECT (CASE
      WHEN NEW.approved_at <> unixepoch()
      THEN RAISE(ABORT, 'offline approval must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_offline_approvals
         WHERE (enrollment_request_id = NEW.enrollment_request_id
                AND offline_authority_key_id = NEW.offline_authority_key_id)
            OR authority_signature_sha256 = NEW.authority_signature_sha256
      )
      THEN RAISE(ABORT, 'offline approval cannot be replayed or replaced')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_admissions
         WHERE enrollment_request_id = NEW.enrollment_request_id
      )
      THEN RAISE(ABORT, 'enrollment request is already admitted')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_enrollment_requests AS request
          JOIN moderation_operator_enrollment_offline_authorities AS authority
            ON authority.offline_authority_key_id =
               NEW.offline_authority_key_id
           AND authority.authority_policy_revision =
               NEW.authority_policy_revision
           AND authority.authority_public_key_fingerprint_sha256 =
               NEW.authority_public_key_fingerprint_sha256
         WHERE request.enrollment_request_id = NEW.enrollment_request_id
           AND request.enrollment_kind = 'initial_bootstrap'
           AND authority.authorized_at <= request.requested_at
           AND request.requested_at <= NEW.approved_at
           AND request.expires_at > NEW.approved_at
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_enrollment_offline_authorities AS newer
              WHERE newer.offline_authority_key_id =
                    authority.offline_authority_key_id
                AND newer.authority_policy_revision >
                    authority.authority_policy_revision
           )
      )
      THEN RAISE(ABORT, 'offline approval requires a reviewed live authority')
    END);
END;

CREATE TRIGGER moderation_operator_enrollment_offline_approvals_are_append_only
BEFORE UPDATE ON moderation_operator_enrollment_offline_approvals
BEGIN SELECT RAISE(ABORT, 'offline approvals are append-only'); END;

CREATE TRIGGER moderation_operator_enrollment_offline_approvals_cannot_be_deleted
BEFORE DELETE ON moderation_operator_enrollment_offline_approvals
BEGIN SELECT RAISE(ABORT, 'offline approvals cannot be deleted'); END;

CREATE TRIGGER moderation_operator_enrollment_admin_approvals_validate
BEFORE INSERT ON moderation_operator_enrollment_admin_approvals
BEGIN
    SELECT (CASE
      WHEN NEW.approved_at <> unixepoch()
      THEN RAISE(ABORT, 'admin approval must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_admin_approvals
         WHERE (enrollment_request_id = NEW.enrollment_request_id
                AND approver_operator_id = NEW.approver_operator_id)
            OR approval_signature_sha256 = NEW.approval_signature_sha256
      )
      THEN RAISE(ABORT, 'admin approval cannot be replayed or replaced')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_admissions
         WHERE enrollment_request_id = NEW.enrollment_request_id
      )
      THEN RAISE(ABORT, 'enrollment request is already admitted')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_requests AS target
         WHERE target.enrollment_request_id = NEW.enrollment_request_id
           AND target.enrollment_kind IN ('enrollment', 'recovery')
           AND target.target_operator_id <> NEW.approver_operator_id
           AND target.requested_at <= NEW.approved_at
           AND target.expires_at > NEW.approved_at
      )
      THEN RAISE(ABORT, 'admin approval requires a live non-self request')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_access_sessions AS session
          JOIN moderation_operator_enrollment_admissions AS admission
            ON admission.enrollment_admission_id = NEW.approver_admission_id
          JOIN moderation_operator_enrollment_migration_fence AS fence
            ON fence.migration_version = 17
          JOIN moderation_operator_enrollment_requests AS admitted_request
            ON admitted_request.enrollment_request_id =
               admission.enrollment_request_id
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 =
               NEW.approver_credential_id_sha256
           AND credential.operator_id = NEW.approver_operator_id
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = NEW.approver_operator_id
           AND identity.access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND identity.access_subject_hmac = session.access_subject_hmac
         WHERE session.access_session_sha256 =
               NEW.approver_access_session_sha256
           AND session.operator_id = NEW.approver_operator_id
           AND session.rowid > fence.access_session_rowid_high_water
           AND session.admitted_at >= admission.admitted_at
           AND session.admitted_at <= NEW.approved_at
           AND session.token_expires_at > NEW.approved_at
           AND admitted_request.target_operator_id =
               NEW.approver_operator_id
           AND admitted_request.target_access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND admitted_request.target_access_subject_hmac =
               session.access_subject_hmac
           AND admitted_request.target_credential_id_sha256 =
               NEW.approver_credential_id_sha256
           AND credential.registration_sign_count =
               admitted_request.target_registration_sign_count
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.approver_operator_id
                AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.approver_operator_id
                AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_role_events
              WHERE operator_id = NEW.approver_operator_id
                AND role_code = 'security_admin' AND event_type = 'granted'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_role_events
              WHERE operator_id = NEW.approver_operator_id
                AND role_code = 'security_admin' AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = NEW.approver_credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = NEW.approver_credential_id_sha256
                AND event_type = 'revoked'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = NEW.approver_operator_id
                AND newer.access_subject_hmac_key_version >
                    session.access_subject_hmac_key_version
           )
      )
      THEN RAISE(ABORT, 'admin approval provenance is not currently trusted')
    END);
END;

CREATE TRIGGER moderation_operator_enrollment_admin_approvals_are_append_only
BEFORE UPDATE ON moderation_operator_enrollment_admin_approvals
BEGIN SELECT RAISE(ABORT, 'admin approvals are append-only'); END;

CREATE TRIGGER moderation_operator_enrollment_admin_approvals_cannot_be_deleted
BEFORE DELETE ON moderation_operator_enrollment_admin_approvals
BEGIN SELECT RAISE(ABORT, 'admin approvals cannot be deleted'); END;

CREATE TRIGGER moderation_operator_enrollment_admissions_validate
BEFORE INSERT ON moderation_operator_enrollment_admissions
BEGIN
    SELECT (CASE
      WHEN NEW.admitted_at <> unixepoch()
      THEN RAISE(ABORT, 'enrollment admission must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_admissions
         WHERE enrollment_admission_id = NEW.enrollment_admission_id
            OR enrollment_request_id = NEW.enrollment_request_id
            OR admission_provenance_sha256 = NEW.admission_provenance_sha256
      )
      THEN RAISE(ABORT, 'enrollment admission cannot be replayed or replaced')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_enrollment_requests AS request
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = request.target_operator_id
           AND identity.access_subject_hmac_key_version =
               request.target_access_subject_hmac_key_version
           AND identity.access_subject_hmac =
               request.target_access_subject_hmac
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 =
               request.target_credential_id_sha256
           AND credential.operator_id = request.target_operator_id
         WHERE request.enrollment_request_id = NEW.enrollment_request_id
           AND request.requested_at <= NEW.admitted_at
           AND request.expires_at > NEW.admitted_at
           AND credential.registration_sign_count =
               request.target_registration_sign_count
           AND credential.public_key_cose =
               request.target_public_key_cose_snapshot
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = request.target_operator_id
                AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = request.target_operator_id
                AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = request.target_credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = request.target_credential_id_sha256
                AND event_type = 'revoked'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = request.target_operator_id
                AND newer.access_subject_hmac_key_version >
                    request.target_access_subject_hmac_key_version
           )
      )
      THEN RAISE(ABORT, 'enrollment admission target is not current')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_requests AS request
         WHERE request.enrollment_request_id = NEW.enrollment_request_id
           AND request.enrollment_kind = 'initial_bootstrap'
      ) AND (
        SELECT COUNT(DISTINCT approval.offline_authority_key_id)
          FROM moderation_operator_enrollment_offline_approvals AS approval
         WHERE approval.enrollment_request_id = NEW.enrollment_request_id
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_enrollment_offline_authorities AS newer
              WHERE newer.offline_authority_key_id =
                    approval.offline_authority_key_id
                AND newer.authority_policy_revision >
                    approval.authority_policy_revision
           )
      ) < 2
      THEN RAISE(ABORT, 'initial bootstrap requires two offline authorities')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_requests AS request
         WHERE request.enrollment_request_id = NEW.enrollment_request_id
           AND request.enrollment_kind = 'initial_bootstrap'
      ) AND (
        NOT EXISTS (
          SELECT 1
            FROM moderation_operator_enrollment_requests AS request
            JOIN moderation_operator_role_events AS role
              ON role.operator_id = request.target_operator_id
           WHERE request.enrollment_request_id = NEW.enrollment_request_id
             AND role.role_code = 'security_admin'
             AND role.event_type = 'granted'
        ) OR EXISTS (
          SELECT 1
            FROM moderation_operator_enrollment_requests AS request
            JOIN moderation_operator_role_events AS role
              ON role.operator_id = request.target_operator_id
           WHERE request.enrollment_request_id = NEW.enrollment_request_id
             AND role.role_code = 'security_admin'
             AND role.event_type = 'revoked'
        )
      )
      THEN RAISE(ABORT, 'initial bootstrap security admin is not current')
      WHEN EXISTS (
        SELECT 1
          FROM moderation_operator_enrollment_requests AS request
         WHERE request.enrollment_request_id = NEW.enrollment_request_id
           AND request.enrollment_kind = 'enrollment'
           AND EXISTS (
             SELECT 1
               FROM moderation_operator_enrollment_admissions AS prior_admission
               JOIN moderation_operator_enrollment_requests AS prior_request
                 ON prior_request.enrollment_request_id =
                    prior_admission.enrollment_request_id
              WHERE prior_request.target_operator_id =
                    request.target_operator_id
           )
      )
      THEN RAISE(ABORT, 'operator is already enrolled; recovery is required')
      WHEN EXISTS (
        SELECT 1
          FROM moderation_operator_enrollment_requests AS request
         WHERE request.enrollment_request_id = NEW.enrollment_request_id
           AND request.enrollment_kind = 'recovery'
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_enrollment_admissions AS prior_admission
               JOIN moderation_operator_enrollment_requests AS prior_request
                 ON prior_request.enrollment_request_id =
                    prior_admission.enrollment_request_id
               JOIN moderation_operator_credentials AS prior_credential
                 ON prior_credential.credential_id_sha256 =
                    request.superseded_credential_id_sha256
                AND prior_credential.operator_id = request.target_operator_id
              WHERE prior_admission.enrollment_admission_id =
                    request.superseded_enrollment_admission_id
                AND prior_request.target_operator_id = request.target_operator_id
                AND prior_request.target_credential_id_sha256 =
                    request.superseded_credential_id_sha256
                AND EXISTS (
                  SELECT 1 FROM moderation_operator_credential_events
                   WHERE credential_id_sha256 =
                         request.superseded_credential_id_sha256
                     AND event_type = 'registered'
                )
                AND NOT EXISTS (
                  SELECT 1
                    FROM moderation_operator_enrollment_admissions AS newer_admission
                    JOIN moderation_operator_enrollment_requests AS newer_request
                      ON newer_request.enrollment_request_id =
                         newer_admission.enrollment_request_id
                   WHERE newer_request.target_operator_id =
                         request.target_operator_id
                     AND newer_admission.rowid > prior_admission.rowid
                )
           )
      )
      THEN RAISE(ABORT, 'recovery superseded credential is not current')
      WHEN (
        SELECT COUNT(DISTINCT approval.approver_operator_id)
          FROM moderation_operator_enrollment_admin_approvals AS approval
          JOIN moderation_operator_access_sessions AS session
            ON session.access_session_sha256 =
               approval.approver_access_session_sha256
          JOIN moderation_operator_enrollment_admissions AS approver_admission
            ON approver_admission.enrollment_admission_id =
               approval.approver_admission_id
          JOIN moderation_operator_enrollment_migration_fence AS fence
            ON fence.migration_version = 17
          JOIN moderation_operator_enrollment_requests AS admitted_request
            ON admitted_request.enrollment_request_id =
               approver_admission.enrollment_request_id
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 =
               approval.approver_credential_id_sha256
           AND credential.operator_id = approval.approver_operator_id
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = approval.approver_operator_id
           AND identity.access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND identity.access_subject_hmac = session.access_subject_hmac
         WHERE approval.enrollment_request_id = NEW.enrollment_request_id
           AND session.operator_id = approval.approver_operator_id
           AND session.rowid > fence.access_session_rowid_high_water
           AND session.admitted_at >= approver_admission.admitted_at
           AND session.token_expires_at > NEW.admitted_at
           AND admitted_request.target_operator_id =
               approval.approver_operator_id
           AND admitted_request.target_access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND admitted_request.target_access_subject_hmac =
               session.access_subject_hmac
           AND admitted_request.target_credential_id_sha256 =
               approval.approver_credential_id_sha256
           AND credential.registration_sign_count =
               admitted_request.target_registration_sign_count
           AND credential.public_key_cose =
               admitted_request.target_public_key_cose_snapshot
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = approval.approver_operator_id
                AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = approval.approver_operator_id
                AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_role_events
              WHERE operator_id = approval.approver_operator_id
                AND role_code = 'security_admin' AND event_type = 'granted'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_role_events
              WHERE operator_id = approval.approver_operator_id
                AND role_code = 'security_admin' AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 =
                    approval.approver_credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 =
                    approval.approver_credential_id_sha256
                AND event_type = 'revoked'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = approval.approver_operator_id
                AND newer.access_subject_hmac_key_version >
                    session.access_subject_hmac_key_version
           )
      ) < COALESCE((
        SELECT (CASE
          WHEN request.enrollment_kind = 'enrollment' THEN 1
          WHEN request.enrollment_kind = 'recovery' THEN 2
          ELSE 0
        END)
          FROM moderation_operator_enrollment_requests AS request
         WHERE request.enrollment_request_id = NEW.enrollment_request_id
      ), 0)
      THEN RAISE(ABORT, 'enrollment lacks current distinct security admins')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_requests AS request
         WHERE request.enrollment_request_id = NEW.enrollment_request_id
           AND request.enrollment_kind = 'initial_bootstrap'
      ) AND EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_admissions
      )
      THEN RAISE(ABORT, 'initial bootstrap is already complete')
    END);
END;

CREATE TRIGGER moderation_operator_enrollment_admissions_are_append_only
BEFORE UPDATE ON moderation_operator_enrollment_admissions
BEGIN SELECT RAISE(ABORT, 'enrollment admissions are append-only'); END;

CREATE TRIGGER moderation_operator_enrollment_admissions_cannot_be_deleted
BEFORE DELETE ON moderation_operator_enrollment_admissions
BEGIN SELECT RAISE(ABORT, 'enrollment admissions cannot be deleted'); END;

-- Recovery is replacement, not credential addition. An emergency-revoked prior
-- credential remains recoverable; otherwise revocation is appended as part of
-- the same SQLite statement and a failed append rolls the admission back.
CREATE TRIGGER moderation_operator_recovery_admission_revokes_superseded_credential
AFTER INSERT ON moderation_operator_enrollment_admissions
WHEN EXISTS (
  SELECT 1 FROM moderation_operator_enrollment_requests
   WHERE enrollment_request_id = NEW.enrollment_request_id
     AND enrollment_kind = 'recovery'
)
BEGIN
    INSERT INTO moderation_operator_credential_events(
      credential_id_sha256, event_type, recorded_at
    )
    SELECT request.superseded_credential_id_sha256, 'revoked', unixepoch()
      FROM moderation_operator_enrollment_requests AS request
     WHERE request.enrollment_request_id = NEW.enrollment_request_id
       AND NOT EXISTS (
         SELECT 1
           FROM moderation_operator_credential_events AS event
          WHERE event.credential_id_sha256 =
                request.superseded_credential_id_sha256
            AND event.event_type = 'revoked'
       );
END;

-- A direct 0013 insert can no longer mint a post-0017 Access session. The
-- session must match a current admitted alias and at least one live admitted
-- credential. Existing pre-0017 sessions remain for forensic compatibility,
-- but cannot issue a new challenge without an exact admission below.
CREATE TRIGGER moderation_operator_new_access_sessions_require_enrollment
BEFORE INSERT ON moderation_operator_access_sessions
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_enrollment_admissions AS admission
          JOIN moderation_operator_enrollment_requests AS request
            ON request.enrollment_request_id = admission.enrollment_request_id
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 =
               request.target_credential_id_sha256
           AND credential.operator_id = request.target_operator_id
         WHERE request.target_operator_id = NEW.operator_id
           AND request.target_access_subject_hmac_key_version =
               NEW.access_subject_hmac_key_version
           AND request.target_access_subject_hmac = NEW.access_subject_hmac
           AND NEW.admitted_at >= admission.admitted_at
           AND credential.registration_sign_count =
               request.target_registration_sign_count
           AND credential.public_key_cose =
               request.target_public_key_cose_snapshot
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = request.target_credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = request.target_credential_id_sha256
                AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'access session requires admitted enrollment')
    END);
END;

CREATE TRIGGER moderation_operator_new_reservations_require_enrollment
BEFORE INSERT ON moderation_case_reservations
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_access_sessions AS session
          JOIN moderation_operator_enrollment_requests AS request
            ON request.target_operator_id = session.operator_id
           AND request.target_access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND request.target_access_subject_hmac = session.access_subject_hmac
          JOIN moderation_operator_enrollment_admissions AS admission
            ON admission.enrollment_request_id = request.enrollment_request_id
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 =
               request.target_credential_id_sha256
           AND credential.operator_id = request.target_operator_id
          JOIN moderation_operator_enrollment_migration_fence AS fence
            ON fence.migration_version = 17
         WHERE session.access_session_sha256 = NEW.access_session_sha256
           AND session.operator_id = NEW.operator_id
           AND session.access_subject_hmac_key_version =
               NEW.access_subject_hmac_key_version
           AND session.rowid > fence.access_session_rowid_high_water
           AND session.admitted_at >= admission.admitted_at
           AND credential.registration_sign_count =
               request.target_registration_sign_count
           AND credential.public_key_cose =
               request.target_public_key_cose_snapshot
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = request.target_credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = request.target_credential_id_sha256
                AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'case reservation requires enrolled access session')
    END);
END;

CREATE TRIGGER moderation_operator_new_challenges_require_enrollment
BEFORE INSERT ON moderation_operator_challenges
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_access_sessions AS session
          JOIN moderation_operator_enrollment_requests AS request
            ON request.target_operator_id = session.operator_id
          JOIN moderation_operator_enrollment_admissions AS admission
            ON admission.enrollment_request_id = request.enrollment_request_id
          JOIN moderation_operator_enrollment_migration_fence AS fence
            ON fence.migration_version = 17
         WHERE session.access_session_sha256 = NEW.access_session_sha256
           AND session.operator_id = NEW.operator_id
           AND request.target_operator_id = NEW.operator_id
           AND request.target_access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND request.target_access_subject_hmac = session.access_subject_hmac
           AND request.target_credential_id_sha256 =
               NEW.credential_id_sha256
           AND session.admitted_at >= admission.admitted_at
           AND session.rowid > fence.access_session_rowid_high_water
      )
      THEN RAISE(ABORT, 'operator challenge requires exact enrollment admission')
    END);
END;

CREATE TRIGGER moderation_operator_new_assertion_attempts_require_enrollment
BEFORE INSERT ON moderation_operator_assertion_attempts
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_enrollment_trusted_challenges
         WHERE challenge_id = NEW.challenge_id
           AND operator_id = NEW.operator_id
           AND credential_id_sha256 = NEW.credential_id_sha256
           AND access_session_sha256 = NEW.access_session_sha256
      )
      THEN RAISE(ABORT, 'assertion attempt requires enrolled challenge')
    END);
END;

CREATE TRIGGER moderation_operator_new_consumptions_require_enrollment
BEFORE INSERT ON moderation_operator_challenge_consumptions
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_enrollment_trusted_challenges AS trusted
          JOIN moderation_operator_assertion_attempts AS attempt
            ON attempt.challenge_id = trusted.challenge_id
         WHERE trusted.challenge_id = NEW.challenge_id
           AND trusted.operator_id = NEW.operator_id
           AND trusted.credential_id_sha256 = NEW.credential_id_sha256
           AND attempt.assertion_sha256 = NEW.verified_assertion_sha256
      )
      THEN RAISE(ABORT, 'challenge consumption requires enrolled attempt')
    END);
END;

CREATE TRIGGER moderation_operator_new_actions_require_enrollment
BEFORE INSERT ON moderation_operator_actions
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_enrollment_trusted_challenges AS trusted
          JOIN moderation_operator_challenge_consumptions AS consumption
            ON consumption.challenge_id = trusted.challenge_id
         WHERE trusted.challenge_id = NEW.request_challenge_id
           AND trusted.operator_id = NEW.requester_operator_id
      )
      THEN RAISE(ABORT, 'operator action requires enrolled assertion chain')
      WHEN NEW.action_type = 'review_start' AND NOT EXISTS (
        SELECT 1
          FROM moderation_case_reservations AS reservation
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = NEW.request_challenge_id
          JOIN moderation_operator_enrollment_migration_fence AS fence
            ON fence.migration_version = 17
         WHERE reservation.operator_id = NEW.requester_operator_id
           AND reservation.case_reference_hmac = NEW.case_reference_hmac
           AND reservation.access_session_sha256 =
               challenge.access_session_sha256
           AND reservation.rowid > fence.reservation_rowid_high_water
           AND NOT EXISTS (
             SELECT 1 FROM moderation_case_reservation_consumptions
              WHERE reservation_id = reservation.reservation_id
           )
      )
      THEN RAISE(ABORT, 'review action requires enrolled-era reservation')
    END);
END;

CREATE TRIGGER moderation_operator_new_action_approvals_require_enrollment
BEFORE INSERT ON moderation_operator_action_approvals
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_enrollment_trusted_challenges AS trusted
          JOIN moderation_operator_challenge_consumptions AS consumption
            ON consumption.challenge_id = trusted.challenge_id
         WHERE trusted.challenge_id = NEW.approval_challenge_id
           AND trusted.operator_id = NEW.operator_id
      )
      THEN RAISE(ABORT, 'operator approval requires enrolled assertion chain')
    END);
END;

CREATE TRIGGER moderation_operator_new_evidence_intents_require_enrollment
BEFORE INSERT ON moderation_evidence_event_intents
WHEN NEW.legacy_backfill = 0
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_enrollment_trusted_challenges AS trusted
            ON trusted.challenge_id = action.request_challenge_id
         WHERE action.action_id = NEW.action_id
           AND trusted.operator_id = action.requester_operator_id
      )
      THEN RAISE(ABORT, 'evidence intent requires enrolled assertion chain')
    END);
END;

CREATE TRIGGER moderation_operator_new_ledger_events_require_enrollment
BEFORE INSERT ON moderation_evidence_ledger_events
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_evidence_event_intents AS intent
          JOIN moderation_operator_actions AS action
            ON action.action_id = intent.action_id
          JOIN moderation_operator_enrollment_trusted_challenges AS trusted
            ON trusted.challenge_id = action.request_challenge_id
         WHERE intent.event_id = NEW.event_id
           AND intent.action_id = NEW.action_id
           AND trusted.operator_id = action.requester_operator_id
      )
      THEN RAISE(ABORT, 'evidence event requires enrolled assertion chain')
    END);
END;

CREATE TRIGGER moderation_operator_new_exports_require_enrollment
BEFORE INSERT ON moderation_evidence_exports
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_enrollment_trusted_challenges AS trusted
            ON trusted.challenge_id = action.request_challenge_id
         WHERE action.action_id = NEW.action_id
           AND trusted.operator_id = action.requester_operator_id
      )
      THEN RAISE(ABORT, 'evidence export requires enrolled assertion chain')
    END);
END;
