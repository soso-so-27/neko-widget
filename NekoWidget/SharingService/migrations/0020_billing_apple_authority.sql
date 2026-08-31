PRAGMA foreign_keys = ON;

-- These are separate upper/lower switches. Apple credentials, a configured
-- webhook URL, or transaction ingestion can never enable notification intake
-- or status reconciliation by themselves.
ALTER TABLE billing_runtime_gate
  ADD COLUMN apple_notification_ingestion_enabled INTEGER NOT NULL DEFAULT 0
  CHECK (apple_notification_ingestion_enabled IN (0, 1));
ALTER TABLE billing_runtime_gate
  ADD COLUMN subscription_reconciliation_enabled INTEGER NOT NULL DEFAULT 0
  CHECK (subscription_reconciliation_enabled IN (0, 1));

-- Keep only a hash and normalized signed facts. The Apple signedPayload and
-- nested JWS values are deliberately never persisted.
CREATE TABLE billing_apple_notification_events (
    notification_uuid TEXT PRIMARY KEY CHECK (
      length(notification_uuid) = 36 AND notification_uuid = lower(notification_uuid)
      AND substr(notification_uuid, 9, 1) = '-'
      AND substr(notification_uuid, 14, 1) = '-'
      AND substr(notification_uuid, 19, 1) = '-'
      AND substr(notification_uuid, 24, 1) = '-'
      AND length(replace(notification_uuid, '-', '')) = 32
      AND notification_uuid NOT GLOB '*[^0-9a-f-]*'
    ),
    payload_hash TEXT NOT NULL UNIQUE CHECK (
      length(payload_hash) = 43 AND payload_hash NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    notification_type TEXT NOT NULL CHECK (
      length(notification_type) BETWEEN 1 AND 64
      AND notification_type NOT GLOB '*[^A-Z0-9_]*'
    ),
    subtype TEXT CHECK (
      length(subtype) BETWEEN 1 AND 64 AND subtype NOT GLOB '*[^A-Z0-9_]*'
    ),
    signed_date_ms INTEGER NOT NULL CHECK (signed_date_ms > 0),
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    apple_status INTEGER CHECK (apple_status BETWEEN 1 AND 5),
    relevance TEXT NOT NULL CHECK (relevance IN ('ignored', 'unmatched', 'linked')),
    transaction_id TEXT CHECK (
      length(transaction_id) BETWEEN 1 AND 32 AND transaction_id NOT GLOB '*[^0-9]*'
    ),
    original_transaction_id TEXT CHECK (
      length(original_transaction_id) BETWEEN 1 AND 32
      AND original_transaction_id NOT GLOB '*[^0-9]*'
    ),
    billing_account_id TEXT CHECK (
      length(billing_account_id) = 36 AND billing_account_id = lower(billing_account_id)
    ),
    received_at INTEGER NOT NULL DEFAULT (unixepoch()),
    CHECK (
      (relevance = 'ignored' AND transaction_id IS NULL
        AND original_transaction_id IS NULL AND billing_account_id IS NULL)
      OR
      (relevance IN ('unmatched', 'linked') AND transaction_id IS NOT NULL
        AND original_transaction_id IS NOT NULL AND billing_account_id IS NOT NULL)
    )
) STRICT;

CREATE INDEX billing_apple_notifications_lineage_order
    ON billing_apple_notification_events(original_transaction_id, signed_date_ms DESC)
    WHERE original_transaction_id IS NOT NULL;

-- A notification only requests reconciliation. It never writes an entitlement
-- state directly. Leases make concurrent cron invocations harmless.
CREATE TABLE billing_reconciliation_jobs (
    original_transaction_id TEXT PRIMARY KEY
      REFERENCES billing_transaction_lineages(original_transaction_id) ON DELETE RESTRICT,
    requested_at INTEGER NOT NULL,
    not_before INTEGER NOT NULL,
    request_generation INTEGER NOT NULL DEFAULT 1 CHECK (request_generation > 0),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 20),
    lease_token TEXT UNIQUE CHECK (
      length(lease_token) = 22 AND lease_token NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    lease_expires_at INTEGER,
    last_error_code TEXT CHECK (
      length(last_error_code) BETWEEN 1 AND 64
      AND last_error_code NOT GLOB '*[^a-z0-9_]*'
    ),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    CHECK (
      (lease_token IS NULL AND lease_expires_at IS NULL)
      OR (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
    )
) STRICT;

CREATE INDEX billing_reconciliation_jobs_due
    ON billing_reconciliation_jobs(not_before, requested_at, original_transaction_id);

-- If a disabled foundation already contains reviewed lineages, enabling the
-- independent reconciliation gates later must not depend on another device
-- submission or a newly delivered notification.
INSERT INTO billing_reconciliation_jobs(
  original_transaction_id, requested_at, not_before
)
SELECT original_transaction_id, unixepoch(), unixepoch()
  FROM billing_transaction_lineages;

-- Append-only snapshots from Get All Subscription Statuses are the only
-- authoritative billing observations. Notification status is audit/trigger
-- data and app-submitted transactions remain provisional candidates.
CREATE TABLE billing_subscription_authority_observations (
    observation_fingerprint TEXT PRIMARY KEY CHECK (
      length(observation_fingerprint) = 43
      AND observation_fingerprint NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    original_transaction_id TEXT NOT NULL,
    billing_account_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    subscription_group_id TEXT NOT NULL,
    apple_status INTEGER NOT NULL CHECK (apple_status BETWEEN 1 AND 5),
    transaction_id TEXT NOT NULL CHECK (
      length(transaction_id) BETWEEN 1 AND 32 AND transaction_id NOT GLOB '*[^0-9]*'
    ),
    product_id TEXT NOT NULL CHECK (
      length(product_id) BETWEEN 1 AND 100
      AND product_id NOT GLOB '*[^A-Za-z0-9._-]*'
    ),
    expires_date_ms INTEGER NOT NULL CHECK (expires_date_ms > 0),
    revocation_date_ms INTEGER CHECK (revocation_date_ms > 0),
    revocation_reason INTEGER CHECK (revocation_reason IN (0, 1)),
    is_upgraded INTEGER NOT NULL CHECK (is_upgraded IN (0, 1)),
    auto_renew_product_id TEXT CHECK (
      length(auto_renew_product_id) BETWEEN 1 AND 100
      AND auto_renew_product_id NOT GLOB '*[^A-Za-z0-9._-]*'
    ),
    auto_renew_status INTEGER CHECK (auto_renew_status IN (0, 1)),
    is_in_billing_retry_period INTEGER CHECK (is_in_billing_retry_period IN (0, 1)),
    grace_period_expires_date_ms INTEGER CHECK (grace_period_expires_date_ms > 0),
    renewal_date_ms INTEGER CHECK (renewal_date_ms > 0),
    transaction_signed_date_ms INTEGER NOT NULL CHECK (transaction_signed_date_ms > 0),
    renewal_signed_date_ms INTEGER NOT NULL CHECK (renewal_signed_date_ms > 0),
    fetched_at_ms INTEGER NOT NULL CHECK (fetched_at_ms > 0),
    recorded_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) REFERENCES billing_transaction_lineages(
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) ON DELETE RESTRICT
) STRICT;

CREATE INDEX billing_authority_account_order
    ON billing_subscription_authority_observations(
      billing_account_id, fetched_at_ms DESC, observation_fingerprint DESC
    );
CREATE INDEX billing_authority_lineage_order
    ON billing_subscription_authority_observations(
      original_transaction_id, fetched_at_ms DESC, observation_fingerprint DESC
    );

CREATE TRIGGER billing_apple_notification_events_are_immutable
BEFORE UPDATE ON billing_apple_notification_events
BEGIN SELECT RAISE(ABORT, 'billing Apple notification events are immutable'); END;
CREATE TRIGGER billing_apple_notification_events_cannot_be_deleted
BEFORE DELETE ON billing_apple_notification_events
BEGIN SELECT RAISE(ABORT, 'billing Apple notification events cannot be deleted'); END;

CREATE TRIGGER billing_authority_observations_are_immutable
BEFORE UPDATE ON billing_subscription_authority_observations
BEGIN SELECT RAISE(ABORT, 'billing authority observations are immutable'); END;
CREATE TRIGGER billing_authority_observations_cannot_be_deleted
BEFORE DELETE ON billing_subscription_authority_observations
BEGIN SELECT RAISE(ABORT, 'billing authority observations cannot be deleted'); END;
