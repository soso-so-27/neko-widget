-- Fail-closed database foundation for a future isolated moderation operator
-- Worker. This migration adds no HTTP route, Worker binding, WebAuthn verifier,
-- R2 operation, deletion queue or runtime switch.
--
-- Reservations are not review receipts. A review starts only when a DB-timed
-- evidence intent is materialized into the append-only ledger. The ledger
-- insert, finalization receipt and case lifecycle event are one SQLite
-- statement, so a failed domain transition rolls the ledger insert back.
-- An intent expires after two minutes and only one active intent is allowed per
-- case and operator. Review decisions and deletion remain fail-closed until
-- their canonical domain evidence and outbox migrations exist.

CREATE TABLE moderation_case_reservations (
    reservation_id TEXT PRIMARY KEY CHECK (
      length(reservation_id) = 36
      AND length(CAST(reservation_id AS BLOB)) = 36
      AND lower(reservation_id) = reservation_id
      AND substr(reservation_id, 9, 1) = '-'
      AND substr(reservation_id, 14, 1) = '-'
      AND substr(reservation_id, 15, 1) = '4'
      AND substr(reservation_id, 19, 1) = '-'
      AND substr(reservation_id, 20, 1) GLOB '[89ab]'
      AND substr(reservation_id, 24, 1) = '-'
      AND length(replace(reservation_id, '-', '')) = 32
      AND reservation_id NOT GLOB '*[^0-9a-f-]*'
    ),
    case_reference_hmac TEXT NOT NULL
        REFERENCES moderation_operator_case_references(case_reference_hmac)
        ON DELETE RESTRICT,
    operator_id TEXT NOT NULL
        REFERENCES moderation_operators(operator_id) ON DELETE RESTRICT,
    access_subject_hmac_key_version INTEGER NOT NULL CHECK (
      access_subject_hmac_key_version BETWEEN 1 AND 2147483647
    ),
    access_session_sha256 TEXT NOT NULL CHECK (
      length(access_session_sha256) = 64
      AND length(CAST(access_session_sha256 AS BLOB)) = 64
      AND access_session_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    reserved_at INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at INTEGER NOT NULL,
    FOREIGN KEY (operator_id, access_subject_hmac_key_version)
      REFERENCES moderation_operator_subject_identities(
        operator_id, access_subject_hmac_key_version
      ) ON DELETE RESTRICT,
    CHECK (
      expires_at > reserved_at
      AND expires_at <= reserved_at + 300
    )
) STRICT;

CREATE INDEX moderation_case_reservations_case_expiry
    ON moderation_case_reservations(
      case_reference_hmac, expires_at, reservation_id
    );

CREATE INDEX moderation_case_reservations_operator_expiry
    ON moderation_case_reservations(
      operator_id, expires_at, reservation_id
    );

CREATE TABLE moderation_case_reservation_consumptions (
    reservation_id TEXT PRIMARY KEY
        REFERENCES moderation_case_reservations(reservation_id)
        ON DELETE RESTRICT,
    action_id TEXT NOT NULL UNIQUE
        REFERENCES moderation_operator_actions(action_id) ON DELETE RESTRICT,
    consumed_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE TABLE moderation_evidence_event_intents (
    event_id TEXT PRIMARY KEY CHECK (
      length(event_id) = 36
      AND length(CAST(event_id AS BLOB)) = 36
      AND lower(event_id) = event_id
      AND substr(event_id, 9, 1) = '-'
      AND substr(event_id, 14, 1) = '-'
      AND substr(event_id, 15, 1) = '4'
      AND substr(event_id, 19, 1) = '-'
      AND substr(event_id, 20, 1) GLOB '[89ab]'
      AND substr(event_id, 24, 1) = '-'
      AND length(replace(event_id, '-', '')) = 32
      AND event_id NOT GLOB '*[^0-9a-f-]*'
    ),
    case_reference_hmac TEXT NOT NULL
        REFERENCES moderation_operator_case_references(case_reference_hmac)
        ON DELETE RESTRICT,
    sequence INTEGER NOT NULL CHECK (sequence BETWEEN 1 AND 2147483647),
    action_id TEXT NOT NULL UNIQUE
        REFERENCES moderation_operator_actions(action_id) ON DELETE RESTRICT,
    action_type TEXT NOT NULL CHECK (
      action_type IN (
        'review_start',
        'evidence_export',
        'review_decision',
        'content_delete'
      )
    ),
    actor_subject_hmac_key_version INTEGER NOT NULL CHECK (
      actor_subject_hmac_key_version BETWEEN 1 AND 2147483647
    ),
    actor_subject_hmac TEXT NOT NULL CHECK (
      length(actor_subject_hmac) = 64
      AND length(CAST(actor_subject_hmac AS BLOB)) = 64
      AND actor_subject_hmac NOT GLOB '*[^0-9a-f]*'
    ),
    occurred_at INTEGER NOT NULL DEFAULT (unixepoch()),
    finalize_by INTEGER NOT NULL DEFAULT (unixepoch() + 120),
    previous_event_sha256 TEXT NOT NULL CHECK (
      length(previous_event_sha256) = 64
      AND length(CAST(previous_event_sha256 AS BLOB)) = 64
      AND previous_event_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    artifact_sha256 TEXT NOT NULL CHECK (
      length(artifact_sha256) = 64
      AND length(CAST(artifact_sha256 AS BLOB)) = 64
      AND artifact_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    case_outcome_code TEXT CHECK (
      case_outcome_code IS NULL OR case_outcome_code IN (
        'no_action',
        'warning',
        'block',
        'account_removal',
        'safety_or_legal_escalation'
      )
    ),
    legacy_backfill INTEGER NOT NULL DEFAULT 0 CHECK (
      legacy_backfill IN (0, 1)
    ),
    FOREIGN KEY (actor_subject_hmac_key_version, actor_subject_hmac)
      REFERENCES moderation_operator_subject_identities(
        access_subject_hmac_key_version, access_subject_hmac
      ) ON DELETE RESTRICT,
    CHECK (
      legacy_backfill = 1
      OR (action_type = 'review_decision' AND case_outcome_code IS NOT NULL)
      OR (action_type <> 'review_decision' AND case_outcome_code IS NULL)
    ),
    CHECK (
      legacy_backfill = 1
      OR (
        finalize_by = occurred_at + 120
        AND finalize_by > occurred_at
      )
    )
) STRICT;

CREATE INDEX moderation_evidence_event_intents_pending
    ON moderation_evidence_event_intents(
      case_reference_hmac, finalize_by, sequence
    );

CREATE INDEX moderation_evidence_event_intents_operator_pending
    ON moderation_evidence_event_intents(action_id, finalize_by);

CREATE TABLE moderation_evidence_event_finalizations (
    event_id TEXT PRIMARY KEY
        REFERENCES moderation_evidence_event_intents(event_id)
        ON DELETE RESTRICT,
    event_sha256 TEXT NOT NULL UNIQUE
        REFERENCES moderation_evidence_ledger_events(event_sha256)
        ON DELETE RESTRICT,
    finalized_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE TABLE moderation_operator_case_event_links (
    event_id TEXT PRIMARY KEY
        REFERENCES moderation_evidence_ledger_events(event_id)
        ON DELETE RESTRICT,
    action_id TEXT NOT NULL UNIQUE
        REFERENCES moderation_operator_actions(action_id) ON DELETE RESTRICT,
    report_id TEXT NOT NULL,
    event_type TEXT NOT NULL CHECK (
      event_type = 'review_started'
    ),
    FOREIGN KEY (report_id, event_type)
      REFERENCES moderation_case_events(report_id, event_type)
      ON DELETE RESTRICT,
    UNIQUE (report_id, event_type)
) STRICT;

-- Existing ledger entries predate DB-timed intents. Preserve them as explicit
-- legacy materializations, but never infer a case lifecycle transition or a
-- deletion side effect from them.
INSERT INTO moderation_evidence_event_intents(
  event_id, case_reference_hmac, sequence, action_id, action_type,
  actor_subject_hmac_key_version, actor_subject_hmac, occurred_at, finalize_by,
  previous_event_sha256, artifact_sha256, case_outcome_code, legacy_backfill
)
SELECT
  event_id, case_reference_hmac, sequence, action_id, action_type,
  actor_subject_hmac_key_version, actor_subject_hmac, occurred_at, occurred_at,
  previous_event_sha256, artifact_sha256, NULL, 1
FROM moderation_evidence_ledger_events;

INSERT INTO moderation_evidence_event_finalizations(
  event_id, event_sha256, finalized_at
)
SELECT event_id, event_sha256, unixepoch()
FROM moderation_evidence_ledger_events;

CREATE TRIGGER moderation_case_reservations_validate
BEFORE INSERT ON moderation_case_reservations
BEGIN
    SELECT (CASE
      WHEN NEW.reserved_at <> unixepoch()
      THEN RAISE(ABORT, 'case reservation must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_case_reservations
         WHERE reservation_id = NEW.reservation_id
      )
      THEN RAISE(ABORT, 'case reservation cannot be replaced')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'activated'
      ) OR EXISTS (
        SELECT 1 FROM moderation_operator_state_events
         WHERE operator_id = NEW.operator_id AND event_type = 'revoked'
      )
      THEN RAISE(ABORT, 'reserving operator is not active')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_role_events AS granted
         WHERE granted.operator_id = NEW.operator_id
           AND granted.role_code = 'triage'
           AND granted.event_type = 'granted'
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_role_events AS revoked
              WHERE revoked.operator_id = granted.operator_id
                AND revoked.role_code = granted.role_code
                AND revoked.event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'reserving operator lacks active triage role')
      WHEN EXISTS (
        SELECT 1
          FROM moderation_operator_case_references AS reference
          JOIN moderation_case_events AS event
            ON event.report_id = reference.report_id
         WHERE reference.case_reference_hmac = NEW.case_reference_hmac
           AND event.event_type = 'review_started'
      )
      THEN RAISE(ABORT, 'moderation case review has already started')
      WHEN EXISTS (
        SELECT 1
          FROM moderation_case_reservations AS existing
         WHERE existing.case_reference_hmac = NEW.case_reference_hmac
           AND (
             (
               existing.expires_at >= NEW.reserved_at
               AND NOT EXISTS (
                 SELECT 1 FROM moderation_case_reservation_consumptions
                  WHERE reservation_id = existing.reservation_id
               )
             )
              OR EXISTS (
                SELECT 1
                  FROM moderation_case_reservation_consumptions AS consumed
                  JOIN moderation_operator_actions AS action
                    ON action.action_id = consumed.action_id
                 WHERE consumed.reservation_id = existing.reservation_id
                   AND (
                     (
                       action.expires_at >= NEW.reserved_at
                       AND NOT EXISTS (
                         SELECT 1 FROM moderation_evidence_event_intents AS intent
                          WHERE intent.action_id = action.action_id
                       )
                     )
                     OR EXISTS (
                       SELECT 1
                         FROM moderation_evidence_event_intents AS intent
                        WHERE intent.action_id = action.action_id
                          AND intent.finalize_by >= NEW.reserved_at
                          AND NOT EXISTS (
                            SELECT 1 FROM moderation_evidence_event_finalizations
                             WHERE event_id = intent.event_id
                          )
                     )
                   )
              )
           )
      )
      THEN RAISE(ABORT, 'moderation case is already reserved')
      WHEN EXISTS (
        SELECT 1
          FROM moderation_case_reservations AS existing
         WHERE existing.operator_id = NEW.operator_id
           AND (
             (
               existing.expires_at >= NEW.reserved_at
               AND NOT EXISTS (
                 SELECT 1 FROM moderation_case_reservation_consumptions
                  WHERE reservation_id = existing.reservation_id
               )
             )
             OR EXISTS (
               SELECT 1
                 FROM moderation_case_reservation_consumptions AS consumed
                 JOIN moderation_operator_actions AS action
                   ON action.action_id = consumed.action_id
                WHERE consumed.reservation_id = existing.reservation_id
                  AND (
                    (
                      action.expires_at >= NEW.reserved_at
                      AND NOT EXISTS (
                        SELECT 1 FROM moderation_evidence_event_intents AS intent
                         WHERE intent.action_id = action.action_id
                      )
                    )
                    OR EXISTS (
                      SELECT 1
                        FROM moderation_evidence_event_intents AS intent
                       WHERE intent.action_id = action.action_id
                         AND intent.finalize_by >= NEW.reserved_at
                         AND NOT EXISTS (
                           SELECT 1 FROM moderation_evidence_event_finalizations
                            WHERE event_id = intent.event_id
                         )
                    )
                  )
             )
           )
      )
      THEN RAISE(ABORT, 'operator already has an active reservation')
    END);
END;

CREATE TRIGGER moderation_case_reservations_are_append_only
BEFORE UPDATE ON moderation_case_reservations
BEGIN SELECT RAISE(ABORT, 'case reservations are append-only'); END;

CREATE TRIGGER moderation_case_reservations_cannot_be_deleted
BEFORE DELETE ON moderation_case_reservations
BEGIN SELECT RAISE(ABORT, 'case reservations cannot be deleted'); END;

CREATE TRIGGER moderation_operator_review_start_requires_reservation
BEFORE INSERT ON moderation_operator_actions
WHEN NEW.action_type = 'review_start'
BEGIN
    SELECT (CASE
      WHEN (
        SELECT COUNT(*)
          FROM moderation_case_reservations AS reservation
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = NEW.request_challenge_id
         WHERE reservation.case_reference_hmac = NEW.case_reference_hmac
           AND reservation.operator_id = NEW.requester_operator_id
           AND reservation.access_subject_hmac_key_version =
               challenge.access_subject_hmac_key_version
           AND reservation.access_session_sha256 = challenge.access_session_sha256
           AND reservation.reserved_at <= NEW.requested_at
           AND reservation.expires_at >= NEW.requested_at
           AND NOT EXISTS (
             SELECT 1 FROM moderation_case_reservation_consumptions
              WHERE reservation_id = reservation.reservation_id
           )
      ) <> 1
      THEN RAISE(ABORT, 'review start requires one active bound reservation')
    END);
END;

CREATE TRIGGER moderation_operator_review_start_consumes_reservation
AFTER INSERT ON moderation_operator_actions
WHEN NEW.action_type = 'review_start'
BEGIN
    INSERT INTO moderation_case_reservation_consumptions(
      reservation_id, action_id, consumed_at
    )
    SELECT reservation.reservation_id, NEW.action_id, unixepoch()
      FROM moderation_case_reservations AS reservation
      JOIN moderation_operator_challenges AS challenge
        ON challenge.challenge_id = NEW.request_challenge_id
     WHERE reservation.case_reference_hmac = NEW.case_reference_hmac
       AND reservation.operator_id = NEW.requester_operator_id
       AND reservation.access_subject_hmac_key_version =
           challenge.access_subject_hmac_key_version
       AND reservation.access_session_sha256 = challenge.access_session_sha256
       AND reservation.reserved_at <= NEW.requested_at
       AND reservation.expires_at >= NEW.requested_at
       AND NOT EXISTS (
         SELECT 1 FROM moderation_case_reservation_consumptions
          WHERE reservation_id = reservation.reservation_id
       );
END;

CREATE TRIGGER moderation_case_reservation_consumptions_validate
BEFORE INSERT ON moderation_case_reservation_consumptions
BEGIN
    SELECT (CASE
      WHEN NEW.consumed_at <> unixepoch()
      THEN RAISE(ABORT, 'reservation consumption must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_case_reservation_consumptions
         WHERE reservation_id = NEW.reservation_id
            OR action_id = NEW.action_id
      )
      THEN RAISE(ABORT, 'reservation consumption cannot be replaced')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_case_reservations AS reservation
          JOIN moderation_operator_actions AS action
            ON action.action_id = NEW.action_id
          JOIN moderation_operator_challenges AS challenge
            ON challenge.challenge_id = action.request_challenge_id
         WHERE reservation.reservation_id = NEW.reservation_id
           AND action.action_type = 'review_start'
           AND action.case_reference_hmac = reservation.case_reference_hmac
           AND action.requester_operator_id = reservation.operator_id
           AND challenge.access_subject_hmac_key_version =
               reservation.access_subject_hmac_key_version
           AND challenge.access_session_sha256 =
               reservation.access_session_sha256
           AND reservation.reserved_at <= action.requested_at
           AND reservation.expires_at >= action.requested_at
           AND NEW.consumed_at >= action.requested_at
      )
      THEN RAISE(ABORT, 'reservation consumption is not bound to review start')
    END);
END;

CREATE TRIGGER moderation_case_reservation_consumptions_are_append_only
BEFORE UPDATE ON moderation_case_reservation_consumptions
BEGIN SELECT RAISE(ABORT, 'reservation consumptions are append-only'); END;

CREATE TRIGGER moderation_case_reservation_consumptions_cannot_be_deleted
BEFORE DELETE ON moderation_case_reservation_consumptions
BEGIN SELECT RAISE(ABORT, 'reservation consumptions cannot be deleted'); END;

CREATE TRIGGER moderation_evidence_event_intents_validate
BEFORE INSERT ON moderation_evidence_event_intents
BEGIN
    SELECT (CASE
      WHEN NEW.legacy_backfill <> 0
      THEN RAISE(ABORT, 'legacy evidence intents cannot be created')
      WHEN NEW.action_type IN ('review_decision', 'content_delete')
      THEN RAISE(ABORT, 'domain-changing evidence is not enabled')
      WHEN NEW.occurred_at <> unixepoch()
      THEN RAISE(ABORT, 'evidence intent must use database time')
      WHEN NEW.finalize_by <> NEW.occurred_at + 120
      THEN RAISE(ABORT, 'evidence intent must use the fixed finalization window')
      WHEN EXISTS (
        SELECT 1 FROM moderation_evidence_event_intents
         WHERE event_id = NEW.event_id OR action_id = NEW.action_id
      )
      THEN RAISE(ABORT, 'evidence intent cannot be replayed or replaced')
      WHEN EXISTS (
        SELECT 1 FROM moderation_evidence_event_intents AS pending
         WHERE pending.case_reference_hmac = NEW.case_reference_hmac
           AND pending.finalize_by >= NEW.occurred_at
           AND NOT EXISTS (
             SELECT 1 FROM moderation_evidence_event_finalizations
              WHERE event_id = pending.event_id
           )
      )
      THEN RAISE(ABORT, 'case already has a pending evidence intent')
      WHEN EXISTS (
        SELECT 1
          FROM moderation_evidence_event_intents AS pending
          JOIN moderation_operator_actions AS pending_action
            ON pending_action.action_id = pending.action_id
          JOIN moderation_operator_actions AS new_action
            ON new_action.action_id = NEW.action_id
         WHERE pending_action.requester_operator_id =
               new_action.requester_operator_id
           AND pending.finalize_by >= NEW.occurred_at
           AND NOT EXISTS (
             SELECT 1 FROM moderation_evidence_event_finalizations
              WHERE event_id = pending.event_id
           )
      )
      THEN RAISE(ABORT, 'operator already has a pending evidence intent')
      WHEN NEW.sequence <> COALESCE((
        SELECT MAX(sequence) + 1
          FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = NEW.case_reference_hmac
      ), 1)
      THEN RAISE(ABORT, 'evidence intent sequence must be contiguous')
      WHEN NEW.occurred_at < COALESCE((
        SELECT occurred_at
          FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = NEW.case_reference_hmac
         ORDER BY sequence DESC
         LIMIT 1
      ), 0)
      THEN RAISE(ABORT, 'evidence intent time precedes the case head')
      WHEN NEW.previous_event_sha256 <> COALESCE((
        SELECT event_sha256
          FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = NEW.case_reference_hmac
         ORDER BY sequence DESC
         LIMIT 1
      ), '0000000000000000000000000000000000000000000000000000000000000000')
      THEN RAISE(ABORT, 'evidence intent previous digest does not match case head')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_challenges AS request_challenge
            ON request_challenge.challenge_id = action.request_challenge_id
          JOIN moderation_operator_subject_identities AS actor
            ON actor.operator_id = action.requester_operator_id
           AND actor.access_subject_hmac_key_version =
               request_challenge.access_subject_hmac_key_version
         WHERE action.action_id = NEW.action_id
           AND action.case_reference_hmac = NEW.case_reference_hmac
           AND action.action_type = NEW.action_type
           AND action.requested_at <= NEW.occurred_at
           AND action.expires_at >= NEW.occurred_at
           AND actor.access_subject_hmac_key_version =
               NEW.actor_subject_hmac_key_version
           AND actor.access_subject_hmac = NEW.actor_subject_hmac
      )
      THEN RAISE(ABORT, 'evidence intent action or actor does not match case')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_operator_actions AS action
         WHERE action.action_id = NEW.action_id
           AND action.required_approvals <= (
             SELECT COUNT(*)
               FROM moderation_operator_action_approvals AS approval
              WHERE approval.action_id = action.action_id
                AND approval.recorded_at <= NEW.occurred_at
           )
      )
      THEN RAISE(ABORT, 'evidence intent action is not fully approved')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_challenge_consumptions AS consumption
            ON consumption.challenge_id = action.request_challenge_id
          JOIN moderation_operator_credential_events AS registered
            ON registered.credential_id_sha256 = consumption.credential_id_sha256
           AND registered.event_type = 'registered'
          JOIN moderation_operator_role_events AS role_grant
            ON role_grant.operator_id = action.requester_operator_id
           AND role_grant.event_type = 'granted'
           AND role_grant.role_code = (CASE action.action_type
             WHEN 'review_start' THEN 'triage'
             ELSE 'evidence_reviewer'
           END)
         WHERE action.action_id = NEW.action_id
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_credential_events AS revoked
              WHERE revoked.credential_id_sha256 = consumption.credential_id_sha256
                AND revoked.event_type = 'revoked'
           )
           AND EXISTS (
             SELECT 1 FROM moderation_operator_state_events AS activated
              WHERE activated.operator_id = action.requester_operator_id
                AND activated.event_type = 'activated'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_state_events AS revoked_actor
              WHERE revoked_actor.operator_id = action.requester_operator_id
                AND revoked_actor.event_type = 'revoked'
           )
           AND NOT EXISTS (
             SELECT 1 FROM moderation_operator_role_events AS role_revoked
              WHERE role_revoked.operator_id = action.requester_operator_id
                AND role_revoked.role_code = role_grant.role_code
                AND role_revoked.event_type = 'revoked'
           )
      )
      THEN RAISE(ABORT, 'evidence intent requester is not active')
      WHEN EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_action_approvals AS approval
            ON approval.action_id = action.action_id
          JOIN moderation_operator_challenge_consumptions AS consumption
            ON consumption.challenge_id = approval.approval_challenge_id
         WHERE action.action_id = NEW.action_id
           AND (
             EXISTS (
               SELECT 1 FROM moderation_operator_credential_events AS revoked
                WHERE revoked.credential_id_sha256 = consumption.credential_id_sha256
                  AND revoked.event_type = 'revoked'
             )
             OR EXISTS (
               SELECT 1 FROM moderation_operator_state_events AS revoked_approver
                WHERE revoked_approver.operator_id = approval.operator_id
                  AND revoked_approver.event_type = 'revoked'
             )
             OR EXISTS (
               SELECT 1 FROM moderation_operator_role_events AS revoked_role
                WHERE revoked_role.operator_id = approval.operator_id
                  AND revoked_role.role_code = action.required_approver_role
                  AND revoked_role.event_type = 'revoked'
             )
           )
      )
      THEN RAISE(ABORT, 'evidence intent approval is no longer active')
      WHEN NEW.action_type = 'review_start' AND NOT EXISTS (
        SELECT 1 FROM moderation_case_reservation_consumptions
         WHERE action_id = NEW.action_id
      )
      THEN RAISE(ABORT, 'review start intent lacks reservation consumption')
      WHEN NEW.action_type = 'review_start' AND EXISTS (
        SELECT 1
          FROM moderation_operator_case_references AS reference
          JOIN moderation_case_events AS event ON event.report_id = reference.report_id
         WHERE reference.case_reference_hmac = NEW.case_reference_hmac
      )
      THEN RAISE(ABORT, 'review start intent conflicts with case state')
    END);
