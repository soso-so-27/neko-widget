PRAGMA foreign_keys = ON;

-- Plus billing is intentionally independent from spaces, participants,
-- members and devices. The UUID is the StoreKit appAccountToken; it is not a
-- sharing credential and grants no window access by itself.

CREATE TABLE billing_runtime_gate (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    generation INTEGER NOT NULL CHECK (generation >= 0),
    account_bootstrap_enabled INTEGER NOT NULL CHECK (account_bootstrap_enabled IN (0, 1)),
    transaction_ingestion_enabled INTEGER NOT NULL CHECK (transaction_ingestion_enabled IN (0, 1)),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

INSERT INTO billing_runtime_gate(
  singleton, generation, account_bootstrap_enabled, transaction_ingestion_enabled
) VALUES (1, 0, 0, 0);

CREATE TRIGGER billing_runtime_gate_singleton_cannot_be_deleted
BEFORE DELETE ON billing_runtime_gate
BEGIN SELECT RAISE(ABORT, 'billing runtime gate cannot be deleted'); END;

CREATE TRIGGER billing_runtime_gate_requires_cas
BEFORE UPDATE ON billing_runtime_gate
WHEN NEW.singleton <> 1
  OR NEW.generation <> OLD.generation + 1
  OR NEW.updated_at <> unixepoch()
BEGIN SELECT RAISE(ABORT, 'billing runtime gate requires generation CAS and database time'); END;

CREATE TABLE billing_accounts (
    id TEXT PRIMARY KEY CHECK (
      length(id) = 36 AND id = lower(id)
      AND substr(id, 9, 1) = '-' AND substr(id, 14, 1) = '-'
      AND substr(id, 15, 1) = '4' AND substr(id, 19, 1) = '-'
      AND substr(id, 20, 1) GLOB '[89ab]' AND substr(id, 24, 1) = '-'
      AND length(replace(id, '-', '')) = 32
      AND id NOT GLOB '*[^0-9a-f-]*'
    ),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE TABLE billing_account_keys (
    id TEXT PRIMARY KEY CHECK (
      length(id) = 22 AND id NOT GLOB '*[^A-Za-z0-9_-]*'
      AND substr(id, 22, 1) GLOB '[AQgw]'
    ),
    billing_account_id TEXT NOT NULL REFERENCES billing_accounts(id) ON DELETE RESTRICT,
    signing_public_key TEXT NOT NULL UNIQUE CHECK (
      length(signing_public_key) = 43
      AND signing_public_key NOT GLOB '*[^A-Za-z0-9_-]*'
      AND substr(signing_public_key, 43, 1) GLOB '[AEIMQUYcgkosw048]'
    ),
    state TEXT NOT NULL CHECK (state IN ('active', 'revoked')),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    revoked_at INTEGER,
    CHECK (
      (state = 'active' AND revoked_at IS NULL)
      OR (state = 'revoked' AND revoked_at IS NOT NULL)
    )
) STRICT;

CREATE UNIQUE INDEX one_initial_billing_key_per_account
    ON billing_account_keys(billing_account_id) WHERE state = 'active';

CREATE TABLE billing_account_bootstrap_requests (
    client_request_id TEXT PRIMARY KEY CHECK (
      length(client_request_id) = 36 AND client_request_id = lower(client_request_id)
      AND substr(client_request_id, 9, 1) = '-' AND substr(client_request_id, 14, 1) = '-'
      AND substr(client_request_id, 15, 1) = '4' AND substr(client_request_id, 19, 1) = '-'
      AND substr(client_request_id, 20, 1) GLOB '[89ab]'
      AND substr(client_request_id, 24, 1) = '-'
      AND length(replace(client_request_id, '-', '')) = 32
      AND client_request_id NOT GLOB '*[^0-9a-f-]*'
    ),
    request_hash TEXT NOT NULL CHECK (
      length(request_hash) = 43 AND request_hash NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    billing_account_id TEXT NOT NULL UNIQUE REFERENCES billing_accounts(id) ON DELETE RESTRICT,
    billing_key_id TEXT NOT NULL UNIQUE REFERENCES billing_account_keys(id) ON DELETE RESTRICT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE TABLE billing_request_nonces (
    billing_key_id TEXT NOT NULL REFERENCES billing_account_keys(id) ON DELETE RESTRICT,
    nonce TEXT NOT NULL CHECK (
      length(nonce) = 22 AND nonce NOT GLOB '*[^A-Za-z0-9_-]*'
      AND substr(nonce, 22, 1) GLOB '[AQgw]'
    ),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK (expires_at > created_at),
    PRIMARY KEY (billing_key_id, nonce)
) STRICT;

CREATE INDEX billing_request_nonces_expiry
    ON billing_request_nonces(expires_at, billing_key_id, nonce);

CREATE TABLE billing_transaction_lineages (
    original_transaction_id TEXT PRIMARY KEY CHECK (
      length(original_transaction_id) BETWEEN 1 AND 32
      AND original_transaction_id NOT GLOB '*[^0-9]*'
    ),
    billing_account_id TEXT NOT NULL REFERENCES billing_accounts(id) ON DELETE RESTRICT,
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    subscription_group_id TEXT NOT NULL CHECK (
      length(subscription_group_id) BETWEEN 1 AND 100
      AND subscription_group_id NOT GLOB '*[^A-Za-z0-9._-]*'
    ),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    UNIQUE (original_transaction_id, billing_account_id, environment, subscription_group_id)
) STRICT;

-- Store only verified normalized fields and a semantic fingerprint. The raw
-- JWS, network address, signatures and HMAC secret are deliberately absent.
CREATE TABLE billing_transaction_events (
    event_fingerprint TEXT PRIMARY KEY CHECK (
      length(event_fingerprint) = 43 AND event_fingerprint NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    transaction_id TEXT NOT NULL CHECK (
      length(transaction_id) BETWEEN 1 AND 32 AND transaction_id NOT GLOB '*[^0-9]*'
    ),
    original_transaction_id TEXT NOT NULL,
    billing_account_id TEXT NOT NULL,
    submitted_by_billing_key_id TEXT REFERENCES billing_account_keys(id) ON DELETE RESTRICT,
    source TEXT NOT NULL CHECK (source IN ('app', 'apple_notification')),
    product_id TEXT NOT NULL CHECK (
      length(product_id) BETWEEN 1 AND 100 AND product_id NOT GLOB '*[^A-Za-z0-9._-]*'
    ),
    subscription_group_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    ownership_type TEXT NOT NULL CHECK (ownership_type IN ('PURCHASED', 'FAMILY_SHARED')),
    transaction_reason TEXT NOT NULL CHECK (transaction_reason IN ('PURCHASE', 'RENEWAL')),
    purchase_date_ms INTEGER NOT NULL CHECK (purchase_date_ms > 0),
    original_purchase_date_ms INTEGER NOT NULL CHECK (original_purchase_date_ms > 0),
    expires_date_ms INTEGER NOT NULL CHECK (expires_date_ms > 0),
    signed_date_ms INTEGER NOT NULL CHECK (signed_date_ms > 0),
    revocation_date_ms INTEGER CHECK (revocation_date_ms > 0),
    revocation_reason INTEGER CHECK (revocation_reason IN (0, 1)),
    is_upgraded INTEGER NOT NULL CHECK (is_upgraded IN (0, 1)),
    received_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) REFERENCES billing_transaction_lineages(
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) ON DELETE RESTRICT,
    CHECK (
      (source = 'app' AND submitted_by_billing_key_id IS NOT NULL)
      OR (source = 'apple_notification' AND submitted_by_billing_key_id IS NULL)
    ),
    UNIQUE (transaction_id, signed_date_ms)
) STRICT;

CREATE INDEX billing_transaction_events_lineage_order
    ON billing_transaction_events(original_transaction_id, signed_date_ms DESC);
CREATE INDEX billing_transaction_events_account_order
    ON billing_transaction_events(billing_account_id, signed_date_ms DESC);

CREATE TRIGGER billing_transaction_events_require_matching_submitter
BEFORE INSERT ON billing_transaction_events WHEN NEW.source = 'app'
BEGIN
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM billing_account_keys
     WHERE id = NEW.submitted_by_billing_key_id
       AND billing_account_id = NEW.billing_account_id AND state = 'active'
  ) THEN RAISE(ABORT, 'billing transaction submitter does not own billing account') END);
END;

CREATE TRIGGER billing_accounts_are_immutable
BEFORE UPDATE ON billing_accounts
BEGIN SELECT RAISE(ABORT, 'billing accounts are immutable'); END;
CREATE TRIGGER billing_accounts_cannot_be_deleted
BEFORE DELETE ON billing_accounts
BEGIN SELECT RAISE(ABORT, 'billing accounts cannot be deleted'); END;

CREATE TRIGGER billing_account_keys_restrict_state
BEFORE UPDATE ON billing_account_keys
WHEN NOT (
  OLD.id = NEW.id AND OLD.billing_account_id = NEW.billing_account_id
  AND OLD.signing_public_key = NEW.signing_public_key AND OLD.created_at = NEW.created_at
  AND OLD.state = 'active' AND NEW.state = 'revoked'
  AND OLD.revoked_at IS NULL AND NEW.revoked_at = unixepoch()
)
BEGIN SELECT RAISE(ABORT, 'invalid billing key transition'); END;
CREATE TRIGGER billing_account_keys_cannot_be_deleted
BEFORE DELETE ON billing_account_keys
BEGIN SELECT RAISE(ABORT, 'billing account keys cannot be deleted'); END;

CREATE TRIGGER billing_bootstrap_requests_are_immutable
BEFORE UPDATE ON billing_account_bootstrap_requests
BEGIN SELECT RAISE(ABORT, 'billing bootstrap requests are immutable'); END;
CREATE TRIGGER billing_bootstrap_requests_cannot_be_deleted
BEFORE DELETE ON billing_account_bootstrap_requests
BEGIN SELECT RAISE(ABORT, 'billing bootstrap requests cannot be deleted'); END;

CREATE TRIGGER billing_transaction_lineages_are_immutable
BEFORE UPDATE ON billing_transaction_lineages
BEGIN SELECT RAISE(ABORT, 'billing transaction lineages are immutable'); END;
CREATE TRIGGER billing_transaction_lineages_cannot_be_deleted
BEFORE DELETE ON billing_transaction_lineages
BEGIN SELECT RAISE(ABORT, 'billing transaction lineages cannot be deleted'); END;

CREATE TRIGGER billing_transaction_events_are_immutable
BEFORE UPDATE ON billing_transaction_events
BEGIN SELECT RAISE(ABORT, 'billing transaction events are immutable'); END;
CREATE TRIGGER billing_transaction_events_cannot_be_deleted
BEFORE DELETE ON billing_transaction_events
BEGIN SELECT RAISE(ABORT, 'billing transaction events cannot be deleted'); END;
