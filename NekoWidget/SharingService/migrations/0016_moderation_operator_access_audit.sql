-- Fail-closed Access-session, WebAuthn-attempt and request-audit foundation
-- for the future isolated moderation operator Worker.
--
-- This migration adds no route, binding, runtime switch, remote side effect or
-- legacy backfill. Access JWTs and raw identity/profile fields are never
-- persisted. A challenge can only be issued from a short-lived admitted
-- Access session, and a WebAuthn assertion is burned before verification so a
-- failed assertion cannot be retried. Existing pre-migration challenges and
-- actions cannot be advanced into a new side effect because they have no
-- matching attempt/session chain.

CREATE TABLE moderation_operator_access_sessions (
    access_session_sha256 TEXT PRIMARY KEY CHECK (
      length(access_session_sha256) = 64
      AND length(CAST(access_session_sha256 AS BLOB)) = 64
      AND access_session_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    access_subject_hmac_key_version INTEGER NOT NULL CHECK (
      access_subject_hmac_key_version BETWEEN 1 AND 2147483647
    ),
    access_subject_hmac TEXT NOT NULL CHECK (
      length(access_subject_hmac) = 64
      AND length(CAST(access_subject_hmac AS BLOB)) = 64
      AND access_subject_hmac NOT GLOB '*[^0-9a-f]*'
    ),
    token_issued_at INTEGER NOT NULL,
    token_expires_at INTEGER NOT NULL,
    admitted_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (operator_id, access_subject_hmac_key_version)
      REFERENCES moderation_operator_subject_identities(
        operator_id, access_subject_hmac_key_version
      ) ON DELETE RESTRICT,
    FOREIGN KEY (access_subject_hmac_key_version, access_subject_hmac)
      REFERENCES moderation_operator_subject_identities(
        access_subject_hmac_key_version, access_subject_hmac
      ) ON DELETE RESTRICT,
    CHECK (
      token_issued_at <= admitted_at
      AND token_expires_at > token_issued_at
      AND token_expires_at <= token_issued_at + 900
      AND token_expires_at > admitted_at
    )
) STRICT;

CREATE INDEX moderation_operator_access_sessions_operator_expiry
    ON moderation_operator_access_sessions(
      operator_id, token_expires_at, access_session_sha256
    );

CREATE INDEX moderation_operator_access_sessions_operator_admission
    ON moderation_operator_access_sessions(
      operator_id, admitted_at, access_session_sha256
    );

-- Supports the rolling challenge-issuance quota below. The older
-- (operator_id, expires_at) index cannot efficiently serve issued_at ranges.
CREATE INDEX moderation_operator_challenges_operator_issued_at
    ON moderation_operator_challenges(
      operator_id, issued_at, challenge_id
    );

CREATE TRIGGER moderation_operator_access_sessions_validate
BEFORE INSERT ON moderation_operator_access_sessions
BEGIN
    SELECT (CASE
      WHEN NEW.admitted_at <> unixepoch()
      THEN RAISE(ABORT, 'access session must use database admission time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_access_sessions
         WHERE access_session_sha256 = NEW.access_session_sha256
      )
      THEN RAISE(ABORT, 'access session cannot be replayed or replaced')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_subject_identities AS identity
         WHERE identity.operator_id = NEW.operator_id
           AND identity.access_subject_hmac_key_version =
               NEW.access_subject_hmac_key_version
           AND identity.access_subject_hmac = NEW.access_subject_hmac
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = identity.operator_id
                AND newer.access_subject_hmac_key_version >
                    identity.access_subject_hmac_key_version
           )
      )
      THEN RAISE(ABORT, 'access session alias is not current')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'activated'
      ) OR EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
      )
      THEN RAISE(ABORT, 'access session operator is not active')
      WHEN (
        SELECT COUNT(*)
          FROM moderation_operator_access_sessions AS session
         WHERE session.operator_id = NEW.operator_id
           AND session.token_expires_at > NEW.admitted_at
      ) >= 4
      THEN RAISE(ABORT, 'operator has too many live access sessions')
      WHEN (
        SELECT COUNT(*)
          FROM moderation_operator_access_sessions AS session
         WHERE session.operator_id = NEW.operator_id
           AND session.admitted_at > NEW.admitted_at - 3600
      ) >= 12
      THEN RAISE(ABORT, 'operator access session admission rate exceeded')
    END);
END;

CREATE TRIGGER moderation_operator_access_sessions_are_append_only
BEFORE UPDATE ON moderation_operator_access_sessions
BEGIN SELECT RAISE(ABORT, 'access sessions are append-only'); END;

CREATE TRIGGER moderation_operator_access_sessions_cannot_be_deleted
BEFORE DELETE ON moderation_operator_access_sessions
BEGIN SELECT RAISE(ABORT, 'access sessions cannot be deleted'); END;

