PRAGMA foreign_keys = ON;

-- Keep this migration LF-only; Wrangler remote trigger parsing rejects CRLF.
-- Keep every conditional expression parenthesized; remote trigger parsing can misread bare forms.

-- ADR-015 uses append-only moments. These tables deliberately do not reuse
-- the Phase 2 daily generation/current tables from ADR-009.

-- The legacy pairing API remains intentionally limited to one owner/invitee.
-- Future members are represented independently below rather than weakening a
-- v1 invariant before its enrollment/status API can represent them safely.

-- A lineage survives deletion of a concrete space. It is the durable home for
-- the one-time bootstrap grant and must never be cascaded with photo metadata.
CREATE TABLE moment_space_lineages (
    id TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    initial_bootstrap_consumed_at INTEGER,
    bootstrap_request_hash TEXT,
    CHECK (
      (initial_bootstrap_consumed_at IS NULL) = (bootstrap_request_hash IS NULL)
    )
) STRICT;

CREATE TABLE moment_spaces (
    space_id TEXT PRIMARY KEY,
    lineage_id TEXT NOT NULL REFERENCES moment_space_lineages(id),
    state TEXT NOT NULL CHECK (state IN ('active', 'revoked')),
    current_key_epoch INTEGER NOT NULL DEFAULT 1 CHECK (current_key_epoch > 0),
    membership_revision INTEGER NOT NULL DEFAULT 1 CHECK (membership_revision > 0),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    revoked_at INTEGER
) STRICT;

CREATE TABLE moment_participants (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES moment_spaces(space_id) ON DELETE CASCADE,
    legacy_member_id TEXT UNIQUE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'member')),
    state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'revoked', 'expired')),
    created_at INTEGER NOT NULL,
    activated_at INTEGER,
    revoked_at INTEGER,
    report_only_until INTEGER
) STRICT;

CREATE INDEX moment_participants_space_state
    ON moment_participants(space_id, state, id);

-- A participant can own more than one device. Legacy member rows bridge to a
-- one-participant/one-device shape without constraining the future model.
CREATE TABLE moment_devices (
    id TEXT PRIMARY KEY,
    participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    legacy_member_id TEXT UNIQUE,
    agreement_public_key TEXT NOT NULL,
    signing_public_key TEXT NOT NULL,
    attestation_key_id TEXT,
    state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'revoked', 'expired')),
    created_at INTEGER NOT NULL,
    activated_at INTEGER,
    revoked_at INTEGER,
    report_only_until INTEGER
) STRICT;

CREATE INDEX moment_devices_participant_state
    ON moment_devices(participant_id, state, id);

CREATE TABLE moment_sender_policy_acceptances (
    participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    policy_version INTEGER NOT NULL CHECK (policy_version > 0),
    accepted_at INTEGER NOT NULL,
    recorded_at INTEGER NOT NULL,
    PRIMARY KEY (participant_id, policy_version)
) STRICT;

CREATE TABLE moment_storage_scopes (
    space_id TEXT PRIMARY KEY REFERENCES moment_spaces(space_id) ON DELETE CASCADE,
    object_prefix TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    moment_empty_sweep_started_at INTEGER,
    moment_sweep_completed_at INTEGER,
    report_empty_sweep_started_at INTEGER,
    report_sweep_completed_at INTEGER,
    last_sweep_at INTEGER,
    sweep_count INTEGER NOT NULL DEFAULT 0 CHECK (sweep_count >= 0)
) STRICT;

CREATE TABLE moments (
    id TEXT PRIMARY KEY,
    client_moment_id TEXT NOT NULL,
    space_id TEXT NOT NULL REFERENCES moment_spaces(space_id) ON DELETE CASCADE,
    sender_participant_id TEXT NOT NULL REFERENCES moment_participants(id),
    sender_device_id TEXT NOT NULL REFERENCES moment_devices(id),
    kind TEXT NOT NULL CHECK (kind IN ('live', 'memory', 'bootstrap')),
    key_epoch INTEGER NOT NULL CHECK (key_epoch > 0),
    state TEXT NOT NULL CHECK (
      state IN ('reserved', 'uploaded', 'committed', 'expired', 'deleted')
    ),
    object_key TEXT NOT NULL UNIQUE,
    ciphertext_size INTEGER NOT NULL CHECK (ciphertext_size BETWEEN 29 AND 1048576),
    ciphertext_sha256 TEXT NOT NULL,
    client_moderation_version INTEGER NOT NULL CHECK (client_moderation_version > 0),
    sender_policy_version INTEGER NOT NULL CHECK (sender_policy_version > 0),
    sender_policy_accepted_at INTEGER NOT NULL,
    quota_day_key INTEGER NOT NULL,
    quota_counted INTEGER NOT NULL CHECK (quota_counted IN (0, 1)),
    reservation_attempt INTEGER NOT NULL CHECK (reservation_attempt BETWEEN 1 AND 3),
    reserve_request_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    upload_expires_at INTEGER NOT NULL,
    uploaded_at INTEGER,
    committed_at INTEGER,
    unreceived_expires_at INTEGER,
    closed_at INTEGER,
    CHECK (upload_expires_at > created_at),
    CHECK (upload_expires_at <= created_at + 3600),
    CHECK (
      (state = 'reserved' AND uploaded_at IS NULL AND committed_at IS NULL)
      OR (state = 'uploaded' AND uploaded_at IS NOT NULL AND committed_at IS NULL)
      OR (state = 'committed' AND uploaded_at IS NOT NULL AND committed_at IS NOT NULL
          AND unreceived_expires_at IS NOT NULL)
      OR (state IN ('expired', 'deleted') AND closed_at IS NOT NULL)
    )
) STRICT;

