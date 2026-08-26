-- Isolated moderation operator control-plane foundation.
--
-- This migration intentionally adds no public route, Worker binding or
-- deployable operator entry point. Raw email, name, Access JWT and WebAuthn
-- credential IDs/assertions are never stored. Stable lookups use SHA-256 or a
-- secret-keyed HMAC prepared by the future authenticated operator service.

CREATE TABLE moderation_operators (
    operator_id TEXT PRIMARY KEY CHECK (
      length(operator_id) = 36
      AND length(CAST(operator_id AS BLOB)) = 36
      AND lower(operator_id) = operator_id
      AND substr(operator_id, 9, 1) = '-'
      AND substr(operator_id, 14, 1) = '-'
      AND substr(operator_id, 15, 1) = '4'
      AND substr(operator_id, 19, 1) = '-'
      AND substr(operator_id, 20, 1) GLOB '[89ab]'
      AND substr(operator_id, 24, 1) = '-'
      AND length(replace(operator_id, '-', '')) = 32
      AND operator_id NOT GLOB '*[^0-9a-f-]*'
    ),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

-- Subject pseudonyms are versioned append-only aliases. Key rotation appends a
-- new alias after authenticating the live Access subject; no raw subject is
-- persisted and the stable operator record never needs to be rewritten.
CREATE TABLE moderation_operator_subject_identities (
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    access_subject_hmac_key_version INTEGER NOT NULL CHECK (
      access_subject_hmac_key_version > 0
      AND access_subject_hmac_key_version <= 2147483647
    ),
    access_subject_hmac TEXT NOT NULL CHECK (
      length(access_subject_hmac) = 64
      AND length(CAST(access_subject_hmac AS BLOB)) = 64
      AND access_subject_hmac NOT GLOB '*[^0-9a-f]*'
    ),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (operator_id, access_subject_hmac_key_version),
    UNIQUE (access_subject_hmac_key_version, access_subject_hmac)
) STRICT;

CREATE TABLE moderation_operator_state_events (
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    event_type TEXT NOT NULL CHECK (event_type IN ('activated', 'revoked')),
    recorded_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (operator_id, event_type)
) STRICT;

CREATE TABLE moderation_operator_role_events (
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    role_code TEXT NOT NULL CHECK (
      role_code IN (
        'triage',
        'evidence_reviewer',
        'privacy_approver',
        'auditor',
        'security_admin'
      )
    ),
    event_type TEXT NOT NULL CHECK (event_type IN ('granted', 'revoked')),
    recorded_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (operator_id, role_code, event_type)
) STRICT;

CREATE TABLE moderation_operator_credentials (
    credential_id_sha256 TEXT PRIMARY KEY CHECK (
      length(credential_id_sha256) = 64
      AND length(CAST(credential_id_sha256 AS BLOB)) = 64
      AND credential_id_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    public_key_cose BLOB NOT NULL CHECK (
      length(public_key_cose) BETWEEN 32 AND 2048
    ),
    -- Captured from the attested authenticator data at registration. The first
    -- assertion is compared against this value, not against an empty history.
    registration_sign_count INTEGER NOT NULL CHECK (
      registration_sign_count BETWEEN 0 AND 4294967295
    ),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE TABLE moderation_operator_credential_events (
    credential_id_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_credentials(credential_id_sha256)
        ON DELETE RESTRICT,
    event_type TEXT NOT NULL CHECK (event_type IN ('registered', 'revoked')),
    recorded_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (credential_id_sha256, event_type)
) STRICT;

-- The HMAC mapping permits audit/export records to avoid exposing report IDs
-- while preserving an internal FK to the immutable moderation case.
CREATE TABLE moderation_operator_case_references (
    report_id TEXT PRIMARY KEY
        REFERENCES moderation_cases(report_id) ON DELETE RESTRICT,
    case_reference_hmac TEXT NOT NULL UNIQUE CHECK (
      length(case_reference_hmac) = 64
      AND length(CAST(case_reference_hmac AS BLOB)) = 64
      AND case_reference_hmac NOT GLOB '*[^0-9a-f]*'
    ),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    UNIQUE (report_id, case_reference_hmac)
) STRICT;

-- Stores only the SHA-256 of the random challenge and credential identifier.
-- A future route must verify the complete WebAuthn assertion before inserting
-- a consumption row; this schema does not pretend that insertion is proof.
CREATE TABLE moderation_operator_challenges (
    challenge_id TEXT PRIMARY KEY CHECK (
      length(challenge_id) = 36
      AND length(CAST(challenge_id AS BLOB)) = 36
      AND lower(challenge_id) = challenge_id
      AND substr(challenge_id, 9, 1) = '-'
      AND substr(challenge_id, 14, 1) = '-'
      AND substr(challenge_id, 15, 1) = '4'
      AND substr(challenge_id, 19, 1) = '-'
      AND substr(challenge_id, 20, 1) GLOB '[89ab]'
      AND substr(challenge_id, 24, 1) = '-'
      AND length(replace(challenge_id, '-', '')) = 32
      AND challenge_id NOT GLOB '*[^0-9a-f-]*'
    ),
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    access_subject_hmac_key_version INTEGER NOT NULL CHECK (
      access_subject_hmac_key_version > 0
      AND access_subject_hmac_key_version <= 2147483647
    ),
    credential_id_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_credentials(credential_id_sha256)
        ON DELETE RESTRICT,
    access_session_sha256 TEXT NOT NULL CHECK (
      length(access_session_sha256) = 64
      AND length(CAST(access_session_sha256 AS BLOB)) = 64
      AND access_session_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    challenge_value_sha256 TEXT NOT NULL UNIQUE CHECK (
      length(challenge_value_sha256) = 64
      AND length(CAST(challenge_value_sha256 AS BLOB)) = 64
      AND challenge_value_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    purpose TEXT NOT NULL CHECK (purpose IN ('request', 'approve')),
    action_type TEXT NOT NULL CHECK (
      action_type IN (
        'review_start',
        'evidence_export',
        'review_decision',
        'content_delete'
      )
    ),
    action_id TEXT NOT NULL CHECK (
      length(action_id) = 36
      AND length(CAST(action_id AS BLOB)) = 36
      AND lower(action_id) = action_id
      AND substr(action_id, 9, 1) = '-'
      AND substr(action_id, 14, 1) = '-'
      AND substr(action_id, 15, 1) = '4'
      AND substr(action_id, 19, 1) = '-'
      AND substr(action_id, 20, 1) GLOB '[89ab]'
      AND substr(action_id, 24, 1) = '-'
      AND length(replace(action_id, '-', '')) = 32
      AND action_id NOT GLOB '*[^0-9a-f-]*'
    ),
    case_reference_hmac TEXT NOT NULL
        REFERENCES moderation_operator_case_references(case_reference_hmac)
        ON DELETE RESTRICT,
    method TEXT NOT NULL CHECK (method IN ('POST', 'PUT', 'DELETE')),
    pathname TEXT NOT NULL CHECK (
      length(pathname) BETWEEN 14 AND 512
      AND length(CAST(pathname AS BLOB)) = length(pathname)
      AND substr(pathname, 1, 13) = '/operator/v1/'
      AND pathname = trim(pathname)
      AND instr(pathname, '//') = 0
      AND instr(pathname, '?') = 0
      AND instr(pathname, '#') = 0
      AND instr(pathname, '%') = 0
      AND instr(pathname, char(9)) = 0
      AND instr(pathname, char(10)) = 0
      AND instr(pathname, char(13)) = 0
    ),
    body_sha256 TEXT NOT NULL CHECK (
      length(body_sha256) = 64
      AND length(CAST(body_sha256 AS BLOB)) = 64
      AND body_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    issued_at INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at INTEGER NOT NULL,
    FOREIGN KEY (operator_id, access_subject_hmac_key_version)
      REFERENCES moderation_operator_subject_identities(
        operator_id, access_subject_hmac_key_version
      ) ON DELETE RESTRICT,
    CHECK (expires_at > issued_at AND expires_at <= issued_at + 300)
) STRICT;

CREATE INDEX moderation_operator_challenges_expiry
    ON moderation_operator_challenges(expires_at, challenge_id);

CREATE INDEX moderation_operator_challenges_active_per_operator
    ON moderation_operator_challenges(operator_id, expires_at, challenge_id);

CREATE TABLE moderation_operator_challenge_consumptions (
    challenge_id TEXT PRIMARY KEY
        REFERENCES moderation_operator_challenges(challenge_id)
        ON DELETE RESTRICT,
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    credential_id_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_credentials(credential_id_sha256)
        ON DELETE RESTRICT,
    verified_assertion_sha256 TEXT NOT NULL UNIQUE CHECK (
      length(verified_assertion_sha256) = 64
      AND length(CAST(verified_assertion_sha256 AS BLOB)) = 64
      AND verified_assertion_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    -- Zero is retained for authenticators that do not implement a signature
    -- counter. A positive counter may only increase. This value is not proof
    -- of WebAuthn verification; the future service must complete origin, RP,
    -- UV, challenge and signature verification before inserting this row.
    authenticator_sign_count INTEGER NOT NULL CHECK (
      authenticator_sign_count BETWEEN 0 AND 4294967295
    ),
    consumed_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

-- Supports bounded per-credential counter validation without rescanning all
-- consumed challenges.
CREATE INDEX moderation_operator_consumptions_credential_counter
    ON moderation_operator_challenge_consumptions(
      credential_id_sha256, authenticator_sign_count DESC, consumed_at DESC
    );

CREATE TABLE moderation_operator_actions (
    action_id TEXT PRIMARY KEY CHECK (
      length(action_id) = 36
      AND length(CAST(action_id AS BLOB)) = 36
      AND lower(action_id) = action_id
      AND substr(action_id, 9, 1) = '-'
      AND substr(action_id, 14, 1) = '-'
      AND substr(action_id, 15, 1) = '4'
      AND substr(action_id, 19, 1) = '-'
      AND substr(action_id, 20, 1) GLOB '[89ab]'
      AND substr(action_id, 24, 1) = '-'
      AND length(replace(action_id, '-', '')) = 32
      AND action_id NOT GLOB '*[^0-9a-f-]*'
    ),
    case_reference_hmac TEXT NOT NULL
        REFERENCES moderation_operator_case_references(case_reference_hmac)
        ON DELETE RESTRICT,
    action_type TEXT NOT NULL CHECK (
      action_type IN (
        'review_start',
        'evidence_export',
        'review_decision',
        'content_delete'
      )
    ),
    requester_operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    request_challenge_id TEXT NOT NULL UNIQUE
        REFERENCES moderation_operator_challenge_consumptions(challenge_id)
        ON DELETE RESTRICT,
    request_sha256 TEXT NOT NULL CHECK (
      length(request_sha256) = 64
      AND length(CAST(request_sha256 AS BLOB)) = 64
      AND request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    request_method TEXT NOT NULL CHECK (
      request_method IN ('POST', 'PUT', 'DELETE')
    ),
    request_pathname TEXT NOT NULL CHECK (
      length(request_pathname) BETWEEN 14 AND 512
      AND length(CAST(request_pathname AS BLOB)) = length(request_pathname)
      AND substr(request_pathname, 1, 13) = '/operator/v1/'
      AND request_pathname = trim(request_pathname)
      AND instr(request_pathname, '//') = 0
      AND instr(request_pathname, '?') = 0
      AND instr(request_pathname, '#') = 0
      AND instr(request_pathname, '%') = 0
      AND instr(request_pathname, char(9)) = 0
      AND instr(request_pathname, char(10)) = 0
      AND instr(request_pathname, char(13)) = 0
    ),
    required_approvals INTEGER NOT NULL CHECK (
      required_approvals BETWEEN 0 AND 2
    ),
    required_approver_role TEXT CHECK (
      required_approver_role IS NULL
      OR required_approver_role IN ('privacy_approver', 'auditor')
    ),
    requested_at INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at INTEGER NOT NULL,
    CHECK (expires_at > requested_at AND expires_at <= requested_at + 900),
    CHECK (
      (action_type = 'review_start'
       AND required_approvals = 0 AND required_approver_role IS NULL)
      OR
      (action_type IN ('evidence_export', 'review_decision', 'content_delete')
       AND required_approvals = 1 AND required_approver_role = 'privacy_approver')
    )
) STRICT;

CREATE INDEX moderation_operator_actions_expiry
    ON moderation_operator_actions(expires_at, action_id);

CREATE TABLE moderation_operator_action_approvals (
    action_id TEXT NOT NULL
        REFERENCES moderation_operator_actions(action_id) ON DELETE RESTRICT,
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    approval_challenge_id TEXT NOT NULL UNIQUE
        REFERENCES moderation_operator_challenge_consumptions(challenge_id)
        ON DELETE RESTRICT,
    approval_sha256 TEXT NOT NULL CHECK (
      length(approval_sha256) = 64
      AND length(CAST(approval_sha256 AS BLOB)) = 64
      AND approval_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    approval_method TEXT NOT NULL CHECK (
      approval_method IN ('POST', 'PUT', 'DELETE')
    ),
    approval_pathname TEXT NOT NULL CHECK (
      length(approval_pathname) BETWEEN 14 AND 512
      AND length(CAST(approval_pathname AS BLOB)) = length(approval_pathname)
      AND substr(approval_pathname, 1, 13) = '/operator/v1/'
      AND approval_pathname = trim(approval_pathname)
      AND instr(approval_pathname, '//') = 0
      AND instr(approval_pathname, '?') = 0
      AND instr(approval_pathname, '#') = 0
      AND instr(approval_pathname, '%') = 0
      AND instr(approval_pathname, char(9)) = 0
      AND instr(approval_pathname, char(10)) = 0
      AND instr(approval_pathname, char(13)) = 0
    ),
    recorded_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (action_id, operator_id)
) STRICT;

-- Base rows and all lifecycle/event rows are immutable and non-replaceable.
CREATE TRIGGER moderation_operators_validate_insert
BEFORE INSERT ON moderation_operators
BEGIN
    SELECT (CASE
      WHEN NEW.created_at <> unixepoch()
      THEN RAISE(ABORT, 'operator must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operators
         WHERE operator_id = NEW.operator_id
      )
      THEN RAISE(ABORT, 'operator cannot be replaced')
    END);
END;

CREATE TRIGGER moderation_operators_are_immutable
BEFORE UPDATE ON moderation_operators
BEGIN SELECT RAISE(ABORT, 'operators are immutable'); END;

CREATE TRIGGER moderation_operators_cannot_be_deleted
BEFORE DELETE ON moderation_operators
BEGIN SELECT RAISE(ABORT, 'operators cannot be deleted'); END;

CREATE TRIGGER moderation_operator_subject_identities_validate
BEFORE INSERT ON moderation_operator_subject_identities
BEGIN
    SELECT (CASE
      WHEN NEW.created_at <> unixepoch()
      THEN RAISE(ABORT, 'operator subject identity must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_subject_identities
         WHERE (operator_id = NEW.operator_id
                AND access_subject_hmac_key_version =
                    NEW.access_subject_hmac_key_version)
            OR (access_subject_hmac_key_version =
                  NEW.access_subject_hmac_key_version
                AND access_subject_hmac = NEW.access_subject_hmac)
      )
      THEN RAISE(ABORT, 'operator subject identity cannot be replaced')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_subject_identities
         WHERE operator_id = NEW.operator_id
           AND access_subject_hmac_key_version >=
               NEW.access_subject_hmac_key_version
      )
      THEN RAISE(ABORT, 'operator subject HMAC key version must increase')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_subject_identities
         WHERE operator_id = NEW.operator_id
      ) AND (
        NOT EXISTS (
          SELECT 1 FROM moderation_operator_state_events
           WHERE operator_id = NEW.operator_id AND event_type = 'activated'
        ) OR EXISTS (
          SELECT 1 FROM moderation_operator_state_events
           WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
        )
      )
      THEN RAISE(ABORT, 'operator is not active for subject HMAC rotation')
    END);
END;

CREATE TRIGGER moderation_operator_subject_identities_are_append_only
BEFORE UPDATE ON moderation_operator_subject_identities
BEGIN SELECT RAISE(ABORT, 'operator subject identities are append-only'); END;

CREATE TRIGGER moderation_operator_subject_identities_cannot_be_deleted
BEFORE DELETE ON moderation_operator_subject_identities
BEGIN SELECT RAISE(ABORT, 'operator subject identities cannot be deleted'); END;

CREATE TRIGGER moderation_operator_state_events_validate
BEFORE INSERT ON moderation_operator_state_events
BEGIN
    SELECT (CASE
      WHEN NEW.recorded_at <> unixepoch()
      THEN RAISE(ABORT, 'operator state event must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = NEW.event_type
      )
      THEN RAISE(ABORT, 'operator state event cannot be replaced')
      WHEN NEW.event_type = 'activated' AND EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id
      )
      THEN RAISE(ABORT, 'operator has already been activated')
      WHEN NEW.event_type = 'activated' AND NOT EXISTS (
        SELECT 1 FROM moderation_operator_subject_identities
         WHERE operator_id = NEW.operator_id
      )
      THEN RAISE(ABORT, 'operator requires a subject identity')
      WHEN NEW.event_type = 'revoked' AND NOT EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'activated'
      )
      THEN RAISE(ABORT, 'operator must be activated before revocation')
    END);
END;

CREATE TRIGGER moderation_operator_state_events_are_append_only
BEFORE UPDATE ON moderation_operator_state_events
BEGIN SELECT RAISE(ABORT, 'operator state events are append-only'); END;

CREATE TRIGGER moderation_operator_state_events_cannot_be_deleted
BEFORE DELETE ON moderation_operator_state_events
BEGIN SELECT RAISE(ABORT, 'operator state events cannot be deleted'); END;

CREATE TRIGGER moderation_operator_role_events_validate
BEFORE INSERT ON moderation_operator_role_events
BEGIN
    SELECT (CASE
      WHEN NEW.recorded_at <> unixepoch()
      THEN RAISE(ABORT, 'operator role event must use database time')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'activated'
      ) OR EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
      )
      THEN RAISE(ABORT, 'operator is not active')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_role_events
         WHERE operator_id = NEW.operator_id
           AND role_code = NEW.role_code AND event_type = NEW.event_type
      )
      THEN RAISE(ABORT, 'operator role event cannot be replaced')
      WHEN NEW.event_type = 'granted' AND EXISTS (
        SELECT 1 FROM moderation_operator_role_events
         WHERE operator_id = NEW.operator_id AND role_code = NEW.role_code
      )
      THEN RAISE(ABORT, 'operator role has already been granted')
      WHEN NEW.event_type = 'revoked' AND (
        NOT EXISTS (
          SELECT 1 FROM moderation_operator_role_events
           WHERE operator_id = NEW.operator_id
             AND role_code = NEW.role_code AND event_type = 'granted'
        ) OR EXISTS (
          SELECT 1 FROM moderation_operator_role_events
           WHERE operator_id = NEW.operator_id
             AND role_code = NEW.role_code AND event_type = 'revoked'
        )
      )
      THEN RAISE(ABORT, 'operator role is not active')
      WHEN NEW.event_type = 'granted'
       AND NEW.role_code IN ('evidence_reviewer', 'privacy_approver')
       AND EXISTS (
         SELECT 1 FROM moderation_operator_role_events AS granted
          WHERE granted.operator_id = NEW.operator_id
            AND granted.event_type = 'granted'
            AND granted.role_code IN ('evidence_reviewer', 'privacy_approver')
            AND granted.role_code <> NEW.role_code
            AND NOT EXISTS (
              SELECT 1 FROM moderation_operator_role_events AS revoked
               WHERE revoked.operator_id = granted.operator_id
                 AND revoked.role_code = granted.role_code
                 AND revoked.event_type = 'revoked'
            )
       )
      THEN RAISE(ABORT, 'reviewer and privacy approver roles are separated')
    END);
END;

CREATE TRIGGER moderation_operator_role_events_are_append_only
BEFORE UPDATE ON moderation_operator_role_events
BEGIN SELECT RAISE(ABORT, 'operator role events are append-only'); END;

CREATE TRIGGER moderation_operator_role_events_cannot_be_deleted
BEFORE DELETE ON moderation_operator_role_events
BEGIN SELECT RAISE(ABORT, 'operator role events cannot be deleted'); END;

CREATE TRIGGER moderation_operator_credentials_validate_insert
BEFORE INSERT ON moderation_operator_credentials
BEGIN
    SELECT (CASE
      WHEN NEW.created_at <> unixepoch()
      THEN RAISE(ABORT, 'operator credential must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_credentials
         WHERE credential_id_sha256 = NEW.credential_id_sha256
      )
      THEN RAISE(ABORT, 'operator credential cannot be replaced')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'activated'
      ) OR EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
      )
      THEN RAISE(ABORT, 'operator is not active')
    END);
END;

CREATE TRIGGER moderation_operator_credentials_are_immutable
BEFORE UPDATE ON moderation_operator_credentials
BEGIN SELECT RAISE(ABORT, 'operator credentials are immutable'); END;

CREATE TRIGGER moderation_operator_credentials_cannot_be_deleted
BEFORE DELETE ON moderation_operator_credentials
BEGIN SELECT RAISE(ABORT, 'operator credentials cannot be deleted'); END;

CREATE TRIGGER moderation_operator_credential_events_validate
BEFORE INSERT ON moderation_operator_credential_events
BEGIN
    SELECT (CASE
      WHEN NEW.recorded_at <> unixepoch()
      THEN RAISE(ABORT, 'credential event must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_credential_events
         WHERE credential_id_sha256 = NEW.credential_id_sha256
           AND event_type = NEW.event_type
      )
      THEN RAISE(ABORT, 'credential event cannot be replaced')
      WHEN NEW.event_type = 'registered' AND EXISTS (
        SELECT 1 FROM moderation_operator_credential_events
         WHERE credential_id_sha256 = NEW.credential_id_sha256
      )
      THEN RAISE(ABORT, 'credential has already been registered')
      WHEN NEW.event_type = 'revoked' AND NOT EXISTS (
        SELECT 1 FROM moderation_operator_credential_events
         WHERE credential_id_sha256 = NEW.credential_id_sha256
           AND event_type = 'registered'
      )
      THEN RAISE(ABORT, 'credential must be registered before revocation')
    END);
END;

CREATE TRIGGER moderation_operator_credential_events_are_append_only
BEFORE UPDATE ON moderation_operator_credential_events
BEGIN SELECT RAISE(ABORT, 'credential events are append-only'); END;

CREATE TRIGGER moderation_operator_credential_events_cannot_be_deleted
BEFORE DELETE ON moderation_operator_credential_events
BEGIN SELECT RAISE(ABORT, 'credential events cannot be deleted'); END;

CREATE TRIGGER moderation_operator_case_references_validate_insert
BEFORE INSERT ON moderation_operator_case_references
BEGIN
    SELECT (CASE
      WHEN NEW.created_at <> unixepoch()
      THEN RAISE(ABORT, 'case reference must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_case_references
         WHERE report_id = NEW.report_id
            OR case_reference_hmac = NEW.case_reference_hmac
      )
      THEN RAISE(ABORT, 'case reference cannot be replaced')
    END);
END;

CREATE TRIGGER moderation_operator_case_references_are_immutable
BEFORE UPDATE ON moderation_operator_case_references
BEGIN SELECT RAISE(ABORT, 'case references are immutable'); END;

CREATE TRIGGER moderation_operator_case_references_cannot_be_deleted
BEFORE DELETE ON moderation_operator_case_references
BEGIN SELECT RAISE(ABORT, 'case references cannot be deleted'); END;

CREATE TRIGGER moderation_operator_challenges_validate_insert
BEFORE INSERT ON moderation_operator_challenges
BEGIN
    SELECT (CASE
      WHEN NEW.issued_at <> unixepoch()
      THEN RAISE(ABORT, 'operator challenge must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_challenges
         WHERE challenge_id = NEW.challenge_id
            OR challenge_value_sha256 = NEW.challenge_value_sha256
      )
      THEN RAISE(ABORT, 'operator challenge cannot be replaced')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'activated'
      ) OR EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
      )
      THEN RAISE(ABORT, 'operator is not active')
      WHEN (
        SELECT COUNT(*)
          FROM moderation_operator_challenges AS challenge
         WHERE challenge.operator_id = NEW.operator_id
           AND challenge.expires_at >= NEW.issued_at
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_challenge_consumptions AS consumption
              WHERE consumption.challenge_id = challenge.challenge_id
           )
      ) >= 8
      THEN RAISE(ABORT, 'operator has too many active challenges')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_credentials AS credential
         WHERE credential.credential_id_sha256 = NEW.credential_id_sha256
           AND credential.operator_id = NEW.operator_id
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = credential.credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = credential.credential_id_sha256
                AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'operator credential is not active')
    END);