END;

CREATE TRIGGER moderation_evidence_event_intents_are_append_only
BEFORE UPDATE ON moderation_evidence_event_intents
BEGIN SELECT RAISE(ABORT, 'evidence intents are append-only'); END;

CREATE TRIGGER moderation_evidence_event_intents_cannot_be_deleted
BEFORE DELETE ON moderation_evidence_event_intents
BEGIN SELECT RAISE(ABORT, 'evidence intents cannot be deleted'); END;

DROP TRIGGER moderation_evidence_ledger_events_validate;

CREATE TRIGGER moderation_evidence_ledger_events_validate
BEFORE INSERT ON moderation_evidence_ledger_events
BEGIN
    SELECT (CASE
      WHEN EXISTS (
        SELECT 1 FROM moderation_evidence_ledger_events
         WHERE event_id = NEW.event_id
            OR action_id = NEW.action_id
            OR event_sha256 = NEW.event_sha256
      )
      THEN RAISE(ABORT, 'evidence event cannot be replayed or replaced')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_evidence_event_intents AS intent
         WHERE intent.event_id = NEW.event_id
           AND intent.legacy_backfill = 0
           AND intent.case_reference_hmac = NEW.case_reference_hmac
           AND intent.sequence = NEW.sequence
           AND intent.action_id = NEW.action_id
           AND intent.action_type = NEW.action_type
           AND intent.actor_subject_hmac_key_version =
               NEW.actor_subject_hmac_key_version
           AND intent.actor_subject_hmac = NEW.actor_subject_hmac
           AND intent.occurred_at = NEW.occurred_at
           AND intent.previous_event_sha256 = NEW.previous_event_sha256
            AND intent.artifact_sha256 = NEW.artifact_sha256
            AND intent.finalize_by >= unixepoch()
            AND NOT EXISTS (
             SELECT 1 FROM moderation_evidence_event_finalizations
              WHERE event_id = intent.event_id
           )
      )
      THEN RAISE(ABORT, 'evidence event does not match an open intent')
      WHEN NEW.sequence <> COALESCE((
        SELECT MAX(sequence) + 1
          FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = NEW.case_reference_hmac
      ), 1)
      THEN RAISE(ABORT, 'evidence sequence must be contiguous')
      WHEN NEW.previous_event_sha256 <> COALESCE((
        SELECT event_sha256
          FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = NEW.case_reference_hmac
         ORDER BY sequence DESC
         LIMIT 1
      ), '0000000000000000000000000000000000000000000000000000000000000000')
      THEN RAISE(ABORT, 'evidence previous digest does not match case head')
    END);