-- A client may recover an upload draft after its one-hour reservation expires,
-- but an active or ever-committed logical moment remains unique. The logical
-- send consumes quota once; at most two replacement reservations are allowed.
CREATE UNIQUE INDEX moments_one_live_client_moment
    ON moments(sender_device_id, client_moment_id)
    WHERE state IN ('reserved', 'uploaded', 'committed') OR committed_at IS NOT NULL;

CREATE INDEX moments_sender_day_state
    ON moments(sender_participant_id, quota_day_key, state, id);

CREATE INDEX moments_upload_expiry
    ON moments(upload_expires_at, id)
    WHERE state IN ('reserved', 'uploaded');

CREATE INDEX moments_committed_state
    ON moments(state, committed_at, id);

CREATE TABLE moment_commit_events (
    id TEXT PRIMARY KEY,
    moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    sender_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    expected_key_epoch INTEGER NOT NULL,
    expected_membership_revision INTEGER NOT NULL,
    committed_at INTEGER NOT NULL,
    unreceived_expires_at INTEGER NOT NULL
) STRICT;

CREATE TABLE moment_daily_usage (
    participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    day_key INTEGER NOT NULL,
    reserved_count INTEGER NOT NULL DEFAULT 0 CHECK (reserved_count >= 0),
    committed_count INTEGER NOT NULL DEFAULT 0 CHECK (committed_count >= 0),
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (participant_id, day_key),
    CHECK (reserved_count + committed_count <= 5)
) STRICT;

CREATE TABLE moment_deliveries (
    moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    recipient_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'expired', 'revoked')),
    created_at INTEGER NOT NULL,
    access_expires_at INTEGER NOT NULL,
    acknowledged_at INTEGER,
    revoked_at INTEGER,
    PRIMARY KEY (moment_id, recipient_participant_id),
    CHECK (
      (state = 'pending' AND acknowledged_at IS NULL AND revoked_at IS NULL)
      OR (state = 'acknowledged' AND acknowledged_at IS NOT NULL AND revoked_at IS NULL)
      OR (state = 'expired')
      OR (state = 'revoked' AND revoked_at IS NOT NULL)
    )
) STRICT;

CREATE INDEX moment_deliveries_recipient_state
    ON moment_deliveries(recipient_participant_id, state, access_expires_at, moment_id);

CREATE INDEX moment_deliveries_expiry
    ON moment_deliveries(access_expires_at, moment_id, recipient_participant_id)
    WHERE state IN ('pending', 'acknowledged');

-- Mutation event tables let a validation trigger and its state change live in
-- the same D1 transaction as nonce/idempotency records. Callers remove the
-- event row in that same batch after the trigger has applied it.
CREATE TABLE moment_ack_events (
    id TEXT PRIMARY KEY,
    moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    recipient_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    ciphertext_sha256 TEXT NOT NULL,
    acknowledged_at INTEGER NOT NULL,
    access_expires_at INTEGER NOT NULL
) STRICT;

-- A random cursor is exposed to clients; the monotonic sequence remains an
-- internal ordering key and is scoped again by participant on lookup.
CREATE TABLE moment_changes (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    cursor TEXT NOT NULL UNIQUE,
    participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    change_type TEXT NOT NULL CHECK (
      change_type IN ('moment_committed', 'delivery_revoked')
    ),
    moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL
) STRICT;

CREATE INDEX moment_changes_participant_sequence
    ON moment_changes(participant_id, sequence);

CREATE TABLE moment_blocks (
    space_id TEXT NOT NULL REFERENCES moment_spaces(space_id) ON DELETE CASCADE,
    blocker_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    blocked_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    state TEXT NOT NULL CHECK (state = 'active'),
    created_key_epoch INTEGER NOT NULL CHECK (created_key_epoch > 1),
    created_at INTEGER NOT NULL,
    PRIMARY KEY (blocker_participant_id, blocked_participant_id),
    CHECK (blocker_participant_id <> blocked_participant_id)
) STRICT;

CREATE INDEX moment_blocks_space
    ON moment_blocks(space_id, state, blocker_participant_id, blocked_participant_id);

