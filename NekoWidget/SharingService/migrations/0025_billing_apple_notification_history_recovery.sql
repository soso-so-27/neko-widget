PRAGMA foreign_keys = ON;

-- Notification History is a recovery path, not an extension of the public
-- App Store notification endpoint.  Keep its D1 lower gate independent and
-- closed until the private verifier, control plane and recovery drill have all
-- been reviewed.
ALTER TABLE billing_runtime_gate
  ADD COLUMN apple_notification_history_recovery_enabled INTEGER NOT NULL DEFAULT 0
  CHECK (apple_notification_history_recovery_enabled IN (0, 1));

-- One immutable cause row makes queueing idempotent per verified Apple
-- notification. Replaying a notification can INSERT OR IGNORE the missing
-- cause to repair an interrupted event/queue sequence, while an ordinary
-- Apple retry cannot keep incrementing request_generation.
CREATE TABLE billing_apple_notification_reconciliation_causes (
    notification_uuid TEXT PRIMARY KEY
      REFERENCES billing_apple_notification_events(notification_uuid) ON DELETE RESTRICT,
    original_transaction_id TEXT NOT NULL
      REFERENCES billing_transaction_lineages(original_transaction_id) ON DELETE RESTRICT,
    requested_at INTEGER NOT NULL DEFAULT (unixepoch()) CHECK (requested_at > 0)
) STRICT;

CREATE TRIGGER billing_apple_notification_reconciliation_cause_matches_event
BEFORE INSERT ON billing_apple_notification_reconciliation_causes
WHEN NEW.requested_at <> unixepoch()
  OR NOT EXISTS (
    SELECT 1
      FROM billing_apple_notification_events AS event
      JOIN billing_transaction_lineages AS lineage
        ON lineage.original_transaction_id = event.original_transaction_id
     WHERE event.notification_uuid = NEW.notification_uuid
       AND event.relevance IN ('linked', 'unmatched')
       AND event.original_transaction_id = NEW.original_transaction_id
       AND lineage.billing_account_id = event.billing_account_id
       AND lineage.environment = event.environment
       AND EXISTS (
         SELECT 1
           FROM billing_transaction_events AS transaction_event
          WHERE transaction_event.transaction_id = event.transaction_id
            AND transaction_event.original_transaction_id = event.original_transaction_id
            AND transaction_event.billing_account_id = event.billing_account_id
            AND transaction_event.environment = event.environment
            AND transaction_event.subscription_group_id = lineage.subscription_group_id
       )
  )
BEGIN SELECT RAISE(ABORT, 'notification reconciliation cause must match linked event'); END;

-- Preserve already-recorded linked events without causing generation churn.
-- Repair their queue once per lineage before enabling the per-cause trigger.
INSERT INTO billing_apple_notification_reconciliation_causes(
  notification_uuid, original_transaction_id
)
SELECT notification_uuid, original_transaction_id
  FROM billing_apple_notification_events
 WHERE relevance = 'linked' AND original_transaction_id IS NOT NULL;

INSERT INTO billing_reconciliation_jobs(
  original_transaction_id, requested_at, not_before
)
SELECT original_transaction_id, MAX(requested_at), MIN(requested_at)
  FROM billing_apple_notification_reconciliation_causes
 WHERE 1
 GROUP BY original_transaction_id
ON CONFLICT(original_transaction_id) DO UPDATE SET
  requested_at = MAX(billing_reconciliation_jobs.requested_at, excluded.requested_at),
  not_before = MIN(billing_reconciliation_jobs.not_before, excluded.not_before),
  request_generation = billing_reconciliation_jobs.request_generation + 1,
  updated_at = unixepoch();

CREATE TRIGGER billing_apple_notification_reconciliation_cause_queues_once
AFTER INSERT ON billing_apple_notification_reconciliation_causes
BEGIN
  INSERT INTO billing_reconciliation_jobs(
    original_transaction_id, requested_at, not_before
  ) VALUES (NEW.original_transaction_id, NEW.requested_at, NEW.requested_at)
  ON CONFLICT(original_transaction_id) DO UPDATE SET
    requested_at = MAX(billing_reconciliation_jobs.requested_at, excluded.requested_at),
    not_before = MIN(billing_reconciliation_jobs.not_before, excluded.not_before),
    request_generation = billing_reconciliation_jobs.request_generation + 1,
    updated_at = unixepoch();
END;