END;

CREATE TRIGGER moderation_evidence_event_finalizations_validate
BEFORE INSERT ON moderation_evidence_event_finalizations
BEGIN
    SELECT (CASE
      WHEN NEW.finalized_at <> unixepoch()
      THEN RAISE(ABORT, 'evidence finalization must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_evidence_event_finalizations
         WHERE event_id = NEW.event_id OR event_sha256 = NEW.event_sha256
      )
      THEN RAISE(ABORT, 'evidence finalization cannot be replayed')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_evidence_event_intents AS intent
          JOIN moderation_evidence_ledger_events AS event
            ON event.event_id = intent.event_id
          WHERE intent.event_id = NEW.event_id
            AND event.event_sha256 = NEW.event_sha256
           AND event.action_id = intent.action_id
           AND event.case_reference_hmac = intent.case_reference_hmac
            AND event.sequence = intent.sequence
            AND NEW.finalized_at >= intent.occurred_at
            AND NEW.finalized_at <= intent.finalize_by
      )
      THEN RAISE(ABORT, 'evidence finalization does not match ledger intent')
    END);
END;

CREATE TRIGGER moderation_evidence_event_finalizations_are_append_only
BEFORE UPDATE ON moderation_evidence_event_finalizations
BEGIN SELECT RAISE(ABORT, 'evidence finalizations are append-only'); END;