END;

CREATE TRIGGER moderation_operator_challenges_are_immutable
BEFORE UPDATE ON moderation_operator_challenges
BEGIN SELECT RAISE(ABORT, 'operator challenges are immutable'); END;

CREATE TRIGGER moderation_operator_challenges_cannot_be_deleted
BEFORE DELETE ON moderation_operator_challenges
BEGIN SELECT RAISE(ABORT, 'operator challenges cannot be deleted'); END;

CREATE TRIGGER moderation_operator_challenge_consumptions_validate
BEFORE INSERT ON moderation_operator_challenge_consumptions
BEGIN
    SELECT (CASE
      WHEN NEW.consumed_at <> unixepoch()
      THEN RAISE(ABORT, 'challenge consumption must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_challenge_consumptions
         WHERE challenge_id = NEW.challenge_id
            OR verified_assertion_sha256 = NEW.verified_assertion_sha256
      )
      THEN RAISE(ABORT, 'operator challenge has already been consumed')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_challenges AS challenge
         WHERE challenge.challenge_id = NEW.challenge_id
           AND challenge.operator_id = NEW.operator_id
           AND challenge.credential_id_sha256 = NEW.credential_id_sha256
           AND challenge.issued_at <= NEW.consumed_at
           AND challenge.expires_at >= NEW.consumed_at
      )
      THEN RAISE(ABORT, 'operator challenge is expired or mismatched')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_challenges AS challenge
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 = challenge.credential_id_sha256
         WHERE challenge.challenge_id = NEW.challenge_id
           AND challenge.credential_id_sha256 = NEW.credential_id_sha256
           AND credential.operator_id = NEW.operator_id
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = credential.credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = credential.credential_id_sha256
                AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'operator credential is not active')
      WHEN NEW.authenticator_sign_count = 0 AND EXISTS (
        SELECT 1
          FROM moderation_operator_credentials AS credential
         WHERE credential.credential_id_sha256 = NEW.credential_id_sha256
           AND (
             credential.registration_sign_count > 0
             OR EXISTS (
               SELECT 1
                 FROM moderation_operator_challenge_consumptions AS prior
                WHERE prior.credential_id_sha256 = NEW.credential_id_sha256
                  AND prior.authenticator_sign_count > 0
             )
           )
      )
      THEN RAISE(ABORT, 'authenticator signature counter rolled back')
      WHEN NEW.authenticator_sign_count > 0
       AND NEW.authenticator_sign_count <= COALESCE((
         SELECT MAX(observed_sign_count)
           FROM (
             SELECT credential.registration_sign_count AS observed_sign_count
               FROM moderation_operator_credentials AS credential
              WHERE credential.credential_id_sha256 = NEW.credential_id_sha256
             UNION ALL
             SELECT prior.authenticator_sign_count AS observed_sign_count
               FROM moderation_operator_challenge_consumptions AS prior
              WHERE prior.credential_id_sha256 = NEW.credential_id_sha256
           )
       ), -1)
      THEN RAISE(ABORT, 'authenticator signature counter did not increase')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'activated'
      ) OR EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
      )
      THEN RAISE(ABORT, 'operator is not active')
    END);
