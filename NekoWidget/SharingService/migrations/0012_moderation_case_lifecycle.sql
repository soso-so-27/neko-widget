-- Additive, operator-inaccessible moderation lifecycle foundation.
--
-- Cases reference the minimal report tombstone rather than moment_reports so
-- the lifecycle receipt survives normal seven-day evidence deletion without
-- retaining participant, device, object-key, ciphertext, or reason fields.
CREATE TABLE moderation_cases (
    report_id TEXT PRIMARY KEY
        REFERENCES moment_report_tombstones(report_id) ON DELETE RESTRICT,
    committed_at INTEGER NOT NULL,
    review_due_at INTEGER NOT NULL,
    CHECK (review_due_at = committed_at + 172800)
) STRICT;

CREATE INDEX moderation_cases_review_due
    ON moderation_cases(review_due_at, report_id);

-- The event pair is the state machine. There is no mutable status column and
-- no operator route in this migration. A future authenticated operator service
-- must append these server-timestamped receipts rather than editing history.
CREATE TABLE moderation_case_events (
    report_id TEXT NOT NULL
        REFERENCES moderation_cases(report_id) ON DELETE RESTRICT,
    event_type TEXT NOT NULL CHECK (
      event_type IN ('review_started', 'review_decided')
    ),
    outcome_code TEXT CHECK (
      outcome_code IS NULL OR outcome_code IN (
        'no_action',
        'warning',
        'block',
        'account_removal',
        'safety_or_legal_escalation'
      )
    ),
    recorded_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (report_id, event_type),
    CHECK (
      (event_type = 'review_started' AND outcome_code IS NULL)
      OR
      (event_type = 'review_decided' AND outcome_code IS NOT NULL)
    )
) STRICT;

-- Existing committed reports have no trustworthy review receipt. Backfill
-- them as unreviewed instead of inferring human action from TTL deletion or
-- any local/offline artifact.
INSERT INTO moderation_cases(report_id, committed_at, review_due_at)
SELECT report_id, committed_at, committed_at + 172800
  FROM moment_report_tombstones
 WHERE 1
ON CONFLICT(report_id) DO NOTHING;

-- moment_report_tombstones is inserted by the existing commit trigger only
-- after an uploaded report becomes committed. This keeps case creation inside
-- the same D1 transaction without adding an operator endpoint.
CREATE TRIGGER moderation_cases_create_after_report_commit
AFTER INSERT ON moment_report_tombstones
BEGIN
    INSERT INTO moderation_cases(report_id, committed_at, review_due_at)
    VALUES (NEW.report_id, NEW.committed_at, NEW.committed_at + 172800)
    ON CONFLICT(report_id) DO NOTHING;
END;

CREATE TRIGGER moderation_cases_are_immutable
BEFORE UPDATE ON moderation_cases
BEGIN
    SELECT RAISE(ABORT, 'moderation cases are immutable');
END;

CREATE TRIGGER moderation_cases_cannot_be_deleted
BEFORE DELETE ON moderation_cases
BEGIN
    SELECT RAISE(ABORT, 'moderation cases cannot be deleted');
END;

-- BEFORE INSERT also runs for INSERT OR REPLACE. Refuse an existing case so
-- SQLite conflict handling cannot turn a nominal insert into hidden mutation.
CREATE TRIGGER moderation_cases_cannot_be_replaced
BEFORE INSERT ON moderation_cases
WHEN EXISTS (
  SELECT 1 FROM moderation_cases WHERE report_id = NEW.report_id
)
BEGIN
    SELECT RAISE(ABORT, 'moderation cases cannot be replaced');
END;

CREATE TRIGGER moderation_case_events_validate_transition
BEFORE INSERT ON moderation_case_events
BEGIN
    SELECT (CASE
      WHEN NEW.recorded_at < (
        SELECT committed_at FROM moderation_cases WHERE report_id = NEW.report_id
      )
      THEN RAISE(ABORT, 'moderation event predates report commit')
      WHEN NEW.recorded_at <> unixepoch()
      THEN RAISE(ABORT, 'moderation event must use database time')
      WHEN EXISTS (
        SELECT 1 FROM moderation_case_events
         WHERE report_id = NEW.report_id AND event_type = NEW.event_type
      )
      THEN RAISE(ABORT, 'moderation event has already been recorded')
      WHEN NEW.event_type = 'review_started' AND EXISTS (
        SELECT 1 FROM moderation_case_events WHERE report_id = NEW.report_id
      )
      THEN RAISE(ABORT, 'moderation review has already started')
      WHEN NEW.event_type = 'review_decided' AND NOT EXISTS (
        SELECT 1 FROM moderation_case_events
         WHERE report_id = NEW.report_id AND event_type = 'review_started'
      )
      THEN RAISE(ABORT, 'moderation decision requires review start')
      WHEN NEW.event_type = 'review_decided' AND NEW.recorded_at < (
        SELECT recorded_at FROM moderation_case_events
         WHERE report_id = NEW.report_id AND event_type = 'review_started'
      )
      THEN RAISE(ABORT, 'moderation decision predates review start')
    END);
END;

CREATE TRIGGER moderation_case_events_are_append_only
BEFORE UPDATE ON moderation_case_events
BEGIN
    SELECT RAISE(ABORT, 'moderation case events are append-only');
END;

CREATE TRIGGER moderation_case_events_cannot_be_deleted
BEFORE DELETE ON moderation_case_events
BEGIN
    SELECT RAISE(ABORT, 'moderation case events cannot be deleted');
END;