-- Report ciphertext is a separately encrypted copy for the moderation public
-- key. The normal room/server keys are neither stored here nor usable by the
-- Worker to decrypt it.
CREATE TABLE moment_reports (
    id TEXT PRIMARY KEY,
    moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    space_id TEXT NOT NULL REFERENCES moment_spaces(space_id) ON DELETE CASCADE,
    lineage_id TEXT NOT NULL REFERENCES moment_space_lineages(id),
    reporter_participant_id TEXT NOT NULL REFERENCES moment_participants(id),
    reporter_device_id TEXT NOT NULL REFERENCES moment_devices(id),
    accused_participant_id TEXT NOT NULL REFERENCES moment_participants(id),
    reason_code TEXT NOT NULL CHECK (
      reason_code IN ('objectionable', 'harassment', 'privacy', 'other')
    ),
    moderation_key_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('reserved', 'uploaded', 'committed', 'expired', 'deleted')),
    object_key TEXT NOT NULL UNIQUE,
    ciphertext_size INTEGER NOT NULL CHECK (ciphertext_size BETWEEN 29 AND 1048576),
    ciphertext_sha256 TEXT NOT NULL,
    reporter_consent_version INTEGER NOT NULL CHECK (reporter_consent_version > 0),
    reporter_consented_at INTEGER NOT NULL,
    quota_day_key INTEGER NOT NULL,
    reserve_request_hash TEXT NOT NULL,
    dedupe_key TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    upload_expires_at INTEGER NOT NULL,
    uploaded_at INTEGER,
    committed_at INTEGER,
    content_expires_at INTEGER,
    closed_at INTEGER,
    CHECK (reporter_participant_id <> accused_participant_id),
    CHECK (upload_expires_at > created_at),
    CHECK (upload_expires_at <= created_at + 3600),
    CHECK (
      (state = 'reserved' AND uploaded_at IS NULL AND committed_at IS NULL)
      OR (state = 'uploaded' AND uploaded_at IS NOT NULL AND committed_at IS NULL)
      OR (state = 'committed' AND uploaded_at IS NOT NULL AND committed_at IS NOT NULL
          AND content_expires_at IS NOT NULL)
      OR (state IN ('expired', 'deleted') AND closed_at IS NOT NULL)
    )
) STRICT;

CREATE INDEX moment_reports_upload_expiry
    ON moment_reports(upload_expires_at, id)
    WHERE state IN ('reserved', 'uploaded');

CREATE INDEX moment_reports_content_expiry
    ON moment_reports(content_expires_at, id)
    WHERE state = 'committed';

-- Minimal moderation/dedupe evidence survives eventual deletion of the
-- concrete v2 space. No photo object key, ciphertext hash, device key, capture
-- time or participant identifier is copied into this lineage tombstone.
CREATE TABLE moment_report_tombstones (
    report_id TEXT PRIMARY KEY,
    lineage_id TEXT NOT NULL REFERENCES moment_space_lineages(id),
    dedupe_key TEXT NOT NULL UNIQUE,
    moderation_key_id TEXT NOT NULL,
    reason_code TEXT NOT NULL CHECK (
      reason_code IN ('objectionable', 'harassment', 'privacy', 'other')
    ),
    committed_at INTEGER NOT NULL,
    content_expires_at INTEGER NOT NULL,
    content_deleted_at INTEGER
) STRICT;

CREATE INDEX moment_report_tombstones_lineage
    ON moment_report_tombstones(lineage_id, committed_at, report_id);

CREATE TABLE moment_report_daily_usage (
    participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    day_key INTEGER NOT NULL,
    attempt_count INTEGER NOT NULL CHECK (attempt_count BETWEEN 0 AND 10),
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (participant_id, day_key)
) STRICT;

-- Report-only credentials intentionally survive deletion of the legacy
-- pairing rows. They cannot authenticate any non-report endpoint.
CREATE TABLE moment_report_request_nonces (
    device_id TEXT NOT NULL REFERENCES moment_devices(id) ON DELETE CASCADE,
    nonce TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (device_id, nonce)
) STRICT;

CREATE INDEX moment_report_request_nonces_expiry
    ON moment_report_request_nonces(expires_at);

CREATE TABLE moment_report_idempotency_records (
    operation TEXT NOT NULL,
    actor_device_id TEXT NOT NULL REFERENCES moment_devices(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    lineage_id TEXT NOT NULL REFERENCES moment_space_lineages(id),
    request_hash TEXT NOT NULL,
    response_status INTEGER NOT NULL,
    response_json TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (operation, actor_device_id, client_request_id),
    CHECK (expires_at > created_at)
) STRICT;

CREATE INDEX moment_report_idempotency_expiry
    ON moment_report_idempotency_records(expires_at);

-- One live/full report per reporter/moment prevents duplicate moderation work.
-- An upload that never committed may expire and be replaced by a fresh attempt;
-- after bounded full-row retention a non-reversible opaque-ID digest in the
-- minimal tombstone remains the durable dedupe key.
CREATE UNIQUE INDEX moment_reports_one_durable_report
    ON moment_reports(moment_id, reporter_participant_id)
    WHERE state IN ('reserved', 'uploaded', 'committed') OR committed_at IS NOT NULL;

CREATE TABLE moment_report_commit_events (
    id TEXT PRIMARY KEY,
    report_id TEXT NOT NULL REFERENCES moment_reports(id) ON DELETE CASCADE,
    reporter_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    committed_at INTEGER NOT NULL,
    content_expires_at INTEGER NOT NULL
) STRICT;

CREATE TABLE moment_object_deletions (
    object_key TEXT PRIMARY KEY,
    object_type TEXT NOT NULL CHECK (object_type IN ('moment', 'report')),
    owner_id TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'deleted')),
    not_before INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    created_at INTEGER NOT NULL,
    deleted_at INTEGER
) STRICT;