CREATE TRIGGER moderation_evidence_event_finalizations_cannot_be_deleted
BEFORE DELETE ON moderation_evidence_event_finalizations
BEGIN SELECT RAISE(ABORT, 'evidence finalizations cannot be deleted'); END;

CREATE TRIGGER moderation_case_events_require_operator_evidence
BEFORE INSERT ON moderation_case_events
BEGIN
    SELECT (CASE
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_evidence_event_intents AS intent
          JOIN moderation_evidence_event_finalizations AS finalization
            ON finalization.event_id = intent.event_id
          JOIN moderation_operator_case_references AS reference
            ON reference.case_reference_hmac = intent.case_reference_hmac
         WHERE intent.legacy_backfill = 0
           AND reference.report_id = NEW.report_id
            AND intent.action_type = 'review_start'
            AND NEW.event_type = 'review_started'
            AND NEW.outcome_code IS NULL
      )
      THEN RAISE(ABORT, 'case event requires finalized operator evidence')
    END);
END;

CREATE TRIGGER moderation_operator_case_event_links_validate
BEFORE INSERT ON moderation_operator_case_event_links
BEGIN
    SELECT (CASE
      WHEN EXISTS (
        SELECT 1 FROM moderation_operator_case_event_links
         WHERE event_id = NEW.event_id
            OR action_id = NEW.action_id
            OR (report_id = NEW.report_id AND event_type = NEW.event_type)
      )
      THEN RAISE(ABORT, 'operator case event link cannot be replaced')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_evidence_event_intents AS intent
          JOIN moderation_evidence_event_finalizations AS finalization
            ON finalization.event_id = intent.event_id
          JOIN moderation_evidence_ledger_events AS event
            ON event.event_id = intent.event_id
          JOIN moderation_operator_case_references AS reference
            ON reference.case_reference_hmac = intent.case_reference_hmac
         WHERE intent.legacy_backfill = 0
           AND intent.event_id = NEW.event_id
           AND intent.action_id = NEW.action_id
           AND event.action_id = NEW.action_id
           AND reference.report_id = NEW.report_id
            AND intent.action_type = 'review_start'
            AND NEW.event_type = 'review_started'
      )
      THEN RAISE(ABORT, 'operator case event link is not authorized')
    END);