-- These two marker tables are deliberately not backfilled. They distinguish
-- a challenge/reservation inserted under this migration's live-session guards
-- from an indistinguishable legacy row created before those guards existed.
CREATE TABLE moderation_operator_access_migration_fence (
    migration_version INTEGER PRIMARY KEY CHECK (migration_version = 16),
    challenge_rowid_high_water INTEGER NOT NULL CHECK (
      challenge_rowid_high_water >= 0
    ),
    reservation_rowid_high_water INTEGER NOT NULL CHECK (
      reservation_rowid_high_water >= 0
    ),
    installed_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

INSERT INTO moderation_operator_access_migration_fence(
  migration_version, challenge_rowid_high_water,
  reservation_rowid_high_water, installed_at
)
SELECT
  16,
  COALESCE((SELECT MAX(rowid) FROM moderation_operator_challenges), 0),
  COALESCE((SELECT MAX(rowid) FROM moderation_case_reservations), 0),
  unixepoch();

CREATE TRIGGER moderation_operator_access_migration_fence_is_immutable
BEFORE UPDATE ON moderation_operator_access_migration_fence
BEGIN SELECT RAISE(ABORT, 'operator access migration fence is immutable'); END;

CREATE TRIGGER moderation_operator_access_migration_fence_cannot_be_deleted
BEFORE DELETE ON moderation_operator_access_migration_fence
BEGIN SELECT RAISE(ABORT, 'operator access migration fence cannot be deleted'); END;

CREATE TRIGGER moderation_operator_access_migration_fence_cannot_be_inserted
BEFORE INSERT ON moderation_operator_access_migration_fence
BEGIN SELECT RAISE(ABORT, 'operator access migration fence already exists'); END;

CREATE TABLE moderation_operator_challenge_access_links (
    challenge_id TEXT PRIMARY KEY
        REFERENCES moderation_operator_challenges(challenge_id)
        ON DELETE RESTRICT,
    access_session_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_access_sessions(access_session_sha256)
        ON DELETE RESTRICT,
    linked_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE TABLE moderation_case_reservation_access_links (
    reservation_id TEXT PRIMARY KEY
        REFERENCES moderation_case_reservations(reservation_id)
        ON DELETE RESTRICT,
    access_session_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_access_sessions(access_session_sha256)
        ON DELETE RESTRICT,
    linked_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE TABLE moderation_operator_assertion_attempts (
    challenge_id TEXT PRIMARY KEY
        REFERENCES moderation_operator_challenges(challenge_id)
        ON DELETE RESTRICT,
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    access_session_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_access_sessions(access_session_sha256)
        ON DELETE RESTRICT,
    credential_id_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_credentials(credential_id_sha256)
        ON DELETE RESTRICT,
    assertion_sha256 TEXT NOT NULL UNIQUE CHECK (
      length(assertion_sha256) = 64
      AND length(CAST(assertion_sha256 AS BLOB)) = 64
      AND assertion_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    attempted_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE INDEX moderation_operator_assertion_attempts_operator_time
    ON moderation_operator_assertion_attempts(
      operator_id, attempted_at, challenge_id
    );

CREATE TABLE moderation_operator_access_audit_starts (
    audit_request_id TEXT PRIMARY KEY CHECK (
      length(audit_request_id) = 36
      AND length(CAST(audit_request_id AS BLOB)) = 36
      AND lower(audit_request_id) = audit_request_id
      AND substr(audit_request_id, 9, 1) = '-'
      AND substr(audit_request_id, 14, 1) = '-'
      AND substr(audit_request_id, 15, 1) = '4'
      AND substr(audit_request_id, 19, 1) = '-'
      AND substr(audit_request_id, 20, 1) GLOB '[89ab]'
      AND substr(audit_request_id, 24, 1) = '-'
      AND length(replace(audit_request_id, '-', '')) = 32
      AND audit_request_id NOT GLOB '*[^0-9a-f-]*'
    ),
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    access_session_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_access_sessions(access_session_sha256)
        ON DELETE RESTRICT,
    operation_code TEXT NOT NULL CHECK (
      operation_code IN (
        'session_admit',
        'case_read',
        'case_reserve',
        'challenge_issue',
        'assertion_verify',
        'review_start',
        'evidence_export',
        'review_decision',
        'content_delete'
      )
    ),
    request_sha256 TEXT NOT NULL CHECK (
      length(request_sha256) = 64
      AND length(CAST(request_sha256 AS BLOB)) = 64
      AND request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    case_reference_hmac TEXT
        REFERENCES moderation_operator_case_references(case_reference_hmac)
        ON DELETE RESTRICT,
    started_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE INDEX moderation_operator_access_audit_starts_session_time
    ON moderation_operator_access_audit_starts(
      access_session_sha256, started_at, audit_request_id
    );

CREATE INDEX moderation_operator_access_audit_starts_operator_time
    ON moderation_operator_access_audit_starts(
      operator_id, started_at, audit_request_id
    );

CREATE TABLE moderation_operator_access_audit_finishes (
    audit_request_id TEXT PRIMARY KEY
        REFERENCES moderation_operator_access_audit_starts(audit_request_id)
        ON DELETE RESTRICT,
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    access_session_sha256 TEXT NOT NULL
        REFERENCES moderation_operator_access_sessions(access_session_sha256)
        ON DELETE RESTRICT,
    operation_code TEXT NOT NULL CHECK (
      operation_code IN (
        'session_admit',
        'case_read',
        'case_reserve',
        'challenge_issue',
        'assertion_verify',
        'review_start',
        'evidence_export',
        'review_decision',
        'content_delete'
      )
    ),
    request_sha256 TEXT NOT NULL CHECK (
      length(request_sha256) = 64
      AND length(CAST(request_sha256 AS BLOB)) = 64
      AND request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    case_reference_hmac TEXT
        REFERENCES moderation_operator_case_references(case_reference_hmac)
        ON DELETE RESTRICT,
    outcome_code TEXT NOT NULL CHECK (
      outcome_code IN (
        'succeeded',
        'rejected_invalid',
        'rejected_forbidden',
        'rejected_not_found',
        'rejected_conflict',
        'rejected_expired',
        'rejected_replay',
        'rejected_quota',
        'failed_dependency',
        'failed_internal'
      )
    ),
    status_code INTEGER NOT NULL CHECK (status_code BETWEEN 100 AND 599),
    finished_at INTEGER NOT NULL DEFAULT (unixepoch()),
    CHECK (
      (outcome_code = 'succeeded' AND status_code BETWEEN 200 AND 299)
      OR (
        outcome_code IN (
          'rejected_invalid', 'rejected_forbidden', 'rejected_not_found',
          'rejected_conflict', 'rejected_expired', 'rejected_replay',
          'rejected_quota'
        )
        AND status_code BETWEEN 400 AND 499
      )
      OR (
        outcome_code IN ('failed_dependency', 'failed_internal')
        AND status_code BETWEEN 500 AND 599
      )
    )
) STRICT;

CREATE TRIGGER moderation_operator_new_challenges_require_access_session
BEFORE INSERT ON moderation_operator_challenges
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_access_sessions AS session
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = session.operator_id
           AND identity.access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND identity.access_subject_hmac = session.access_subject_hmac
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 = NEW.credential_id_sha256
           AND credential.operator_id = session.operator_id
         WHERE session.access_session_sha256 = NEW.access_session_sha256
           AND session.operator_id = NEW.operator_id
           AND session.access_subject_hmac_key_version =
               NEW.access_subject_hmac_key_version
           AND session.admitted_at <= NEW.issued_at
           AND session.token_expires_at > NEW.issued_at
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = identity.operator_id
                AND newer.access_subject_hmac_key_version >
                    identity.access_subject_hmac_key_version
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = NEW.credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = NEW.credential_id_sha256
                AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'operator challenge requires a live access session')
      WHEN (
        SELECT COUNT(*)
          FROM moderation_operator_challenges AS challenge
         WHERE challenge.operator_id = NEW.operator_id
           AND challenge.issued_at > NEW.issued_at - 300
      ) >= 12
      THEN RAISE(ABORT, 'operator challenge issue rate exceeded')
    END);
END;

CREATE TRIGGER moderation_operator_new_challenges_record_access_session
AFTER INSERT ON moderation_operator_challenges
BEGIN
    INSERT INTO moderation_operator_challenge_access_links(
      challenge_id, access_session_sha256, linked_at
    ) VALUES (NEW.challenge_id, NEW.access_session_sha256, unixepoch());
END;

CREATE TRIGGER moderation_operator_challenge_access_links_validate
BEFORE INSERT ON moderation_operator_challenge_access_links
BEGIN
    SELECT (CASE
      WHEN NEW.linked_at <> unixepoch()
      THEN RAISE(ABORT, 'challenge access link must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_challenge_access_links
         WHERE challenge_id = NEW.challenge_id
      )
      THEN RAISE(ABORT, 'challenge access link cannot be replaced')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_challenges
        JOIN moderation_operator_access_migration_fence AS fence
          ON fence.migration_version = 16
         WHERE moderation_operator_challenges.challenge_id = NEW.challenge_id
           AND moderation_operator_challenges.access_session_sha256 =
               NEW.access_session_sha256
           AND moderation_operator_challenges.issued_at = NEW.linked_at
           AND moderation_operator_challenges.rowid >
               fence.challenge_rowid_high_water
      )
      THEN RAISE(ABORT, 'challenge access link does not match a new challenge')
    END);
END;

CREATE TRIGGER moderation_operator_challenge_access_links_are_append_only
BEFORE UPDATE ON moderation_operator_challenge_access_links
BEGIN SELECT RAISE(ABORT, 'challenge access links are append-only'); END;

CREATE TRIGGER moderation_operator_challenge_access_links_cannot_be_deleted
BEFORE DELETE ON moderation_operator_challenge_access_links
BEGIN SELECT RAISE(ABORT, 'challenge access links cannot be deleted'); END;

CREATE TRIGGER moderation_operator_new_reservations_require_access_session
BEFORE INSERT ON moderation_case_reservations
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_access_sessions AS session
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = session.operator_id
           AND identity.access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND identity.access_subject_hmac = session.access_subject_hmac
         WHERE session.access_session_sha256 = NEW.access_session_sha256
           AND session.operator_id = NEW.operator_id
           AND session.access_subject_hmac_key_version =
               NEW.access_subject_hmac_key_version
           AND session.admitted_at <= NEW.reserved_at
           AND session.token_expires_at > NEW.reserved_at
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = identity.operator_id
                AND newer.access_subject_hmac_key_version >
                    identity.access_subject_hmac_key_version
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
      THEN RAISE(ABORT, 'case reservation requires a live access session')
    END);
END;

CREATE TRIGGER moderation_operator_new_reservations_record_access_session
AFTER INSERT ON moderation_case_reservations
BEGIN
    INSERT INTO moderation_case_reservation_access_links(
      reservation_id, access_session_sha256, linked_at
    ) VALUES (NEW.reservation_id, NEW.access_session_sha256, unixepoch());
END;

CREATE TRIGGER moderation_case_reservation_access_links_validate
BEFORE INSERT ON moderation_case_reservation_access_links
BEGIN
    SELECT (CASE
      WHEN NEW.linked_at <> unixepoch()
      THEN RAISE(ABORT, 'reservation access link must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_case_reservation_access_links
         WHERE reservation_id = NEW.reservation_id
      )
      THEN RAISE(ABORT, 'reservation access link cannot be replaced')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_case_reservations
        JOIN moderation_operator_access_migration_fence AS fence
          ON fence.migration_version = 16
         WHERE moderation_case_reservations.reservation_id = NEW.reservation_id
           AND moderation_case_reservations.access_session_sha256 =
               NEW.access_session_sha256
           AND moderation_case_reservations.reserved_at = NEW.linked_at
           AND moderation_case_reservations.rowid >
               fence.reservation_rowid_high_water
      )
      THEN RAISE(ABORT, 'reservation access link does not match a new reservation')
    END);
END;

CREATE TRIGGER moderation_case_reservation_access_links_are_append_only
BEFORE UPDATE ON moderation_case_reservation_access_links
BEGIN SELECT RAISE(ABORT, 'reservation access links are append-only'); END;

CREATE TRIGGER moderation_case_reservation_access_links_cannot_be_deleted
BEFORE DELETE ON moderation_case_reservation_access_links
BEGIN SELECT RAISE(ABORT, 'reservation access links cannot be deleted'); END;

CREATE TRIGGER moderation_operator_assertion_attempts_validate
BEFORE INSERT ON moderation_operator_assertion_attempts
BEGIN
    SELECT (CASE
      WHEN NEW.attempted_at <> unixepoch()
      THEN RAISE(ABORT, 'assertion attempt must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_assertion_attempts
         WHERE challenge_id = NEW.challenge_id
            OR assertion_sha256 = NEW.assertion_sha256
      )
      THEN RAISE(ABORT, 'assertion attempt cannot be replayed')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_challenge_consumptions
         WHERE challenge_id = NEW.challenge_id
      )
      THEN RAISE(ABORT, 'assertion attempt must precede verification')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_challenges AS challenge
          JOIN moderation_operator_challenge_access_links AS access_link
            ON access_link.challenge_id = challenge.challenge_id
          JOIN moderation_operator_access_sessions AS session
            ON session.access_session_sha256 = challenge.access_session_sha256
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = session.operator_id
           AND identity.access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND identity.access_subject_hmac = session.access_subject_hmac
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 = challenge.credential_id_sha256
         WHERE challenge.challenge_id = NEW.challenge_id
           AND challenge.operator_id = NEW.operator_id
           AND challenge.access_session_sha256 = NEW.access_session_sha256
           AND access_link.access_session_sha256 = NEW.access_session_sha256
           AND challenge.credential_id_sha256 = NEW.credential_id_sha256
           AND challenge.issued_at <= NEW.attempted_at
           AND challenge.expires_at > NEW.attempted_at
           AND session.operator_id = NEW.operator_id
           AND session.access_subject_hmac_key_version =
               challenge.access_subject_hmac_key_version
           AND session.admitted_at <= NEW.attempted_at
           AND session.token_expires_at > NEW.attempted_at
           AND credential.operator_id = NEW.operator_id
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = NEW.credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = NEW.credential_id_sha256
                AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
           )
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = identity.operator_id
                AND newer.access_subject_hmac_key_version >
                    identity.access_subject_hmac_key_version
           )
      )
      THEN RAISE(ABORT, 'assertion attempt is not bound to a live challenge')
    END);