CREATE INDEX moment_object_deletions_pending
    ON moment_object_deletions(state, not_before, created_at, object_key);

-- Logical-send quota is counted on the first reserve and never released within
-- that UTC day. Exact replacement reservations carry quota_counted=0 and retain
-- the original day key; the row-level attempt cap bounds R2/D1 retry abuse.
CREATE TRIGGER moments_require_live_sender_and_quota
BEFORE INSERT ON moments
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moment_spaces AS ms
        JOIN moment_participants AS p ON p.space_id = ms.space_id
        JOIN moment_devices AS d ON d.participant_id = p.id
       WHERE ms.space_id = NEW.space_id
         AND ms.state = 'active'
         AND ms.current_key_epoch = NEW.key_epoch
         AND p.id = NEW.sender_participant_id
         AND p.state = 'active'
         AND d.id = NEW.sender_device_id
         AND d.state = 'active'
    ) THEN RAISE(ABORT, 'moment sender is not active') END);
    SELECT (CASE WHEN NEW.kind <> 'bootstrap' AND NEW.quota_counted = 1 AND COALESCE((
      SELECT reserved_count + committed_count
        FROM moment_daily_usage
       WHERE participant_id = NEW.sender_participant_id
         AND day_key = NEW.quota_day_key
    ), 0) >= 5 THEN RAISE(ABORT, 'moment daily quota exceeded') END);
END;

CREATE TRIGGER moments_hold_daily_quota
AFTER INSERT ON moments
WHEN NEW.kind <> 'bootstrap' AND NEW.quota_counted = 1
BEGIN
    INSERT INTO moment_daily_usage(
      participant_id, day_key, reserved_count, committed_count, updated_at
    ) VALUES (NEW.sender_participant_id, NEW.quota_day_key, 1, 0, NEW.created_at)
    ON CONFLICT(participant_id, day_key) DO UPDATE SET
      reserved_count = moment_daily_usage.reserved_count + 1,
      updated_at = excluded.updated_at;
END;

CREATE TRIGGER moments_validate_state_transition
BEFORE UPDATE OF state ON moments
WHEN NOT (
  (OLD.state = 'reserved' AND NEW.state IN ('uploaded', 'expired'))
  OR (OLD.state = 'uploaded' AND NEW.state IN ('committed', 'expired'))
  OR (OLD.state = 'committed' AND NEW.state = 'expired')
  OR (OLD.state = 'expired' AND NEW.state = 'deleted')
  OR (OLD.state = NEW.state)
)
BEGIN
    SELECT RAISE(ABORT, 'invalid moment state transition');
END;

CREATE TRIGGER moments_commit_daily_quota
AFTER UPDATE OF state ON moments
WHEN OLD.state = 'uploaded' AND NEW.state = 'committed' AND NEW.kind <> 'bootstrap'
BEGIN
    UPDATE moment_daily_usage
       SET reserved_count = reserved_count - 1,
           committed_count = committed_count + 1,
           updated_at = NEW.committed_at
     WHERE participant_id = NEW.sender_participant_id
       AND day_key = NEW.quota_day_key
       AND reserved_count > 0;
END;

CREATE TRIGGER moment_commit_events_validate
BEFORE INSERT ON moment_commit_events
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moments AS moment
        JOIN moment_spaces AS space ON space.space_id = moment.space_id
        JOIN moment_participants AS sender
          ON sender.id = moment.sender_participant_id
        JOIN moment_devices AS device
          ON device.id = moment.sender_device_id
       WHERE moment.id = NEW.moment_id
         AND moment.sender_participant_id = NEW.sender_participant_id
         AND moment.state = 'uploaded'
         AND moment.upload_expires_at > NEW.committed_at
         AND moment.key_epoch = NEW.expected_key_epoch
         AND space.state = 'active'
         AND space.current_key_epoch = NEW.expected_key_epoch
         AND space.membership_revision = NEW.expected_membership_revision
         AND sender.state = 'active'
         AND device.state = 'active'
    ) THEN RAISE(ABORT, 'moment cannot be committed') END);
END;