CREATE TRIGGER billing_apple_notification_reconciliation_causes_are_immutable
BEFORE UPDATE ON billing_apple_notification_reconciliation_causes
BEGIN SELECT RAISE(ABORT, 'notification reconciliation causes are immutable'); END;

CREATE TRIGGER billing_apple_notification_reconciliation_causes_cannot_be_deleted
BEFORE DELETE ON billing_apple_notification_reconciliation_causes
BEGIN SELECT RAISE(ABORT, 'notification reconciliation causes cannot be deleted'); END;

-- One Worker deployment recovers one App Store environment at a time.  The
-- requested interval is frozen for the lifetime of a generation: retries and
-- pagination can never silently widen it.  pagination_cursor is an opaque,
-- verifier-signed value; the Worker stores it but never decodes it.  Raw Apple
-- JWS values deliberately have no column in this state model.
CREATE TABLE billing_apple_notification_history_recovery (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    state TEXT NOT NULL DEFAULT 'idle' CHECK (
      state IN ('idle', 'ready', 'leased', 'retry_wait', 'completed', 'blocked')
    ),
    store_environment TEXT CHECK (store_environment IN ('Sandbox', 'Production')),
    bundle_id TEXT CHECK (
      length(bundle_id) BETWEEN 3 AND 255
      AND bundle_id NOT GLOB '*[^A-Za-z0-9.-]*'
      AND instr(bundle_id, '.') > 0
    ),
    frozen_start_date_ms INTEGER CHECK (frozen_start_date_ms > 0),
    frozen_end_date_ms INTEGER CHECK (frozen_end_date_ms > 0),
    pagination_cursor TEXT CHECK (
      length(pagination_cursor) BETWEEN 1 AND 4096
      AND pagination_cursor NOT GLOB '*[^!-~]*'
    ),
    committed_page_count INTEGER NOT NULL DEFAULT 0 CHECK (committed_page_count >= 0),
    committed_record_count INTEGER NOT NULL DEFAULT 0 CHECK (
      committed_record_count >= 0
      AND committed_record_count <= committed_page_count * 20
    ),
    cursor_reset_count INTEGER NOT NULL DEFAULT 0 CHECK (cursor_reset_count BETWEEN 0 AND 3),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 20),
    not_before INTEGER NOT NULL DEFAULT 0 CHECK (not_before >= 0),
    lease_token TEXT UNIQUE CHECK (
      length(lease_token) = 22 AND lease_token NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    lease_expires_at INTEGER CHECK (lease_expires_at > 0),
    claimed_gate_generation INTEGER CHECK (claimed_gate_generation >= 0),
    last_error_code TEXT CHECK (
      length(last_error_code) BETWEEN 1 AND 64
      AND last_error_code NOT GLOB '*[^a-z0-9_]*'
    ),
    started_at INTEGER CHECK (started_at > 0),
    completed_at INTEGER CHECK (completed_at > 0),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    CHECK (
      (state = 'idle'
        AND generation = 0
        AND store_environment IS NULL AND bundle_id IS NULL
        AND frozen_start_date_ms IS NULL AND frozen_end_date_ms IS NULL
        AND pagination_cursor IS NULL
        AND committed_page_count = 0 AND committed_record_count = 0
        AND cursor_reset_count = 0 AND attempts = 0 AND not_before = 0
        AND lease_token IS NULL AND lease_expires_at IS NULL
        AND last_error_code IS NULL AND started_at IS NULL AND completed_at IS NULL)
      OR
      (state <> 'idle'
        AND generation > 0
        AND store_environment IS NOT NULL AND bundle_id IS NOT NULL
        AND frozen_start_date_ms IS NOT NULL AND frozen_end_date_ms IS NOT NULL
        AND frozen_start_date_ms < frozen_end_date_ms
        AND frozen_end_date_ms - frozen_start_date_ms <= (CASE store_environment
          WHEN 'Sandbox' THEN 2592000000
          WHEN 'Production' THEN 15552000000
        END)
        AND started_at IS NOT NULL)
    ),
    CHECK (
      (state = 'leased' AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL
        AND claimed_gate_generation IS NOT NULL)
      OR (state <> 'leased' AND lease_token IS NULL AND lease_expires_at IS NULL
        AND claimed_gate_generation IS NULL)
    ),
    CHECK (
      (state = 'retry_wait' AND attempts > 0 AND not_before > 0
        AND last_error_code IS NOT NULL AND completed_at IS NULL)
      OR (state = 'blocked' AND last_error_code IS NOT NULL AND completed_at IS NULL)
      OR (state = 'completed' AND attempts = 0 AND pagination_cursor IS NULL
        AND last_error_code IS NULL AND completed_at IS NOT NULL
        AND committed_page_count > 0)
      OR (state IN ('ready', 'leased') AND last_error_code IS NULL
        AND completed_at IS NULL)
      OR state = 'idle'
    )
) STRICT;

