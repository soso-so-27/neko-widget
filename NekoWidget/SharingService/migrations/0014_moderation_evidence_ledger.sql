-- Append-only moderation evidence ledger and signed-export replay foundation.
--
-- This migration adds no route, key binding, deletion mechanism or deployment
-- configuration. Event and export digests/signatures are prepared and checked
-- cryptographically by a future authenticated service. SQL constrains their
-- canonical shapes, case-local chain continuity, approved operator action and
-- one-time persistence; it does not claim to calculate SHA-256 or Ed25519.

CREATE TABLE moderation_evidence_ledger_events (
    case_reference_hmac TEXT NOT NULL
        REFERENCES moderation_operator_case_references(case_reference_hmac)
        ON DELETE RESTRICT,
    sequence INTEGER NOT NULL CHECK (sequence BETWEEN 1 AND 2147483647),
    event_id TEXT NOT NULL UNIQUE CHECK (
      length(event_id) = 36
      AND lower(event_id) = event_id
      AND substr(event_id, 9, 1) = '-'
      AND substr(event_id, 14, 1) = '-'
      AND substr(event_id, 15, 1) = '4'
      AND substr(event_id, 19, 1) = '-'
      AND substr(event_id, 20, 1) GLOB '[89ab]'
      AND substr(event_id, 24, 1) = '-'
      AND event_id NOT GLOB '*[^0-9a-f-]*'
    ),
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
      actor_subject_hmac_key_version > 0
      AND actor_subject_hmac_key_version <= 2147483647
    ),
    actor_subject_hmac TEXT NOT NULL CHECK (
          length(actor_subject_hmac) = 64
          AND actor_subject_hmac NOT GLOB '*[^0-9a-f]*'
    ),
    occurred_at INTEGER NOT NULL DEFAULT (unixepoch()),
    previous_event_sha256 TEXT NOT NULL CHECK (
      length(previous_event_sha256) = 64
      AND previous_event_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    artifact_sha256 TEXT NOT NULL CHECK (
      length(artifact_sha256) = 64
      AND artifact_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    event_sha256 TEXT NOT NULL UNIQUE CHECK (
      length(event_sha256) = 64
      AND event_sha256 NOT GLOB '*[^0-9a-f]*'
      AND event_sha256 <>
        '0000000000000000000000000000000000000000000000000000000000000000'
    ),
    PRIMARY KEY (case_reference_hmac, sequence),
    FOREIGN KEY (actor_subject_hmac_key_version, actor_subject_hmac)
      REFERENCES moderation_operator_subject_identities(
        access_subject_hmac_key_version, access_subject_hmac
      ) ON DELETE RESTRICT
) STRICT;

CREATE INDEX moderation_evidence_ledger_case_time
    ON moderation_evidence_ledger_events(
      case_reference_hmac, occurred_at, sequence
    );

CREATE TABLE moderation_evidence_exports (
    export_id TEXT PRIMARY KEY CHECK (
      length(export_id) = 36
      AND lower(export_id) = export_id
      AND substr(export_id, 9, 1) = '-'
      AND substr(export_id, 14, 1) = '-'
      AND substr(export_id, 15, 1) = '4'
      AND substr(export_id, 19, 1) = '-'
      AND substr(export_id, 20, 1) GLOB '[89ab]'
      AND substr(export_id, 24, 1) = '-'
      AND export_id NOT GLOB '*[^0-9a-f-]*'
    ),
    case_reference_hmac TEXT NOT NULL
        REFERENCES moderation_operator_case_references(case_reference_hmac)
        ON DELETE RESTRICT,
    action_id TEXT NOT NULL UNIQUE
        REFERENCES moderation_operator_actions(action_id) ON DELETE RESTRICT,
    actor_subject_hmac_key_version INTEGER NOT NULL CHECK (
      actor_subject_hmac_key_version > 0
      AND actor_subject_hmac_key_version <= 2147483647
    ),
    actor_subject_hmac TEXT NOT NULL CHECK (
      length(actor_subject_hmac) = 64
      AND actor_subject_hmac NOT GLOB '*[^0-9a-f]*'
    ),
    event_count INTEGER NOT NULL CHECK (
      event_count BETWEEN 1 AND 2147483647
    ),
    chain_head_sha256 TEXT NOT NULL CHECK (
      length(chain_head_sha256) = 64
      AND chain_head_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    export_sha256 TEXT NOT NULL UNIQUE CHECK (
      length(export_sha256) = 64
      AND export_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    signing_key_id TEXT NOT NULL CHECK (
      length(signing_key_id) BETWEEN 3 AND 64
      AND lower(signing_key_id) = signing_key_id
      AND substr(signing_key_id, 1, 1) GLOB '[a-z]'
      AND signing_key_id NOT GLOB '*[^a-z0-9-]*'
    ),
    -- A canonical unpadded base64url Ed25519 signature is exactly 86 ASCII
    -- characters; its final character has only two significant bits.
    signature TEXT NOT NULL UNIQUE CHECK (
      length(signature) = 86
      AND signature NOT GLOB '*[^A-Za-z0-9_-]*'
      AND substr(signature, 86, 1) GLOB '[AQgw]'
    ),
    generated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (actor_subject_hmac_key_version, actor_subject_hmac)
      REFERENCES moderation_operator_subject_identities(
        access_subject_hmac_key_version, access_subject_hmac
      ) ON DELETE RESTRICT
) STRICT;

CREATE INDEX moderation_evidence_exports_case_time
    ON moderation_evidence_exports(
      case_reference_hmac, generated_at, export_id
    );

CREATE TRIGGER moderation_evidence_ledger_events_validate
BEFORE INSERT ON moderation_evidence_ledger_events
BEGIN
    SELECT (CASE
      WHEN NEW.occurred_at <> unixepoch()
      THEN RAISE(ABORT, 'evidence event must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_evidence_ledger_events
         WHERE event_id = NEW.event_id
            OR action_id = NEW.action_id
            OR event_sha256 = NEW.event_sha256
      )
      THEN RAISE(ABORT, 'evidence event cannot be replayed or replaced')
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
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_subject_identities AS actor
            ON actor.operator_id = action.requester_operator_id
         WHERE action.action_id = NEW.action_id
           AND action.case_reference_hmac = NEW.case_reference_hmac
           AND action.action_type = NEW.action_type
           AND actor.access_subject_hmac_key_version =
               NEW.actor_subject_hmac_key_version
           AND actor.access_subject_hmac = NEW.actor_subject_hmac
           AND action.requested_at <= NEW.occurred_at
           AND action.expires_at >= NEW.occurred_at
      )
      THEN RAISE(ABORT, 'evidence event action or actor does not match case')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
         WHERE action.action_id = NEW.action_id
           AND action.required_approvals <= (
             SELECT COUNT(*)
               FROM moderation_operator_action_approvals AS approval
              WHERE approval.action_id = action.action_id
                AND approval.recorded_at <= NEW.occurred_at
           )
      )
      THEN RAISE(ABORT, 'evidence event action is not fully approved')
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
           AND role_grant.role_code = CASE action.action_type
             WHEN 'review_start' THEN 'triage'
             ELSE 'evidence_reviewer'
           END
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
      THEN RAISE(ABORT, 'evidence event requester is not active')
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
      THEN RAISE(ABORT, 'evidence event approval is no longer active')
    END);
END;

CREATE TRIGGER moderation_evidence_ledger_events_are_append_only
BEFORE UPDATE ON moderation_evidence_ledger_events
BEGIN SELECT RAISE(ABORT, 'evidence ledger events are append-only'); END;

CREATE TRIGGER moderation_evidence_ledger_events_cannot_be_deleted
BEFORE DELETE ON moderation_evidence_ledger_events
BEGIN SELECT RAISE(ABORT, 'evidence ledger events cannot be deleted'); END;

CREATE TRIGGER moderation_evidence_exports_validate
BEFORE INSERT ON moderation_evidence_exports
BEGIN
    SELECT (CASE
      WHEN NEW.generated_at <> unixepoch()
      THEN RAISE(ABORT, 'evidence export must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_evidence_exports
         WHERE export_id = NEW.export_id
            OR export_sha256 = NEW.export_sha256
            OR signature = NEW.signature
      )
      THEN RAISE(ABORT, 'evidence export cannot be replayed or replaced')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
          JOIN moderation_operator_subject_identities AS actor
            ON actor.operator_id = action.requester_operator_id
          JOIN moderation_operator_challenge_consumptions AS consumption
            ON consumption.challenge_id = action.request_challenge_id
          JOIN moderation_operator_credential_events AS registered
            ON registered.credential_id_sha256 = consumption.credential_id_sha256
           AND registered.event_type = 'registered'
          JOIN moderation_operator_role_events AS role_grant
            ON role_grant.operator_id = action.requester_operator_id
           AND role_grant.role_code = 'evidence_reviewer'
           AND role_grant.event_type = 'granted'
         WHERE action.action_id = NEW.action_id
           AND action.action_type = 'evidence_export'
           AND action.case_reference_hmac = NEW.case_reference_hmac
           AND action.requested_at <= NEW.generated_at
           AND action.expires_at >= NEW.generated_at
           AND actor.access_subject_hmac_key_version =
               NEW.actor_subject_hmac_key_version
           AND actor.access_subject_hmac = NEW.actor_subject_hmac
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
      THEN RAISE(ABORT, 'evidence export action or requester is not active')
      WHEN NOT EXISTS (
        SELECT 1
          FROM moderation_operator_actions AS action
         WHERE action.action_id = NEW.action_id
           AND action.required_approvals <= (
             SELECT COUNT(*)
               FROM moderation_operator_action_approvals AS approval
               JOIN moderation_operator_challenge_consumptions AS consumption
                 ON consumption.challenge_id = approval.approval_challenge_id
              WHERE approval.action_id = action.action_id
                AND approval.recorded_at <= NEW.generated_at
                AND NOT EXISTS (
                  SELECT 1 FROM moderation_operator_credential_events AS revoked
                   WHERE revoked.credential_id_sha256 = consumption.credential_id_sha256
                     AND revoked.event_type = 'revoked'
                )
                AND EXISTS (
                  SELECT 1 FROM moderation_operator_state_events AS activated
                   WHERE activated.operator_id = approval.operator_id
                     AND activated.event_type = 'activated'
                )
                AND NOT EXISTS (
                  SELECT 1 FROM moderation_operator_state_events AS revoked_approver
                   WHERE revoked_approver.operator_id = approval.operator_id
                     AND revoked_approver.event_type = 'revoked'
                )
                AND EXISTS (
                  SELECT 1 FROM moderation_operator_role_events AS role_grant
                   WHERE role_grant.operator_id = approval.operator_id
                     AND role_grant.role_code = action.required_approver_role
                     AND role_grant.event_type = 'granted'
                     AND NOT EXISTS (
                       SELECT 1 FROM moderation_operator_role_events AS role_revoked
                        WHERE role_revoked.operator_id = approval.operator_id
                          AND role_revoked.role_code = role_grant.role_code
                          AND role_revoked.event_type = 'revoked'
                     )
                )
           )
      )
      THEN RAISE(ABORT, 'evidence export action is not fully approved')
      WHEN NOT EXISTS (
        SELECT 1 FROM moderation_evidence_ledger_events AS event
         WHERE event.action_id = NEW.action_id
           AND event.action_type = 'evidence_export'
           AND event.case_reference_hmac = NEW.case_reference_hmac
           AND event.actor_subject_hmac_key_version =
               NEW.actor_subject_hmac_key_version
           AND event.actor_subject_hmac = NEW.actor_subject_hmac
      )
      THEN RAISE(ABORT, 'evidence export action is not recorded in the ledger')
      WHEN NEW.event_count <> (
        SELECT COUNT(*)
          FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = NEW.case_reference_hmac
      )
      THEN RAISE(ABORT, 'evidence export event count does not match case ledger')
      WHEN NEW.chain_head_sha256 <> COALESCE((
        SELECT event_sha256
          FROM moderation_evidence_ledger_events
         WHERE case_reference_hmac = NEW.case_reference_hmac
         ORDER BY sequence DESC
         LIMIT 1
      ), '')
      THEN RAISE(ABORT, 'evidence export chain head does not match case ledger')
    END);
END;

CREATE TRIGGER moderation_evidence_exports_are_append_only
BEFORE UPDATE ON moderation_evidence_exports
BEGIN SELECT RAISE(ABORT, 'evidence exports are append-only'); END;

CREATE TRIGGER moderation_evidence_exports_cannot_be_deleted
BEFORE DELETE ON moderation_evidence_exports
BEGIN SELECT RAISE(ABORT, 'evidence exports cannot be deleted'); END;