CREATE TRIGGER moments_require_active_upload
BEFORE UPDATE OF state ON moments
WHEN OLD.state = 'reserved' AND NEW.state = 'uploaded'
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moment_spaces AS space
        JOIN moment_participants AS sender
          ON sender.id = OLD.sender_participant_id
        JOIN moment_devices AS device
          ON device.id = OLD.sender_device_id
       WHERE space.space_id = OLD.space_id AND space.state = 'active'
         AND sender.state = 'active' AND device.state = 'active'
    ) THEN RAISE(ABORT, 'moment upload sender is not active') END);
END;

CREATE TRIGGER moment_commit_events_apply
AFTER INSERT ON moment_commit_events
BEGIN
    UPDATE moments
       SET state = 'committed', committed_at = NEW.committed_at,
           unreceived_expires_at = NEW.unreceived_expires_at
     WHERE id = NEW.moment_id AND state = 'uploaded';
END;

CREATE TRIGGER moment_participants_increment_membership_on_insert
AFTER INSERT ON moment_participants
BEGIN
    UPDATE moment_spaces
       SET membership_revision = membership_revision + 1,
           updated_at = MAX(updated_at, NEW.created_at)
     WHERE space_id = NEW.space_id;
END;

CREATE TRIGGER moment_participants_increment_membership_on_state
AFTER UPDATE OF state ON moment_participants
WHEN OLD.state <> NEW.state
BEGIN
    UPDATE moment_spaces
       SET membership_revision = membership_revision + 1,
           updated_at = MAX(updated_at, COALESCE(NEW.revoked_at, NEW.activated_at, NEW.created_at))
     WHERE space_id = NEW.space_id;
END;

CREATE TRIGGER moment_devices_increment_membership_on_insert
AFTER INSERT ON moment_devices
BEGIN
    UPDATE moment_spaces
       SET membership_revision = membership_revision + 1,
           updated_at = MAX(updated_at, NEW.created_at)
     WHERE space_id = (
       SELECT space_id FROM moment_participants WHERE id = NEW.participant_id
     );
END;

CREATE TRIGGER moment_devices_increment_membership_on_state
AFTER UPDATE OF state ON moment_devices
WHEN OLD.state <> NEW.state
BEGIN
    UPDATE moment_spaces
       SET membership_revision = membership_revision + 1,
           updated_at = MAX(updated_at, COALESCE(NEW.revoked_at, NEW.activated_at, NEW.created_at))
     WHERE space_id = (
       SELECT space_id FROM moment_participants WHERE id = NEW.participant_id
     );
END;

-- Delivery rows are a commit-time authorization snapshot.  A participant
-- added later must not gain access to old ciphertext, and either direction of
-- an active block prevents a new delivery from being minted.
CREATE TRIGGER moment_deliveries_validate_insert
BEFORE INSERT ON moment_deliveries
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moments AS m
        JOIN moment_participants AS recipient
          ON recipient.id = NEW.recipient_participant_id
       WHERE m.id = NEW.moment_id
         AND m.state = 'committed'
         AND recipient.space_id = m.space_id
         AND recipient.state = 'active'
         AND recipient.id <> m.sender_participant_id
         AND EXISTS (
           SELECT 1 FROM moment_devices AS device
            WHERE device.participant_id = recipient.id AND device.state = 'active'
         )
         AND NOT EXISTS (
           SELECT 1 FROM moment_blocks AS b
            WHERE b.space_id = m.space_id AND b.state = 'active'
              AND (
                (b.blocker_participant_id = m.sender_participant_id
                 AND b.blocked_participant_id = recipient.id)
                OR
                (b.blocker_participant_id = recipient.id
                 AND b.blocked_participant_id = m.sender_participant_id)
              )
         )
    ) THEN RAISE(ABORT, 'moment recipient is not eligible') END);
END;

CREATE TRIGGER moment_deliveries_validate_state_transition
BEFORE UPDATE OF state ON moment_deliveries
WHEN NOT (
  (OLD.state = 'pending' AND NEW.state IN ('acknowledged', 'expired', 'revoked'))
  OR (OLD.state = 'acknowledged' AND NEW.state IN ('expired', 'revoked'))
  OR (OLD.state = NEW.state)
)
BEGIN
    SELECT RAISE(ABORT, 'invalid delivery state transition');
END;

CREATE TRIGGER moment_ack_events_validate
BEFORE INSERT ON moment_ack_events
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moment_deliveries AS delivery
        JOIN moments AS m ON m.id = delivery.moment_id
        JOIN moment_participants AS recipient
          ON recipient.id = delivery.recipient_participant_id
       WHERE delivery.moment_id = NEW.moment_id
         AND delivery.recipient_participant_id = NEW.recipient_participant_id
         AND delivery.state IN ('pending', 'acknowledged')
         AND delivery.access_expires_at > NEW.acknowledged_at
         AND m.state = 'committed'
         AND m.ciphertext_sha256 = NEW.ciphertext_sha256
         AND recipient.state = 'active'
         AND NOT EXISTS (
           SELECT 1 FROM moment_blocks AS b
            WHERE b.space_id = m.space_id AND b.state = 'active'
              AND (
                (b.blocker_participant_id = m.sender_participant_id
                 AND b.blocked_participant_id = recipient.id)
                OR
                (b.blocker_participant_id = recipient.id
                 AND b.blocked_participant_id = m.sender_participant_id)
              )
         )
    ) THEN RAISE(ABORT, 'delivery cannot be acknowledged') END);