END;

CREATE TRIGGER moderation_operator_assertion_attempts_are_append_only
BEFORE UPDATE ON moderation_operator_assertion_attempts
BEGIN SELECT RAISE(ABORT, 'assertion attempts are append-only'); END;

CREATE TRIGGER moderation_operator_assertion_attempts_cannot_be_deleted
BEFORE DELETE ON moderation_operator_assertion_attempts
BEGIN SELECT RAISE(ABORT, 'assertion attempts cannot be deleted'); END;

CREATE TRIGGER moderation_operator_new_consumptions_require_attempt
BEFORE INSERT ON moderation_operator_challenge_consumptions
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_assertion_attempts AS attempt
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = attempt.challenge_id
          JOIN moderation_operator_access_sessions AS session
            ON session.access_session_sha256 = attempt.access_session_sha256
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = session.operator_id
           AND identity.access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND identity.access_subject_hmac = session.access_subject_hmac
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 = attempt.credential_id_sha256
           AND credential.operator_id = attempt.operator_id
         WHERE attempt.challenge_id = NEW.challenge_id
           AND attempt.operator_id = NEW.operator_id
           AND attempt.credential_id_sha256 = NEW.credential_id_sha256
           AND attempt.assertion_sha256 = NEW.verified_assertion_sha256
           AND attempt.attempted_at <= NEW.consumed_at
           AND challenge.operator_id = NEW.operator_id
           AND challenge.credential_id_sha256 = NEW.credential_id_sha256
           AND challenge.access_session_sha256 =
               attempt.access_session_sha256
           AND challenge.expires_at > NEW.consumed_at
           AND session.operator_id = NEW.operator_id
           AND session.access_subject_hmac_key_version =
               challenge.access_subject_hmac_key_version
           AND session.token_expires_at > NEW.consumed_at
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = identity.operator_id
                AND newer.access_subject_hmac_key_version >
                    identity.access_subject_hmac_key_version
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = attempt.credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = attempt.credential_id_sha256
                AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'challenge consumption lacks its exact assertion attempt')
    END);