END;

CREATE TRIGGER moderation_operator_challenge_consumptions_are_append_only
BEFORE UPDATE ON moderation_operator_challenge_consumptions
BEGIN SELECT RAISE(ABORT, 'challenge consumptions are append-only'); END;

CREATE TRIGGER moderation_operator_challenge_consumptions_cannot_be_deleted
BEFORE DELETE ON moderation_operator_challenge_consumptions
BEGIN SELECT RAISE(ABORT, 'challenge consumptions cannot be deleted'); END;

CREATE TRIGGER moderation_operator_actions_validate_insert
BEFORE INSERT ON moderation_operator_actions
BEGIN
    SELECT (CASE
      WHEN NEW.requested_at <> unixepoch()
      THEN RAISE(ABORT, 'operator action must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_actions
         WHERE action_id = NEW.action_id
            OR request_challenge_id = NEW.request_challenge_id
      )
      THEN RAISE(ABORT, 'operator action cannot be replaced')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_challenge_consumptions AS consumption
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = consumption.challenge_id
         WHERE consumption.challenge_id = NEW.request_challenge_id
           AND consumption.operator_id = NEW.requester_operator_id
           AND challenge.operator_id = NEW.requester_operator_id
           AND challenge.purpose = 'request'
           AND challenge.action_type = NEW.action_type
           AND challenge.action_id = NEW.action_id
           AND challenge.case_reference_hmac = NEW.case_reference_hmac
           AND challenge.body_sha256 = NEW.request_sha256
           AND challenge.method = NEW.request_method
           AND challenge.pathname = NEW.request_pathname
           AND consumption.consumed_at <= NEW.requested_at
           AND challenge.expires_at >= NEW.requested_at
      )
      THEN RAISE(ABORT, 'operator action lacks its bound step-up')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_challenge_consumptions AS consumption
          JOIN moderation_operator_credential_events AS registered
            ON registered.credential_id_sha256 = consumption.credential_id_sha256
           AND registered.event_type = 'registered'
         WHERE consumption.challenge_id = NEW.request_challenge_id
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events AS revoked
              WHERE revoked.credential_id_sha256 = consumption.credential_id_sha256
                AND revoked.event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'request credential is not active')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.requester_operator_id AND event_type = 'activated'
      ) OR EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.requester_operator_id AND event_type = 'revoked'
      )
      THEN RAISE(ABORT, 'requesting operator is not active')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_role_events AS granted
         WHERE granted.operator_id = NEW.requester_operator_id
           AND granted.event_type = 'granted'
           AND granted.role_code = CASE NEW.action_type
             WHEN 'review_start' THEN 'triage'
             ELSE 'evidence_reviewer'
           END
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_role_events AS revoked
              WHERE revoked.operator_id = granted.operator_id
                AND revoked.role_code = granted.role_code
                AND revoked.event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'requesting operator role is not active')
    END);