END;

CREATE TRIGGER moment_ack_events_apply
AFTER INSERT ON moment_ack_events
BEGIN
    UPDATE moment_deliveries
       SET state = 'acknowledged',
           acknowledged_at = COALESCE(acknowledged_at, NEW.acknowledged_at),
           access_expires_at = MIN(access_expires_at, NEW.access_expires_at)
     WHERE moment_id = NEW.moment_id
       AND recipient_participant_id = NEW.recipient_participant_id
       AND state IN ('pending', 'acknowledged');
END;

CREATE TRIGGER moment_reports_require_authorized_reporter
BEFORE INSERT ON moment_reports
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moments AS m
        JOIN moment_participants AS reporter
          ON reporter.id = NEW.reporter_participant_id
        JOIN moment_devices AS device
          ON device.id = NEW.reporter_device_id
         AND device.participant_id = reporter.id
       WHERE m.id = NEW.moment_id
         AND m.space_id = NEW.space_id
         AND NEW.lineage_id = (
           SELECT lineage_id FROM moment_spaces WHERE space_id = NEW.space_id
         )
         AND m.sender_participant_id = NEW.accused_participant_id
         AND reporter.space_id = m.space_id
         AND (
           reporter.state = 'active'
           OR (reporter.state IN ('revoked', 'expired')
               AND reporter.report_only_until > NEW.created_at)
         )
         AND (
           device.state = 'active'
           OR (device.state IN ('revoked', 'expired')
               AND device.report_only_until > NEW.created_at)
         )
         AND EXISTS (
           SELECT 1 FROM moment_deliveries AS delivery
            WHERE delivery.moment_id = m.id
              AND delivery.recipient_participant_id = reporter.id
         )
    ) THEN RAISE(ABORT, 'reporter is not authorized') END);
    SELECT (CASE WHEN COALESCE((
      SELECT attempt_count FROM moment_report_daily_usage
       WHERE participant_id = NEW.reporter_participant_id
         AND day_key = NEW.quota_day_key
    ), 0) >= 10 THEN RAISE(ABORT, 'report daily quota exceeded') END);
END;

CREATE TRIGGER moment_reports_hold_daily_quota
AFTER INSERT ON moment_reports
BEGIN
    INSERT INTO moment_report_daily_usage(
      participant_id, day_key, attempt_count, updated_at
    ) VALUES (NEW.reporter_participant_id, NEW.quota_day_key, 1, NEW.created_at)
    ON CONFLICT(participant_id, day_key) DO UPDATE SET
      attempt_count = moment_report_daily_usage.attempt_count + 1,
      updated_at = excluded.updated_at;
END;

-- A report-only request can have authenticated just before its 24-hour window
-- closes. If it arrives after an empty-prefix proof, invalidate that proof so
-- terminal space cleanup cannot race and orphan the newly accepted object.
CREATE TRIGGER moment_reports_reset_report_sweep
AFTER INSERT ON moment_reports
BEGIN
    UPDATE moment_storage_scopes
       SET report_empty_sweep_started_at = NULL,
           report_sweep_completed_at = NULL
     WHERE space_id = NEW.space_id;
END;

CREATE TRIGGER moment_reports_validate_state_transition
BEFORE UPDATE OF state ON moment_reports
WHEN NOT (
  (OLD.state = 'reserved' AND NEW.state IN ('uploaded', 'expired'))
  OR (OLD.state = 'uploaded' AND NEW.state IN ('committed', 'expired'))
  OR (OLD.state = 'committed' AND NEW.state = 'expired')
  OR (OLD.state = 'expired' AND NEW.state = 'deleted')
  OR (OLD.state = NEW.state)
)
BEGIN
    SELECT RAISE(ABORT, 'invalid report state transition');
END;

CREATE TRIGGER moment_reports_require_active_upload
BEFORE UPDATE OF state ON moment_reports
WHEN OLD.state = 'reserved' AND NEW.state = 'uploaded'
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moment_spaces AS space
        JOIN moment_participants AS reporter
          ON reporter.id = OLD.reporter_participant_id
        JOIN moment_devices AS device
          ON device.id = OLD.reporter_device_id
       WHERE space.space_id = OLD.space_id
         AND (
           reporter.state = 'active'
           OR (reporter.state IN ('revoked', 'expired')
               AND reporter.report_only_until > COALESCE(NEW.uploaded_at, 0))
         )
         AND (
           device.state = 'active'
           OR (device.state IN ('revoked', 'expired')
               AND device.report_only_until > COALESCE(NEW.uploaded_at, 0))
         )
    ) THEN RAISE(ABORT, 'report upload reporter is not active') END);
END;