END;

CREATE TRIGGER moderation_operator_new_actions_require_session_attempt
BEFORE INSERT ON moderation_operator_actions
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_challenge_consumptions AS consumption
          JOIN moderation_operator_assertion_attempts AS attempt
            ON attempt.challenge_id = consumption.challenge_id
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = consumption.challenge_id
          JOIN moderation_operator_access_sessions AS session
            ON session.access_session_sha256 = attempt.access_session_sha256
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = session.operator_id
           AND identity.access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND identity.access_subject_hmac = session.access_subject_hmac
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 = attempt.credential_id_sha256
           AND credential.operator_id = attempt.operator_id
         WHERE consumption.challenge_id = NEW.request_challenge_id
           AND consumption.operator_id = NEW.requester_operator_id
           AND consumption.verified_assertion_sha256 = attempt.assertion_sha256
           AND attempt.operator_id = NEW.requester_operator_id
           AND attempt.credential_id_sha256 = consumption.credential_id_sha256
           AND challenge.access_session_sha256 = attempt.access_session_sha256
           AND session.operator_id = NEW.requester_operator_id
           AND session.access_subject_hmac_key_version =
               challenge.access_subject_hmac_key_version
           AND session.token_expires_at > NEW.requested_at
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = identity.operator_id
                AND newer.access_subject_hmac_key_version >
                    identity.access_subject_hmac_key_version
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.requester_operator_id
                AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.requester_operator_id
                AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = attempt.credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = attempt.credential_id_sha256
                AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'operator action lacks an admitted assertion attempt')
      WHEN NEW.expires_at > (
        SELECT session.token_expires_at
          FROM moderation_operator_challenges AS challenge
          JOIN moderation_operator_access_sessions AS session
            ON session.access_session_sha256 = challenge.access_session_sha256
         WHERE challenge.challenge_id = NEW.request_challenge_id
      )
      THEN RAISE(ABORT, 'operator action exceeds access session lifetime')
      WHEN NEW.action_type = 'review_start' AND NOT EXISTS (
        SELECT 1
          FROM moderation_case_reservations AS reservation
          JOIN moderation_case_reservation_access_links AS access_link
            ON access_link.reservation_id = reservation.reservation_id
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = NEW.request_challenge_id
         WHERE reservation.case_reference_hmac = NEW.case_reference_hmac
           AND reservation.operator_id = NEW.requester_operator_id
           AND reservation.access_session_sha256 =
               challenge.access_session_sha256
           AND access_link.access_session_sha256 =
               reservation.access_session_sha256
           AND reservation.reserved_at <= NEW.requested_at
           AND reservation.expires_at >= NEW.requested_at
           AND NOT EXISTS (
             SELECT 1 FROM moderation_case_reservation_consumptions
              WHERE reservation_id = reservation.reservation_id
           )
      )
      THEN RAISE(ABORT, 'review action lacks a session-bound reservation')
    END);
