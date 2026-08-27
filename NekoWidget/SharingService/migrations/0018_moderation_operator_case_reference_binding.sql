-- Version-bound moderation case references.
--
-- This migration adds no route, secret, binding, runtime switch, deployment or
-- backfill. Existing moderation_operator_case_references rows remain available
-- for forensic compatibility but are not trusted for new operator work. New
-- references are created only through the authoritative table below; its AFTER
-- trigger creates the legacy compatibility row in the same SQLite statement.
-- The database records a future reviewed HMAC verifier's output. It does not
-- derive or verify HMAC-SHA-256 and must never receive the HMAC key.

CREATE TABLE moderation_operator_versioned_case_references (
    report_id TEXT PRIMARY KEY
        REFERENCES moderation_cases(report_id) ON DELETE RESTRICT CHECK (
          length(report_id) = 22
          AND length(CAST(report_id AS BLOB)) = 22
          AND report_id NOT GLOB '*[^A-Za-z0-9_-]*'
          AND substr(report_id, 22, 1) GLOB '[AQgw]'
        ),
    case_reference_hmac TEXT NOT NULL UNIQUE CHECK (
      length(case_reference_hmac) = 64
      AND length(CAST(case_reference_hmac AS BLOB)) = 64
      AND case_reference_hmac NOT GLOB '*[^0-9a-f]*'
    ),
    case_reference_hmac_key_version INTEGER NOT NULL CHECK (
      case_reference_hmac_key_version BETWEEN 1 AND 2147483647
    ),
    derivation_protocol_version INTEGER NOT NULL CHECK (
      derivation_protocol_version = 1
    ),
    derivation_domain TEXT NOT NULL CHECK (
      derivation_domain = ('NW.MODERATION-OPERATOR.C' || 'ASE-REFERENCE')
    ),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    UNIQUE (report_id, case_reference_hmac)
) STRICT;

CREATE TRIGGER moderation_operator_versioned_case_references_validate
BEFORE INSERT ON moderation_operator_versioned_case_references
BEGIN
    SELECT (CASE
      WHEN NEW.created_at <> unixepoch()
      THEN RAISE(ABORT, 'versioned case reference must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_versioned_case_references
         WHERE report_id = NEW.report_id
            OR case_reference_hmac = NEW.case_reference_hmac
      )
      THEN RAISE(ABORT, 'versioned case reference cannot be replaced')
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_case_references
         WHERE report_id = NEW.report_id
            OR case_reference_hmac = NEW.case_reference_hmac
      )
      THEN RAISE(ABORT, 'legacy case reference cannot be version-bound')
    END);
END;

CREATE TRIGGER moderation_operator_versioned_case_references_create_legacy_row
AFTER INSERT ON moderation_operator_versioned_case_references
BEGIN
    INSERT INTO moderation_operator_case_references(
      report_id, case_reference_hmac, created_at
    ) VALUES (NEW.report_id, NEW.case_reference_hmac, NEW.created_at);
END;

CREATE TRIGGER moderation_operator_case_references_require_version_binding
BEFORE INSERT ON moderation_operator_case_references
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_versioned_case_references AS reference
         WHERE reference.report_id = NEW.report_id
           AND reference.case_reference_hmac = NEW.case_reference_hmac
           AND reference.created_at = NEW.created_at
      )
      THEN RAISE(ABORT, 'case reference requires an atomic version binding')
    END);
END;

CREATE TRIGGER moderation_operator_versioned_case_references_are_immutable
BEFORE UPDATE ON moderation_operator_versioned_case_references
BEGIN SELECT RAISE(ABORT, 'versioned case references are immutable'); END;

CREATE TRIGGER moderation_operator_versioned_case_references_cannot_be_deleted
BEFORE DELETE ON moderation_operator_versioned_case_references
BEGIN SELECT RAISE(ABORT, 'versioned case references cannot be deleted'); END;

-- Every new operator chain is gated at each externally insertable boundary.
-- This prevents a chain created between migrations 0013-0017 from being
-- resumed after 0018 with a legacy, key-version-ambiguous case reference.