END;

CREATE TRIGGER moderation_operator_case_event_links_are_append_only
BEFORE UPDATE ON moderation_operator_case_event_links
BEGIN SELECT RAISE(ABORT, 'operator case event links are append-only'); END;

CREATE TRIGGER moderation_operator_case_event_links_cannot_be_deleted
BEFORE DELETE ON moderation_operator_case_event_links
BEGIN SELECT RAISE(ABORT, 'operator case event links cannot be deleted'); END;

CREATE TRIGGER moderation_evidence_ledger_events_finalize_intent
AFTER INSERT ON moderation_evidence_ledger_events
BEGIN
    INSERT INTO moderation_evidence_event_finalizations(
      event_id, event_sha256, finalized_at
    ) VALUES (NEW.event_id, NEW.event_sha256, unixepoch());

    INSERT INTO moderation_case_events(
      report_id, event_type, outcome_code, recorded_at
    )
    SELECT
      reference.report_id,
      'review_started',
      intent.case_outcome_code,
      unixepoch()
      FROM moderation_evidence_event_intents AS intent
      JOIN moderation_operator_case_references AS reference
        ON reference.case_reference_hmac = intent.case_reference_hmac
     WHERE intent.event_id = NEW.event_id
       AND intent.action_type = 'review_start';

    INSERT INTO moderation_operator_case_event_links(
      event_id, action_id, report_id, event_type
    )
    SELECT
      intent.event_id,
      intent.action_id,
      reference.report_id,
      'review_started'
      FROM moderation_evidence_event_intents AS intent
      JOIN moderation_operator_case_references AS reference
        ON reference.case_reference_hmac = intent.case_reference_hmac
     WHERE intent.event_id = NEW.event_id
       AND intent.action_type = 'review_start';
END;