END;

CREATE TRIGGER moderation_operator_new_approvals_require_session_attempt
BEFORE INSERT ON moderation_operator_action_approvals
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_challenge_consumptions AS consumption
          JOIN moderation_operator_assertion_attempts AS attempt
            ON attempt.challenge_id = consumption.challenge_id
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = consumption.challenge_id
          JOIN moderation_operator_access_sessions AS session
            ON session.access_session_sha256 = attempt.access_session_sha256
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = session.operator_id
           AND identity.access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND identity.access_subject_hmac = session.access_subject_hmac
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 = attempt.credential_id_sha256
           AND credential.operator_id = attempt.operator_id
         WHERE consumption.challenge_id = NEW.approval_challenge_id
           AND consumption.operator_id = NEW.operator_id
           AND consumption.verified_assertion_sha256 = attempt.assertion_sha256
           AND attempt.operator_id = NEW.operator_id
           AND attempt.credential_id_sha256 = consumption.credential_id_sha256
           AND challenge.access_session_sha256 = attempt.access_session_sha256
           AND session.operator_id = NEW.operator_id
           AND session.access_subject_hmac_key_version =
               challenge.access_subject_hmac_key_version
           AND session.token_expires_at > NEW.recorded_at
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = identity.operator_id
                AND newer.access_subject_hmac_key_version >
                    identity.access_subject_hmac_key_version
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = attempt.credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = attempt.credential_id_sha256
                AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'operator approval lacks an admitted assertion attempt')
    END);