CREATE TRIGGER moment_report_commit_events_validate
BEFORE INSERT ON moment_report_commit_events
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moment_reports AS report
        JOIN moment_participants AS reporter
          ON reporter.id = report.reporter_participant_id
        JOIN moment_devices AS device
          ON device.id = report.reporter_device_id
       WHERE report.id = NEW.report_id
         AND report.reporter_participant_id = NEW.reporter_participant_id
         AND report.state = 'uploaded'
         AND report.upload_expires_at > NEW.committed_at
         AND (
           reporter.state = 'active'
           OR (reporter.state IN ('revoked', 'expired')
               AND reporter.report_only_until > NEW.committed_at)
         )
         AND (
           device.state = 'active'
           OR (device.state IN ('revoked', 'expired')
               AND device.report_only_until > NEW.committed_at)
         )
    ) THEN RAISE(ABORT, 'report cannot be committed') END);
END;

CREATE TRIGGER moment_report_commit_events_apply
AFTER INSERT ON moment_report_commit_events
BEGIN
    UPDATE moment_reports
       SET state = 'committed', committed_at = NEW.committed_at,
           content_expires_at = NEW.content_expires_at
     WHERE id = NEW.report_id AND state = 'uploaded';
END;

CREATE TRIGGER moment_reports_create_tombstone
AFTER UPDATE OF state ON moment_reports
WHEN OLD.state = 'uploaded' AND NEW.state = 'committed'
BEGIN
    INSERT INTO moment_report_tombstones(
      report_id, lineage_id, dedupe_key, moderation_key_id, reason_code,
      committed_at, content_expires_at
    ) VALUES (
      NEW.id, NEW.lineage_id, NEW.dedupe_key, NEW.moderation_key_id, NEW.reason_code,
      NEW.committed_at, NEW.content_expires_at
    );
END;

CREATE TRIGGER moment_reports_close_tombstone
AFTER UPDATE OF state ON moment_reports
WHEN OLD.state = 'expired' AND NEW.state = 'deleted'
  AND NEW.committed_at IS NOT NULL
BEGIN
    UPDATE moment_report_tombstones
       SET content_deleted_at = MAX(COALESCE(content_deleted_at, 0), NEW.closed_at)
     WHERE report_id = NEW.id;
END;

CREATE TRIGGER moment_blocks_validate_insert
BEFORE INSERT ON moment_blocks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moment_spaces AS space
        JOIN moment_participants AS blocker
          ON blocker.id = NEW.blocker_participant_id
        JOIN moment_participants AS blocked
          ON blocked.id = NEW.blocked_participant_id
       WHERE space.space_id = NEW.space_id
         AND space.state = 'active'
         AND space.current_key_epoch + 1 = NEW.created_key_epoch
         AND blocker.space_id = space.space_id AND blocker.state = 'active'
         AND blocked.space_id = space.space_id AND blocked.state = 'active'
    ) THEN RAISE(ABORT, 'block participants are not eligible') END);
END;

CREATE TRIGGER moment_blocks_rotate_space
AFTER INSERT ON moment_blocks
BEGIN
    UPDATE moment_spaces
       SET current_key_epoch = NEW.created_key_epoch,
           membership_revision = membership_revision + 1,
           updated_at = NEW.created_at
     WHERE space_id = NEW.space_id
       AND current_key_epoch + 1 = NEW.created_key_epoch;
END;

-- Bridge all existing and future Phase 1 identities into the v2 model. A later
-- pairing API can create additional devices under one participant directly.
INSERT INTO moment_space_lineages(id, created_at)
SELECT id, created_at FROM spaces;

INSERT INTO moment_spaces(space_id, lineage_id, state, created_at, updated_at, revoked_at)
SELECT id, id, state, created_at, last_activity_at, revoked_at FROM spaces;

INSERT INTO moment_participants(
  id, space_id, legacy_member_id, role, state, created_at, activated_at, revoked_at,
  report_only_until
)
SELECT id, space_id, id,
       (CASE role WHEN 'owner' THEN 'owner' ELSE 'member' END),
       state, created_at, activated_at, revoked_at,
       (CASE WHEN state IN ('revoked', 'expired') AND revoked_at IS NOT NULL
            THEN revoked_at + 86400 ELSE NULL END)
  FROM members;

INSERT INTO moment_devices(
  id, participant_id, legacy_member_id, agreement_public_key, signing_public_key,
  state, created_at, activated_at, revoked_at, report_only_until
)
SELECT id, id, id, agreement_public_key, signing_public_key,
       state, created_at, activated_at, revoked_at,
       (CASE WHEN state IN ('revoked', 'expired') AND revoked_at IS NOT NULL
            THEN revoked_at + 86400 ELSE NULL END)
  FROM members;

CREATE TRIGGER moment_bridge_space_insert
AFTER INSERT ON spaces
BEGIN
    INSERT INTO moment_space_lineages(id, created_at)
    VALUES (NEW.id, NEW.created_at);
    INSERT INTO moment_spaces(
      space_id, lineage_id, state, created_at, updated_at, revoked_at
    ) VALUES (
      NEW.id, NEW.id, NEW.state, NEW.created_at, NEW.last_activity_at, NEW.revoked_at
    );