CREATE TRIGGER moderation_operator_challenges_require_versioned_case_reference
BEFORE INSERT ON moderation_operator_challenges
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moderation_operator_versioned_case_references
       WHERE case_reference_hmac = NEW.case_reference_hmac
    ) THEN RAISE(ABORT, 'operator challenge requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_operator_challenge_consumptions_require_versioned_case_reference
BEFORE INSERT ON moderation_operator_challenge_consumptions
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moderation_operator_challenges AS challenge
        JOIN moderation_operator_versioned_case_references AS reference
          ON reference.case_reference_hmac = challenge.case_reference_hmac
       WHERE challenge.challenge_id = NEW.challenge_id
    ) THEN RAISE(ABORT, 'challenge consumption requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_operator_assertion_attempts_require_versioned_case_reference
BEFORE INSERT ON moderation_operator_assertion_attempts
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moderation_operator_challenges AS challenge
        JOIN moderation_operator_versioned_case_references AS reference
          ON reference.case_reference_hmac = challenge.case_reference_hmac
       WHERE challenge.challenge_id = NEW.challenge_id
    ) THEN RAISE(ABORT, 'assertion attempt requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_operator_actions_require_versioned_case_reference
BEFORE INSERT ON moderation_operator_actions
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moderation_operator_versioned_case_references
       WHERE case_reference_hmac = NEW.case_reference_hmac
    ) THEN RAISE(ABORT, 'operator action requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_operator_action_approvals_require_versioned_case_reference
BEFORE INSERT ON moderation_operator_action_approvals
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moderation_operator_actions AS action
        JOIN moderation_operator_versioned_case_references AS reference
          ON reference.case_reference_hmac = action.case_reference_hmac
       WHERE action.action_id = NEW.action_id
    ) THEN RAISE(ABORT, 'action approval requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_case_reservations_require_versioned_case_reference
BEFORE INSERT ON moderation_case_reservations
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moderation_operator_versioned_case_references
       WHERE case_reference_hmac = NEW.case_reference_hmac
    ) THEN RAISE(ABORT, 'case reservation requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_case_reservation_consumptions_require_versioned_case_reference
BEFORE INSERT ON moderation_case_reservation_consumptions
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moderation_case_reservations AS reservation
        JOIN moderation_operator_versioned_case_references AS reference
          ON reference.case_reference_hmac = reservation.case_reference_hmac
       WHERE reservation.reservation_id = NEW.reservation_id
    ) THEN RAISE(ABORT, 'reservation consumption requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_evidence_event_intents_require_versioned_case_reference
BEFORE INSERT ON moderation_evidence_event_intents
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moderation_operator_versioned_case_references
       WHERE case_reference_hmac = NEW.case_reference_hmac
    ) THEN RAISE(ABORT, 'evidence intent requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_evidence_event_finalizations_require_versioned_case_reference
BEFORE INSERT ON moderation_evidence_event_finalizations
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moderation_evidence_event_intents AS intent
        JOIN moderation_operator_versioned_case_references AS reference
          ON reference.case_reference_hmac = intent.case_reference_hmac
       WHERE intent.event_id = NEW.event_id
    ) THEN RAISE(ABORT, 'evidence finalization requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_case_events_require_versioned_case_reference
BEFORE INSERT ON moderation_case_events
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moderation_operator_versioned_case_references
       WHERE report_id = NEW.report_id
    ) THEN RAISE(ABORT, 'case event requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_evidence_ledger_events_require_versioned_case_reference
BEFORE INSERT ON moderation_evidence_ledger_events
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moderation_operator_versioned_case_references
       WHERE case_reference_hmac = NEW.case_reference_hmac
    ) THEN RAISE(ABORT, 'evidence event requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_evidence_exports_require_versioned_case_reference
BEFORE INSERT ON moderation_evidence_exports
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moderation_operator_versioned_case_references
       WHERE case_reference_hmac = NEW.case_reference_hmac
    ) THEN RAISE(ABORT, 'evidence export requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_operator_case_event_links_require_versioned_case_reference
BEFORE INSERT ON moderation_operator_case_event_links
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moderation_evidence_event_intents AS intent
        JOIN moderation_operator_versioned_case_references AS reference
          ON reference.case_reference_hmac = intent.case_reference_hmac
       WHERE intent.event_id = NEW.event_id
         AND intent.action_id = NEW.action_id
    ) THEN RAISE(ABORT, 'case event link requires a versioned case reference') END);
END;

-- A rejected request is audited without a case reference. A non-NULL case
-- reference is permitted only after it has passed the versioned lookup.
CREATE TRIGGER moderation_operator_access_audit_starts_require_versioned_case_reference
BEFORE INSERT ON moderation_operator_access_audit_starts
WHEN NEW.case_reference_hmac IS NOT NULL
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moderation_operator_versioned_case_references
       WHERE case_reference_hmac = NEW.case_reference_hmac
    ) THEN RAISE(ABORT, 'access audit requires a versioned case reference') END);
END;

CREATE TRIGGER moderation_operator_access_audit_finishes_require_versioned_case_reference
BEFORE INSERT ON moderation_operator_access_audit_finishes
WHEN NEW.case_reference_hmac IS NOT NULL
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moderation_operator_versioned_case_references
       WHERE case_reference_hmac = NEW.case_reference_hmac
    ) THEN RAISE(ABORT, 'access audit finish requires a versioned case reference') END);
END;