END;

-- These guards are intentionally not an audit/domain atomicity claim. They
-- only ensure new evidence cannot be materialized from a pre-migration action
-- or approval that lacks the admitted-session and burned-attempt chain.
CREATE TRIGGER moderation_operator_new_evidence_intents_require_attempts
BEFORE INSERT ON moderation_evidence_event_intents
WHEN NEW.legacy_backfill = 0
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_challenge_consumptions AS consumption
            ON consumption.challenge_id = action.request_challenge_id
          JOIN moderation_operator_assertion_attempts AS attempt
            ON attempt.challenge_id = consumption.challenge_id
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = consumption.challenge_id
          JOIN moderation_operator_access_sessions AS session
            ON session.access_session_sha256 = attempt.access_session_sha256
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = session.operator_id
           AND identity.access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND identity.access_subject_hmac = session.access_subject_hmac
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 = attempt.credential_id_sha256
           AND credential.operator_id = attempt.operator_id
         WHERE action.action_id = NEW.action_id
           AND consumption.verified_assertion_sha256 = attempt.assertion_sha256
           AND attempt.operator_id = action.requester_operator_id
           AND attempt.credential_id_sha256 = consumption.credential_id_sha256
           AND challenge.access_session_sha256 = attempt.access_session_sha256
           AND session.operator_id = action.requester_operator_id
           AND session.access_subject_hmac_key_version =
               challenge.access_subject_hmac_key_version
           AND session.token_expires_at > NEW.occurred_at
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = identity.operator_id
                AND newer.access_subject_hmac_key_version >
                    identity.access_subject_hmac_key_version
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = action.requester_operator_id
                AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = action.requester_operator_id
                AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = attempt.credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = attempt.credential_id_sha256
                AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'evidence intent lacks an admitted request attempt')
      WHEN EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_action_approvals AS approval
            ON approval.action_id = action.action_id
         WHERE action.action_id = NEW.action_id
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_challenge_consumptions AS consumption
               JOIN moderation_operator_assertion_attempts AS attempt
                 ON attempt.challenge_id = consumption.challenge_id
               JOIN moderation_operator_challenges AS challenge
                 ON challenge.challenge_id = consumption.challenge_id
               JOIN moderation_operator_access_sessions AS session
                 ON session.access_session_sha256 = attempt.access_session_sha256
               JOIN moderation_operator_subject_identities AS identity
                 ON identity.operator_id = session.operator_id
                AND identity.access_subject_hmac_key_version =
                    session.access_subject_hmac_key_version
                AND identity.access_subject_hmac = session.access_subject_hmac
               JOIN moderation_operator_credentials AS credential
                 ON credential.credential_id_sha256 =
                    attempt.credential_id_sha256
                AND credential.operator_id = attempt.operator_id
              WHERE consumption.challenge_id = approval.approval_challenge_id
                AND consumption.operator_id = approval.operator_id
                AND consumption.verified_assertion_sha256 =
                    attempt.assertion_sha256
                AND attempt.operator_id = approval.operator_id
                AND attempt.credential_id_sha256 =
                    consumption.credential_id_sha256
                AND challenge.access_session_sha256 =
                    attempt.access_session_sha256
                AND session.operator_id = approval.operator_id
                AND session.access_subject_hmac_key_version =
                    challenge.access_subject_hmac_key_version
                AND session.token_expires_at > NEW.occurred_at
                AND NOT EXISTS (
                  SELECT 1
                    FROM moderation_operator_subject_identities AS newer
                   WHERE newer.operator_id = identity.operator_id
                     AND newer.access_subject_hmac_key_version >
                         identity.access_subject_hmac_key_version
                )
                AND EXISTS (
                  SELECT 1 FROM moderation_operator_state_events
                   WHERE operator_id = approval.operator_id
                     AND event_type = 'activated'
                )
                AND NOT EXISTS (
                  SELECT 1 FROM moderation_operator_state_events
                   WHERE operator_id = approval.operator_id
                     AND event_type = 'revoked'
                )
                AND EXISTS (
                  SELECT 1 FROM moderation_operator_credential_events
                   WHERE credential_id_sha256 = attempt.credential_id_sha256
                     AND event_type = 'registered'
                )
                AND NOT EXISTS (
                  SELECT 1 FROM moderation_operator_credential_events
                   WHERE credential_id_sha256 = attempt.credential_id_sha256
                     AND event_type = 'revoked'
                )
           )
      )
      THEN RAISE(ABORT, 'evidence intent has an unauditable approval attempt')
    END);