END;

CREATE TRIGGER moment_bridge_space_state
AFTER UPDATE OF state ON spaces
BEGIN
    UPDATE moment_spaces
       SET state = NEW.state,
           updated_at = COALESCE(NEW.revoked_at, NEW.last_activity_at),
           revoked_at = NEW.revoked_at
     WHERE space_id = NEW.id;
    UPDATE moment_participants
       SET state = 'revoked', revoked_at = COALESCE(revoked_at, NEW.revoked_at),
           report_only_until = MAX(
             COALESCE(report_only_until, 0), COALESCE(NEW.revoked_at, NEW.last_activity_at) + 86400
           )
     WHERE space_id = NEW.id AND state IN ('pending', 'active')
       AND NEW.state = 'revoked';
    UPDATE moment_devices
       SET state = 'revoked', revoked_at = COALESCE(revoked_at, NEW.revoked_at),
           report_only_until = MAX(
             COALESCE(report_only_until, 0), COALESCE(NEW.revoked_at, NEW.last_activity_at) + 86400
           )
     WHERE participant_id IN (
       SELECT id FROM moment_participants WHERE space_id = NEW.id
     ) AND state IN ('pending', 'active') AND NEW.state = 'revoked';
    UPDATE moment_deliveries
       SET state = 'revoked', revoked_at = COALESCE(NEW.revoked_at, NEW.last_activity_at)
     WHERE state IN ('pending', 'acknowledged')
       AND moment_id IN (SELECT id FROM moments WHERE space_id = NEW.id)
       AND NEW.state = 'revoked';
    INSERT INTO moment_object_deletions(
      object_key, object_type, owner_id, state, not_before, attempts, created_at
    )
    SELECT object_key, 'moment', id, 'pending',
           COALESCE(NEW.revoked_at, NEW.last_activity_at) + 600, 0,
           COALESCE(NEW.revoked_at, NEW.last_activity_at)
      FROM moments
     WHERE space_id = NEW.id AND state <> 'deleted' AND NEW.state = 'revoked'
    ON CONFLICT(object_key) DO UPDATE SET
      state = 'pending',
      not_before = MIN(moment_object_deletions.not_before, excluded.not_before),
      attempts = moment_object_deletions.attempts + 1,
      deleted_at = NULL;
    UPDATE moments
       SET state = 'expired', closed_at = COALESCE(NEW.revoked_at, NEW.last_activity_at)
     WHERE space_id = NEW.id
       AND state IN ('reserved', 'uploaded', 'committed')
       AND NEW.state = 'revoked';
END;

CREATE TRIGGER moment_bridge_member_insert
AFTER INSERT ON members
BEGIN
    INSERT INTO moment_participants(
      id, space_id, legacy_member_id, role, state, created_at, activated_at, revoked_at,
      report_only_until
    ) VALUES (
      NEW.id, NEW.space_id, NEW.id,
       (CASE NEW.role WHEN 'owner' THEN 'owner' ELSE 'member' END),
      NEW.state, NEW.created_at, NEW.activated_at, NEW.revoked_at,
       (CASE WHEN NEW.state IN ('revoked', 'expired') AND NEW.revoked_at IS NOT NULL
            THEN NEW.revoked_at + 86400 ELSE NULL END)
    );
    INSERT INTO moment_devices(
      id, participant_id, legacy_member_id, agreement_public_key, signing_public_key,
      state, created_at, activated_at, revoked_at, report_only_until
    ) VALUES (
      NEW.id, NEW.id, NEW.id, NEW.agreement_public_key, NEW.signing_public_key,
      NEW.state, NEW.created_at, NEW.activated_at, NEW.revoked_at,
       (CASE WHEN NEW.state IN ('revoked', 'expired') AND NEW.revoked_at IS NOT NULL
            THEN NEW.revoked_at + 86400 ELSE NULL END)
    );
END;

CREATE TRIGGER moment_bridge_member_state
AFTER UPDATE OF state ON members
BEGIN
    UPDATE moment_participants
       SET state = NEW.state,
           activated_at = NEW.activated_at,
           revoked_at = NEW.revoked_at,
           report_only_until = (CASE
             WHEN NEW.state IN ('revoked', 'expired')
             THEN MAX(COALESCE(report_only_until, 0), COALESCE(NEW.revoked_at, NEW.created_at) + 86400)
              ELSE NULL END)
     WHERE legacy_member_id = NEW.id;
    UPDATE moment_devices
       SET state = NEW.state,
           activated_at = NEW.activated_at,
           revoked_at = NEW.revoked_at,
           report_only_until = (CASE
             WHEN NEW.state IN ('revoked', 'expired')
             THEN MAX(COALESCE(report_only_until, 0), COALESCE(NEW.revoked_at, NEW.created_at) + 86400)
              ELSE NULL END)
     WHERE legacy_member_id = NEW.id;
END;