INSERT INTO billing_apple_notification_history_recovery(singleton) VALUES (1);

-- The page ledger is an atomic guard and a compact audit trail. The caller
-- first durably records normalized events/causes; then one repository batch
-- verifies event receipts, inserts this guard and advances the state. The
-- trigger rejects stale generations, stolen/expired leases and skipped pages.
-- Cursor hashes aid diagnosis without disclosing the signed cursor itself.
-- A gate change may therefore leave append-only verified facts from an
-- already-started request, but it cannot checkpoint their page/cursor; those
-- facts grant no entitlement directly and are replayed idempotently on resume.
CREATE TABLE billing_apple_notification_history_page_commits (
    generation INTEGER NOT NULL CHECK (generation > 0),
    page_index INTEGER NOT NULL CHECK (page_index > 0),
    gate_generation INTEGER NOT NULL CHECK (gate_generation >= 0),
    lease_token TEXT NOT NULL CHECK (
      length(lease_token) = 22 AND lease_token NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    input_cursor_hash TEXT CHECK (
      length(input_cursor_hash) = 43
      AND input_cursor_hash NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    next_cursor_hash TEXT CHECK (
      length(next_cursor_hash) = 43
      AND next_cursor_hash NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    has_more INTEGER NOT NULL CHECK (has_more IN (0, 1)),
    record_count INTEGER NOT NULL CHECK (record_count BETWEEN 0 AND 20),
    committed_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (generation, page_index),
    CHECK (
      (has_more = 1 AND next_cursor_hash IS NOT NULL)
      OR (has_more = 0 AND next_cursor_hash IS NULL)
    ),
    CHECK (
      (page_index = 1 AND input_cursor_hash IS NULL)
      OR (page_index > 1 AND input_cursor_hash IS NOT NULL)
    ),
    CHECK (
      has_more = 0 OR input_cursor_hash IS NULL OR next_cursor_hash <> input_cursor_hash
    )
) STRICT;

CREATE UNIQUE INDEX billing_apple_notification_history_cursor_once_per_generation
    ON billing_apple_notification_history_page_commits(generation, next_cursor_hash)
    WHERE next_cursor_hash IS NOT NULL;

CREATE TRIGGER billing_apple_notification_history_page_commit_requires_lease
BEFORE INSERT ON billing_apple_notification_history_page_commits
WHEN NOT EXISTS (
  SELECT 1
    FROM billing_apple_notification_history_recovery AS recovery
   WHERE recovery.singleton = 1
     AND recovery.state = 'leased'
     AND recovery.generation = NEW.generation
     AND recovery.lease_token = NEW.lease_token
     AND recovery.claimed_gate_generation = NEW.gate_generation
     AND recovery.lease_expires_at > unixepoch()
     AND recovery.committed_page_count + 1 = NEW.page_index
     AND (
       NEW.page_index = 1
       OR EXISTS (
         SELECT 1
           FROM billing_apple_notification_history_page_commits AS previous
          WHERE previous.generation = NEW.generation
            AND previous.page_index = NEW.page_index - 1
            AND previous.next_cursor_hash = NEW.input_cursor_hash
       )
     )
     AND EXISTS (
       SELECT 1 FROM billing_runtime_gate AS gate
        WHERE gate.singleton = 1
          AND gate.apple_notification_history_recovery_enabled = 1
          AND gate.generation = NEW.gate_generation
     )
)
BEGIN SELECT RAISE(ABORT, 'notification history page requires current lease'); END;

-- Each page names the already-durable normalized notification facts it is
-- checkpointing.  This is a receipt, not a second notification copy: UUID and
-- payload hash must resolve to the immutable event ledger, and no raw JWS is
-- retained.  A UUID may appear only once in a recovery generation.
CREATE TABLE billing_apple_notification_history_page_records (
    generation INTEGER NOT NULL,
    page_index INTEGER NOT NULL,
    record_index INTEGER NOT NULL CHECK (record_index BETWEEN 0 AND 19),
    notification_uuid TEXT NOT NULL
      REFERENCES billing_apple_notification_events(notification_uuid) ON DELETE RESTRICT,
    payload_hash TEXT NOT NULL CHECK (
      length(payload_hash) = 43 AND payload_hash NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    PRIMARY KEY (generation, page_index, record_index),
    UNIQUE (generation, notification_uuid),
    UNIQUE (generation, payload_hash),
    FOREIGN KEY (generation, page_index)
      REFERENCES billing_apple_notification_history_page_commits(generation, page_index)
      ON DELETE RESTRICT
) STRICT;

CREATE TRIGGER billing_apple_notification_history_page_record_requires_event
BEFORE INSERT ON billing_apple_notification_history_page_records
WHEN NOT EXISTS (
  SELECT 1
    FROM billing_apple_notification_history_page_commits AS page
    JOIN billing_apple_notification_history_recovery AS recovery
      ON recovery.singleton = 1
     AND recovery.generation = page.generation
    JOIN billing_apple_notification_events AS event
      ON event.notification_uuid = NEW.notification_uuid
     AND event.payload_hash = NEW.payload_hash
   WHERE page.generation = NEW.generation
     AND page.page_index = NEW.page_index
     AND NEW.record_index < page.record_count
     AND event.environment = recovery.store_environment
     AND event.signed_date_ms BETWEEN recovery.frozen_start_date_ms
                                  AND recovery.frozen_end_date_ms
     AND (
       event.relevance <> 'linked'
       OR EXISTS (
         SELECT 1
           FROM billing_apple_notification_reconciliation_causes AS cause
          WHERE cause.notification_uuid = event.notification_uuid
            AND cause.original_transaction_id = event.original_transaction_id
       )
     )
)
BEGIN SELECT RAISE(ABORT, 'notification history page record requires durable event'); END;

-- Finalization is deliberately a second insert after the state UPDATE. If the
-- UPDATE matched zero rows because the lease/gate/generation became stale, this
-- trigger aborts the whole D1 batch, including every normalized event/cause
-- write and the page-guard row.
CREATE TABLE billing_apple_notification_history_page_finalizations (
    generation INTEGER NOT NULL,
    page_index INTEGER NOT NULL,
    finalized_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (generation, page_index),
    FOREIGN KEY (generation, page_index)
      REFERENCES billing_apple_notification_history_page_commits(generation, page_index)
      ON DELETE RESTRICT
) STRICT;

CREATE TRIGGER billing_apple_notification_history_page_finalize_requires_advance
BEFORE INSERT ON billing_apple_notification_history_page_finalizations
WHEN NOT EXISTS (
  SELECT 1
    FROM billing_apple_notification_history_page_commits AS page
    JOIN billing_apple_notification_history_recovery AS recovery
      ON recovery.singleton = 1
    JOIN billing_runtime_gate AS gate ON gate.singleton = 1
   WHERE page.generation = NEW.generation
     AND page.page_index = NEW.page_index
     AND recovery.generation = page.generation
     AND recovery.committed_page_count = page.page_index
     AND recovery.lease_token IS NULL
     AND recovery.lease_expires_at IS NULL
     AND recovery.claimed_gate_generation IS NULL
     AND recovery.state = (CASE WHEN page.has_more = 1 THEN 'ready' ELSE 'completed' END)
     AND (
       SELECT COUNT(*)
         FROM billing_apple_notification_history_page_records AS record
        WHERE record.generation = page.generation
          AND record.page_index = page.page_index
     ) = page.record_count
     AND gate.apple_notification_history_recovery_enabled = 1
     AND gate.generation = page.gate_generation
)
BEGIN SELECT RAISE(ABORT, 'notification history page advance was not finalized'); END;

-- Generation changes are reserved for a new frozen run or a bounded cursor
-- restart.  Within a generation the app identity and frozen interval cannot be
-- rewritten, and only a claimed lease can advance or fail the job.
CREATE TRIGGER billing_apple_notification_history_recovery_requires_transition
BEFORE UPDATE ON billing_apple_notification_history_recovery
WHEN NEW.updated_at <> unixepoch()
  OR NOT (
    (
      OLD.state IN ('idle', 'completed', 'blocked')
      AND NEW.state = 'ready'
      AND NEW.generation = OLD.generation + 1
      AND NEW.committed_page_count = 0 AND NEW.committed_record_count = 0
      AND NEW.cursor_reset_count = 0 AND NEW.pagination_cursor IS NULL
    )
    OR
    (
      OLD.state IN ('ready', 'retry_wait')
      AND NEW.state = 'leased'
      AND NEW.generation = OLD.generation
      AND NEW.store_environment IS OLD.store_environment
      AND NEW.bundle_id IS OLD.bundle_id
      AND NEW.frozen_start_date_ms IS OLD.frozen_start_date_ms
      AND NEW.frozen_end_date_ms IS OLD.frozen_end_date_ms
      AND NEW.pagination_cursor IS OLD.pagination_cursor
      AND NEW.committed_page_count = OLD.committed_page_count
      AND NEW.committed_record_count = OLD.committed_record_count
      AND NEW.cursor_reset_count = OLD.cursor_reset_count
    )
    OR
    (
      OLD.state = 'leased'
      AND NEW.state IN ('ready', 'retry_wait', 'completed', 'blocked')
      AND NEW.generation = OLD.generation
      AND NEW.store_environment IS OLD.store_environment
      AND NEW.bundle_id IS OLD.bundle_id
      AND NEW.frozen_start_date_ms IS OLD.frozen_start_date_ms
      AND NEW.frozen_end_date_ms IS OLD.frozen_end_date_ms
      AND NEW.cursor_reset_count = OLD.cursor_reset_count
      AND (
        (
          NEW.committed_page_count = OLD.committed_page_count + 1
          AND NEW.committed_record_count BETWEEN OLD.committed_record_count
            AND OLD.committed_record_count + 20
          AND NEW.state IN ('ready', 'completed')
          AND EXISTS (
            SELECT 1
              FROM billing_apple_notification_history_page_commits AS page
             WHERE page.generation = NEW.generation
               AND page.page_index = NEW.committed_page_count
               AND page.lease_token = OLD.lease_token
               AND page.record_count = NEW.committed_record_count - OLD.committed_record_count
               AND page.has_more = (CASE WHEN NEW.state = 'ready' THEN 1 ELSE 0 END)
          )
        )
        OR
        (
          NEW.committed_page_count = OLD.committed_page_count
          AND NEW.committed_record_count = OLD.committed_record_count
          AND NEW.pagination_cursor IS OLD.pagination_cursor
          AND NEW.state IN ('ready', 'retry_wait', 'blocked')
        )
      )
    )
    OR
    (
      OLD.state = 'leased'
      AND NEW.state = 'ready'
      AND NEW.generation = OLD.generation + 1
      AND NEW.store_environment IS OLD.store_environment
      AND NEW.bundle_id IS OLD.bundle_id
      AND NEW.frozen_start_date_ms IS OLD.frozen_start_date_ms
      AND NEW.frozen_end_date_ms IS OLD.frozen_end_date_ms
      AND NEW.pagination_cursor IS NULL
      AND NEW.committed_page_count = 0 AND NEW.committed_record_count = 0
      AND NEW.cursor_reset_count = OLD.cursor_reset_count + 1
    )
  )
BEGIN SELECT RAISE(ABORT, 'invalid notification history recovery transition'); END;

CREATE TRIGGER billing_apple_notification_history_recovery_cannot_be_deleted
BEFORE DELETE ON billing_apple_notification_history_recovery
BEGIN SELECT RAISE(ABORT, 'notification history recovery cannot be deleted'); END;

CREATE TRIGGER billing_apple_notification_history_page_commits_are_immutable
BEFORE UPDATE ON billing_apple_notification_history_page_commits
BEGIN SELECT RAISE(ABORT, 'notification history page commits are immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_commits_cannot_be_deleted
BEFORE DELETE ON billing_apple_notification_history_page_commits
BEGIN SELECT RAISE(ABORT, 'notification history page commits cannot be deleted'); END;

CREATE TRIGGER billing_apple_notification_history_page_records_are_immutable
BEFORE UPDATE ON billing_apple_notification_history_page_records
BEGIN SELECT RAISE(ABORT, 'notification history page records are immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_records_cannot_be_deleted
BEFORE DELETE ON billing_apple_notification_history_page_records
BEGIN SELECT RAISE(ABORT, 'notification history page records cannot be deleted'); END;

CREATE TRIGGER billing_apple_notification_history_page_finalizations_are_immutable
BEFORE UPDATE ON billing_apple_notification_history_page_finalizations
BEGIN SELECT RAISE(ABORT, 'notification history page finalizations are immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_finalizations_cannot_be_deleted
BEFORE DELETE ON billing_apple_notification_history_page_finalizations
BEGIN SELECT RAISE(ABORT, 'notification history page finalizations cannot be deleted'); END;