END;

CREATE TRIGGER moderation_operator_new_ledger_events_require_attempts
BEFORE INSERT ON moderation_evidence_ledger_events
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_challenge_consumptions AS consumption
            ON consumption.challenge_id = action.request_challenge_id
          JOIN moderation_operator_assertion_attempts AS attempt
            ON attempt.challenge_id = consumption.challenge_id
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = consumption.challenge_id
          JOIN moderation_operator_access_sessions AS session
            ON session.access_session_sha256 = attempt.access_session_sha256
         WHERE action.action_id = NEW.action_id
           AND consumption.verified_assertion_sha256 = attempt.assertion_sha256
           AND attempt.operator_id = action.requester_operator_id
           AND challenge.access_session_sha256 = attempt.access_session_sha256
           AND session.operator_id = action.requester_operator_id
           AND session.access_subject_hmac_key_version =
               challenge.access_subject_hmac_key_version
      )
      THEN RAISE(ABORT, 'evidence event lacks an admitted request attempt')
    END);
END;

CREATE TRIGGER moderation_operator_new_exports_require_attempts
BEFORE INSERT ON moderation_evidence_exports
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_challenge_consumptions AS consumption
            ON consumption.challenge_id = action.request_challenge_id
          JOIN moderation_operator_assertion_attempts AS attempt
            ON attempt.challenge_id = consumption.challenge_id
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = consumption.challenge_id
          JOIN moderation_operator_access_sessions AS session
            ON session.access_session_sha256 = attempt.access_session_sha256
          JOIN moderation_operator_subject_identities AS identity
            ON identity.operator_id = session.operator_id
           AND identity.access_subject_hmac_key_version =
               session.access_subject_hmac_key_version
           AND identity.access_subject_hmac = session.access_subject_hmac
          JOIN moderation_operator_credentials AS credential
            ON credential.credential_id_sha256 = attempt.credential_id_sha256
           AND credential.operator_id = attempt.operator_id
         WHERE action.action_id = NEW.action_id
           AND consumption.verified_assertion_sha256 = attempt.assertion_sha256
           AND attempt.operator_id = action.requester_operator_id
           AND attempt.credential_id_sha256 = consumption.credential_id_sha256
           AND challenge.access_session_sha256 = attempt.access_session_sha256
           AND session.operator_id = action.requester_operator_id
           AND session.access_subject_hmac_key_version =
               challenge.access_subject_hmac_key_version
           AND session.token_expires_at > NEW.generated_at
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = identity.operator_id
                AND newer.access_subject_hmac_key_version >
                    identity.access_subject_hmac_key_version
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = action.requester_operator_id
                AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = action.requester_operator_id
                AND event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = attempt.credential_id_sha256
                AND event_type = 'registered'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events
              WHERE credential_id_sha256 = attempt.credential_id_sha256
                AND event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'evidence export lacks an admitted request attempt')
      WHEN EXISTS (
        SELECT 1
          FROM moderation_operator_action_approvals AS approval
         WHERE approval.action_id = NEW.action_id
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_challenge_consumptions AS consumption
               JOIN moderation_operator_assertion_attempts AS attempt
                 ON attempt.challenge_id = consumption.challenge_id
               JOIN moderation_operator_challenges AS challenge
                 ON challenge.challenge_id = consumption.challenge_id
               JOIN moderation_operator_access_sessions AS session
                 ON session.access_session_sha256 = attempt.access_session_sha256
               JOIN moderation_operator_subject_identities AS identity
                 ON identity.operator_id = session.operator_id
                AND identity.access_subject_hmac_key_version =
                    session.access_subject_hmac_key_version
                AND identity.access_subject_hmac = session.access_subject_hmac
               JOIN moderation_operator_credentials AS credential
                 ON credential.credential_id_sha256 =
                    attempt.credential_id_sha256
                AND credential.operator_id = attempt.operator_id
              WHERE consumption.challenge_id = approval.approval_challenge_id
                AND consumption.operator_id = approval.operator_id
                AND consumption.verified_assertion_sha256 =
                    attempt.assertion_sha256
                AND attempt.operator_id = approval.operator_id
                AND attempt.credential_id_sha256 =
                    consumption.credential_id_sha256
                AND challenge.access_session_sha256 =
                    attempt.access_session_sha256
                AND session.operator_id = approval.operator_id
                AND session.access_subject_hmac_key_version =
                    challenge.access_subject_hmac_key_version
                AND session.token_expires_at > NEW.generated_at
                AND NOT EXISTS (
                  SELECT 1
                    FROM moderation_operator_subject_identities AS newer
                   WHERE newer.operator_id = identity.operator_id
                     AND newer.access_subject_hmac_key_version >
                         identity.access_subject_hmac_key_version
                )
                AND EXISTS (
                  SELECT 1 FROM moderation_operator_state_events
                   WHERE operator_id = approval.operator_id
                     AND event_type = 'activated'
                )
                AND NOT EXISTS (
                  SELECT 1 FROM moderation_operator_state_events
                   WHERE operator_id = approval.operator_id
                     AND event_type = 'revoked'
                )
                AND EXISTS (
                  SELECT 1 FROM moderation_operator_credential_events
                   WHERE credential_id_sha256 = attempt.credential_id_sha256
                     AND event_type = 'registered'
                )
                AND NOT EXISTS (
                  SELECT 1 FROM moderation_operator_credential_events
                   WHERE credential_id_sha256 = attempt.credential_id_sha256
                     AND event_type = 'revoked'
                )
           )
      )
      THEN RAISE(ABORT, 'evidence export has an unauditable approval attempt')
    END);