END;

CREATE TRIGGER moderation_operator_actions_are_immutable
BEFORE UPDATE ON moderation_operator_actions
BEGIN SELECT RAISE(ABORT, 'operator actions are immutable'); END;

CREATE TRIGGER moderation_operator_actions_cannot_be_deleted
BEFORE DELETE ON moderation_operator_actions
BEGIN SELECT RAISE(ABORT, 'operator actions cannot be deleted'); END;

CREATE TRIGGER moderation_operator_action_approvals_validate
BEFORE INSERT ON moderation_operator_action_approvals
BEGIN
    SELECT (CASE
      WHEN NEW.recorded_at <> unixepoch()
      THEN RAISE(ABORT, 'operator approval must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_action_approvals
         WHERE (action_id = NEW.action_id AND operator_id = NEW.operator_id)
            OR approval_challenge_id = NEW.approval_challenge_id
      )
      THEN RAISE(ABORT, 'operator approval cannot be replaced or repeated')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_actions
         WHERE action_id = NEW.action_id
           AND requester_operator_id = NEW.operator_id
      )
      THEN RAISE(ABORT, 'operator cannot approve their own action')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_actions
         WHERE action_id = NEW.action_id
           AND required_approvals > 0
           AND expires_at >= NEW.recorded_at
      )
      THEN RAISE(ABORT, 'operator action is expired or needs no approval')
      WHEN (SELECT COUNT(*) FROM moderation_operator_action_approvals
             WHERE action_id = NEW.action_id) >= (
               SELECT required_approvals FROM moderation_operator_actions
                WHERE action_id = NEW.action_id
             )
      THEN RAISE(ABORT, 'operator action already has enough approvals')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_challenge_consumptions AS consumption
            ON consumption.challenge_id = NEW.approval_challenge_id
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = consumption.challenge_id
         WHERE action.action_id = NEW.action_id
           AND consumption.operator_id = NEW.operator_id
           AND challenge.operator_id = NEW.operator_id
           AND challenge.purpose = 'approve'
           AND challenge.action_type = action.action_type
           AND challenge.action_id = action.action_id
           AND challenge.case_reference_hmac = action.case_reference_hmac
           AND challenge.body_sha256 = NEW.approval_sha256
           AND challenge.method = NEW.approval_method
           AND challenge.pathname = NEW.approval_pathname
           AND challenge.issued_at >= action.requested_at
           AND consumption.consumed_at <= NEW.recorded_at
           AND challenge.expires_at >= NEW.recorded_at
      )
      THEN RAISE(ABORT, 'operator approval lacks its bound step-up')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_challenge_consumptions AS consumption
          JOIN moderation_operator_credential_events AS registered
            ON registered.credential_id_sha256 = consumption.credential_id_sha256
           AND registered.event_type = 'registered'
         WHERE consumption.challenge_id = NEW.approval_challenge_id
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events AS revoked
              WHERE revoked.credential_id_sha256 = consumption.credential_id_sha256
                AND revoked.event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'approval credential is not active')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_role_events AS granted
            ON granted.operator_id = NEW.operator_id
           AND granted.role_code = action.required_approver_role
           AND granted.event_type = 'granted'
         WHERE action.action_id = NEW.action_id
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_role_events AS revoked
              WHERE revoked.operator_id = granted.operator_id
                AND revoked.role_code = granted.role_code
                AND revoked.event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'approving operator role is not active')
    END);
END;

CREATE TRIGGER moderation_operator_action_approvals_are_append_only
BEFORE UPDATE ON moderation_operator_action_approvals
BEGIN SELECT RAISE(ABORT, 'operator approvals are append-only'); END;

CREATE TRIGGER moderation_operator_action_approvals_cannot_be_deleted
BEFORE DELETE ON moderation_operator_action_approvals
BEGIN SELECT RAISE(ABORT, 'operator approvals cannot be deleted'); END;