END;

CREATE TRIGGER moderation_operator_access_audit_starts_validate
BEFORE INSERT ON moderation_operator_access_audit_starts
BEGIN
    SELECT (CASE
      WHEN NEW.started_at <> unixepoch()
      THEN RAISE(ABORT, 'access audit start must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_access_audit_starts
         WHERE audit_request_id = NEW.audit_request_id
      )
      THEN RAISE(ABORT, 'access audit request cannot be replayed')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_access_sessions AS session
         WHERE session.access_session_sha256 = NEW.access_session_sha256
           AND session.operator_id = NEW.operator_id
           AND session.admitted_at <= NEW.started_at
           AND session.token_expires_at > NEW.started_at
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events
              WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
           )
           AND NOT EXISTS (
             SELECT 1
               FROM moderation_operator_subject_identities AS newer
              WHERE newer.operator_id = NEW.operator_id
                AND newer.access_subject_hmac_key_version >
                    session.access_subject_hmac_key_version
           )
      )
      THEN RAISE(ABORT, 'access audit request requires a live access session')
      WHEN (
        SELECT COUNT(*)
          FROM moderation_operator_access_audit_starts AS audit
         WHERE audit.access_session_sha256 = NEW.access_session_sha256
           AND audit.started_at > NEW.started_at - 60
      ) >= 30
      THEN RAISE(ABORT, 'access audit session request rate exceeded')
      WHEN (
        SELECT COUNT(*)
          FROM moderation_operator_access_audit_starts AS audit
         WHERE audit.operator_id = NEW.operator_id
           AND audit.started_at > NEW.started_at - 60
      ) >= 60
      THEN RAISE(ABORT, 'access audit operator request rate exceeded')
    END);
END;

CREATE TRIGGER moderation_operator_access_audit_starts_are_append_only
BEFORE UPDATE ON moderation_operator_access_audit_starts
BEGIN SELECT RAISE(ABORT, 'access audit starts are append-only'); END;

CREATE TRIGGER moderation_operator_access_audit_starts_cannot_be_deleted
BEFORE DELETE ON moderation_operator_access_audit_starts
BEGIN SELECT RAISE(ABORT, 'access audit starts cannot be deleted'); END;

CREATE TRIGGER moderation_operator_access_audit_finishes_validate
BEFORE INSERT ON moderation_operator_access_audit_finishes
BEGIN
    SELECT (CASE
      WHEN NEW.finished_at <> unixepoch()
      THEN RAISE(ABORT, 'access audit finish must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_access_audit_finishes
         WHERE audit_request_id = NEW.audit_request_id
      )
      THEN RAISE(ABORT, 'access audit request is already finished')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_access_audit_starts AS started
         WHERE started.audit_request_id = NEW.audit_request_id
           AND started.operator_id = NEW.operator_id
           AND started.access_session_sha256 = NEW.access_session_sha256
           AND started.operation_code = NEW.operation_code
           AND started.request_sha256 = NEW.request_sha256
           AND started.case_reference_hmac IS NEW.case_reference_hmac
           AND started.started_at <= NEW.finished_at
      )
      THEN RAISE(ABORT, 'access audit finish does not exactly match its start')
    END);
END;

CREATE TRIGGER moderation_operator_access_audit_finishes_are_append_only
BEFORE UPDATE ON moderation_operator_access_audit_finishes
BEGIN SELECT RAISE(ABORT, 'access audit finishes are append-only'); END;

CREATE TRIGGER moderation_operator_access_audit_finishes_cannot_be_deleted
BEFORE DELETE ON moderation_operator_access_audit_finishes
BEGIN SELECT RAISE(ABORT, 'access audit finishes cannot be deleted'); END;
