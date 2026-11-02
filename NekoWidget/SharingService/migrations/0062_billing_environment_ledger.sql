-- Environment-qualified billing ledger. Apply only with all billing gates closed and leases drained.
-- The migration is one D1 batch; do not run statements individually.
-- Unattributable historical empty pages remain in immutable legacy tables.
PRAGMA defer_foreign_keys = ON;

CREATE TABLE billing_environment_migration_guard (safe INTEGER NOT NULL CHECK (safe = 1));

INSERT INTO billing_environment_migration_guard SELECT (CASE WHEN EXISTS (SELECT 1 FROM billing_runtime_gate WHERE singleton = 1 AND account_bootstrap_enabled = 0 AND transaction_ingestion_enabled = 0 AND apple_notification_ingestion_enabled = 0 AND subscription_reconciliation_enabled = 0 AND effective_entitlement_enabled = 0 AND account_recovery_enabled = 0 AND window_sponsorship_enabled = 0 AND apple_notification_history_recovery_enabled = 0 AND NOT EXISTS (SELECT 1 FROM billing_reconciliation_jobs WHERE lease_token IS NOT NULL) AND NOT EXISTS (SELECT 1 FROM billing_apple_notification_history_recovery WHERE state = 'leased')) THEN 1 ELSE 0 END);

CREATE TABLE billing_apple_notification_history_page_commits_legacy_0061 AS SELECT * FROM billing_apple_notification_history_page_commits;

CREATE TABLE billing_apple_notification_history_page_finalizations_legacy_0061 AS SELECT * FROM billing_apple_notification_history_page_finalizations;

CREATE TABLE billing_apple_notification_history_page_records_legacy_0061 AS SELECT * FROM billing_apple_notification_history_page_records;

CREATE TABLE billing_apple_notification_history_recovery_legacy_0061 AS SELECT * FROM billing_apple_notification_history_recovery;

CREATE TABLE billing_transaction_lineages__new (
    original_transaction_id TEXT NOT NULL CHECK (
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
    UNIQUE (original_transaction_id, billing_account_id, environment, subscription_group_id),
    PRIMARY KEY (environment, original_transaction_id)
) STRICT;

CREATE TABLE billing_account_apple_identities__new (
    billing_account_id TEXT NOT NULL REFERENCES billing_accounts(id) ON DELETE RESTRICT,
    app_transaction_id_hash TEXT NOT NULL CHECK (
      length(app_transaction_id_hash) = 43
      AND app_transaction_id_hash NOT GLOB '*[^A-Za-z0-9_-]*'
      AND substr(app_transaction_id_hash, 43, 1) GLOB '[AEIMQUYcgkosw048]'
    ),
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    first_original_transaction_id TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (environment, first_original_transaction_id) REFERENCES billing_transaction_lineages__new(environment, original_transaction_id) ON DELETE RESTRICT,
    PRIMARY KEY (environment, billing_account_id),
    UNIQUE (environment, app_transaction_id_hash)
) STRICT;

CREATE TABLE billing_account_recovery_requests__new (
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    client_request_id TEXT PRIMARY KEY CHECK (
      length(client_request_id) = 36 AND client_request_id = lower(client_request_id)
      AND substr(client_request_id, 15, 1) = '4'
      AND substr(client_request_id, 20, 1) GLOB '[89ab]'
      AND length(replace(client_request_id, '-', '')) = 32
      AND client_request_id NOT GLOB '*[^0-9a-f-]*'
    ),
    request_hash TEXT NOT NULL CHECK (
      length(request_hash) = 43 AND request_hash NOT GLOB '*[^A-Za-z0-9_-]*'
      AND substr(request_hash, 43, 1) GLOB '[AEIMQUYcgkosw048]'
    ),
    billing_account_id TEXT NOT NULL REFERENCES billing_accounts(id) ON DELETE RESTRICT,
    expected_generation INTEGER NOT NULL CHECK (expected_generation >= 0),
    expected_transaction_id TEXT NOT NULL CHECK (
      length(expected_transaction_id) BETWEEN 1 AND 32
      AND expected_transaction_id NOT GLOB '*[^0-9]*'
    ),
    expected_original_transaction_id TEXT NOT NULL,
    app_transaction_id_hash TEXT NOT NULL CHECK (
      length(app_transaction_id_hash) = 43
      AND app_transaction_id_hash NOT GLOB '*[^A-Za-z0-9_-]*'
      AND substr(app_transaction_id_hash, 43, 1) GLOB '[AEIMQUYcgkosw048]'
    ),
    replaced_billing_key_id TEXT NOT NULL REFERENCES billing_account_keys(id) ON DELETE RESTRICT,
    new_billing_key_id TEXT NOT NULL UNIQUE CHECK (
      length(new_billing_key_id) = 22
      AND new_billing_key_id NOT GLOB '*[^A-Za-z0-9_-]*'
      AND substr(new_billing_key_id, 22, 1) GLOB '[AQgw]'
    ),
    new_signing_public_key TEXT NOT NULL UNIQUE CHECK (
      length(new_signing_public_key) = 43
      AND new_signing_public_key NOT GLOB '*[^A-Za-z0-9_-]*'
      AND substr(new_signing_public_key, 43, 1) GLOB '[AEIMQUYcgkosw048]'
    ),
    recovered_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (environment, expected_original_transaction_id) REFERENCES billing_transaction_lineages__new(environment, original_transaction_id) ON DELETE RESTRICT
) STRICT;

CREATE TABLE billing_apple_notification_events__new (
    notification_uuid TEXT NOT NULL CHECK (
      length(notification_uuid) = 36 AND notification_uuid = lower(notification_uuid)
      AND substr(notification_uuid, 9, 1) = '-'
      AND substr(notification_uuid, 14, 1) = '-'
      AND substr(notification_uuid, 19, 1) = '-'
      AND substr(notification_uuid, 24, 1) = '-'
      AND length(replace(notification_uuid, '-', '')) = 32
      AND notification_uuid NOT GLOB '*[^0-9a-f-]*'
    ),
    payload_hash TEXT NOT NULL CHECK (
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
    ),
    PRIMARY KEY (environment, notification_uuid),
    UNIQUE (environment, payload_hash)
) STRICT;

CREATE TABLE billing_apple_notification_history_page_commits__new (
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
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
    PRIMARY KEY (environment, generation, page_index),
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

CREATE TABLE billing_apple_notification_history_page_finalizations__new (
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    generation INTEGER NOT NULL,
    page_index INTEGER NOT NULL,
    finalized_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (environment, generation, page_index),
    FOREIGN KEY (environment, generation, page_index)
      REFERENCES billing_apple_notification_history_page_commits__new(environment, generation, page_index)
      ON DELETE RESTRICT
) STRICT;

CREATE TABLE billing_apple_notification_history_page_records__new (
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    generation INTEGER NOT NULL,
    page_index INTEGER NOT NULL,
    record_index INTEGER NOT NULL CHECK (record_index BETWEEN 0 AND 19),
    notification_uuid TEXT NOT NULL,
    payload_hash TEXT NOT NULL CHECK (
      length(payload_hash) = 43 AND payload_hash NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    PRIMARY KEY (environment, generation, page_index, record_index),
    UNIQUE (environment, generation, notification_uuid),
    UNIQUE (environment, generation, payload_hash),
    FOREIGN KEY (environment, generation, page_index)
      REFERENCES billing_apple_notification_history_page_commits__new(environment, generation, page_index)
      ON DELETE RESTRICT,
    FOREIGN KEY (environment, notification_uuid) REFERENCES billing_apple_notification_events__new(environment, notification_uuid) ON DELETE RESTRICT
) STRICT;

CREATE TABLE billing_apple_notification_history_recovery__new (
    environment TEXT PRIMARY KEY CHECK (environment IN ('Sandbox', 'Production')),
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
    ),
    CHECK (store_environment IS NULL OR store_environment = environment)
) STRICT;

CREATE TABLE billing_apple_notification_reconciliation_causes__new (
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    notification_uuid TEXT NOT NULL,
    original_transaction_id TEXT NOT NULL,
    requested_at INTEGER NOT NULL DEFAULT (unixepoch()) CHECK (requested_at > 0),
    FOREIGN KEY (environment, notification_uuid) REFERENCES billing_apple_notification_events__new(environment, notification_uuid) ON DELETE RESTRICT,
    FOREIGN KEY (environment, original_transaction_id) REFERENCES billing_transaction_lineages__new(environment, original_transaction_id) ON DELETE RESTRICT,
    PRIMARY KEY (environment, notification_uuid)
) STRICT;

CREATE TABLE billing_subscription_authority_observations__new (
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
    recorded_at INTEGER NOT NULL DEFAULT (unixepoch()), ownership_type TEXT
  CHECK (ownership_type IN ('PURCHASED', 'FAMILY_SHARED')),
    FOREIGN KEY (
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) REFERENCES billing_transaction_lineages__new(
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) ON DELETE RESTRICT
) STRICT;

CREATE TABLE billing_effective_entitlement_decisions__new (
    decision_id TEXT PRIMARY KEY CHECK (
      length(decision_id) = 22 AND decision_id NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    observation_fingerprint TEXT NOT NULL
      REFERENCES billing_subscription_authority_observations__new(observation_fingerprint)
      ON DELETE RESTRICT,
    original_transaction_id TEXT NOT NULL,
    billing_account_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    subscription_group_id TEXT NOT NULL,
    ownership_type TEXT NOT NULL CHECK (ownership_type IN ('PURCHASED', 'FAMILY_SHARED')),
    request_generation INTEGER NOT NULL CHECK (request_generation > 0),
    lease_token TEXT NOT NULL CHECK (
      length(lease_token) = 22 AND lease_token NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
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
    grace_period_expires_date_ms INTEGER CHECK (grace_period_expires_date_ms > 0),
    source_fetched_at_ms INTEGER NOT NULL CHECK (source_fetched_at_ms > 0),
    decision_status TEXT NOT NULL CHECK (
      decision_status IN (
        'active', 'gracePeriod', 'billingRetry', 'expired', 'revoked',
        'upgraded', 'unconfirmed'
      )
    ),
    grants_plus INTEGER NOT NULL CHECK (grants_plus IN (0, 1)),
    access_until_ms INTEGER CHECK (access_until_ms > 0),
    authority_stale_at_ms INTEGER NOT NULL CHECK (authority_stale_at_ms > 0),
    evaluated_at_ms INTEGER NOT NULL CHECK (evaluated_at_ms > 0),
    recorded_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) REFERENCES billing_transaction_lineages__new(
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) ON DELETE RESTRICT,
    CHECK (
      (grants_plus = 1 AND decision_status IN ('active', 'gracePeriod')
        AND ownership_type = 'PURCHASED' AND access_until_ms IS NOT NULL)
      OR
      (grants_plus = 0 AND decision_status NOT IN ('active', 'gracePeriod')
        AND access_until_ms IS NULL)
    )
) STRICT;

CREATE TABLE billing_effective_entitlement_current__new (
    original_transaction_id TEXT NOT NULL,
    billing_account_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    subscription_group_id TEXT NOT NULL,
    decision_id TEXT NOT NULL UNIQUE
      REFERENCES billing_effective_entitlement_decisions__new(decision_id) ON DELETE RESTRICT,
    observation_fingerprint TEXT NOT NULL
      REFERENCES billing_subscription_authority_observations__new(observation_fingerprint)
      ON DELETE RESTRICT,
    ownership_type TEXT NOT NULL CHECK (ownership_type IN ('PURCHASED', 'FAMILY_SHARED')),
    request_generation INTEGER NOT NULL CHECK (request_generation > 0),
    lease_token TEXT NOT NULL CHECK (
      length(lease_token) = 22 AND lease_token NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
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
    grace_period_expires_date_ms INTEGER CHECK (grace_period_expires_date_ms > 0),
    source_fetched_at_ms INTEGER NOT NULL CHECK (source_fetched_at_ms > 0),
    materialized_status TEXT NOT NULL CHECK (
      materialized_status IN (
        'active', 'gracePeriod', 'billingRetry', 'expired', 'revoked',
        'upgraded', 'unconfirmed'
      )
    ),
    materialized_grants_plus INTEGER NOT NULL CHECK (materialized_grants_plus IN (0, 1)),
    access_until_ms INTEGER CHECK (access_until_ms > 0),
    authority_stale_at_ms INTEGER NOT NULL CHECK (authority_stale_at_ms > 0),
    evaluated_at_ms INTEGER NOT NULL CHECK (evaluated_at_ms > 0),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) REFERENCES billing_transaction_lineages__new(
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) ON DELETE RESTRICT,
    CHECK (
      (materialized_grants_plus = 1
        AND materialized_status IN ('active', 'gracePeriod')
        AND ownership_type = 'PURCHASED' AND access_until_ms IS NOT NULL)
      OR
      (materialized_grants_plus = 0
        AND materialized_status NOT IN ('active', 'gracePeriod')
        AND access_until_ms IS NULL)
    ),
    PRIMARY KEY (environment, original_transaction_id)
) STRICT;

CREATE TABLE billing_reconciliation_jobs__new (
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    original_transaction_id TEXT NOT NULL,
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
    ),
    FOREIGN KEY (environment, original_transaction_id) REFERENCES billing_transaction_lineages__new(environment, original_transaction_id) ON DELETE RESTRICT,
    PRIMARY KEY (environment, original_transaction_id)
) STRICT;

CREATE TABLE billing_transaction_events__new (
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
    ) REFERENCES billing_transaction_lineages__new(
      original_transaction_id, billing_account_id, environment, subscription_group_id
    ) ON DELETE RESTRICT,
    CHECK (
      (source = 'app' AND submitted_by_billing_key_id IS NOT NULL)
      OR (source = 'apple_notification' AND submitted_by_billing_key_id IS NULL)
    ),
    UNIQUE (environment, transaction_id, signed_date_ms)
) STRICT;

CREATE TABLE billing_window_sponsorship_requests__new(
 client_request_id TEXT PRIMARY KEY CHECK(length(client_request_id)=36 AND client_request_id=lower(client_request_id) AND substr(client_request_id,15,1)='4' AND substr(client_request_id,20,1) GLOB '[89ab]' AND length(replace(client_request_id,'-',''))=32 AND client_request_id NOT GLOB '*[^0-9a-f-]*'),
 request_hash TEXT NOT NULL CHECK(length(request_hash)=43 AND request_hash NOT GLOB '*[^A-Za-z0-9_-]*'),
 operation TEXT NOT NULL CHECK(operation IN('sponsor','unsponsor')),
 billing_account_id TEXT NOT NULL REFERENCES billing_accounts(id) ON DELETE RESTRICT,
 submitted_by_billing_key_id TEXT NOT NULL REFERENCES billing_account_keys(id) ON DELETE RESTRICT,
 window_lineage_id TEXT NOT NULL REFERENCES moment_space_lineages(id) ON DELETE RESTRICT,
 expected_generation INTEGER NOT NULL CHECK(expected_generation>=0),
 expected_current_billing_account_id TEXT REFERENCES billing_accounts(id) ON DELETE RESTRICT,
 consent_space_id TEXT, owner_participant_id TEXT, owner_device_id TEXT,
 consent_membership_revision INTEGER CHECK(consent_membership_revision>0), consent_issued_at INTEGER,
 owner_consent_nonce_hash TEXT CHECK(owner_consent_nonce_hash IS NULL OR (length(owner_consent_nonce_hash)=43 AND owner_consent_nonce_hash NOT GLOB '*[^A-Za-z0-9_-]*')),
 owner_consent_hash TEXT CHECK(owner_consent_hash IS NULL OR (length(owner_consent_hash)=43 AND owner_consent_hash NOT GLOB '*[^A-Za-z0-9_-]*')),
 entitlement_decision_id TEXT REFERENCES billing_effective_entitlement_decisions__new(decision_id) ON DELETE RESTRICT,
 entitlement_request_generation INTEGER CHECK(entitlement_request_generation>0),
 entitlement_evaluated_at_ms INTEGER CHECK(entitlement_evaluated_at_ms>0),
 resulting_generation INTEGER NOT NULL CHECK(resulting_generation=expected_generation+1),
 recorded_at INTEGER NOT NULL DEFAULT(unixepoch()),
 CHECK((operation='sponsor' AND consent_space_id IS NOT NULL AND owner_participant_id IS NOT NULL AND owner_device_id IS NOT NULL AND consent_membership_revision IS NOT NULL AND consent_issued_at IS NOT NULL AND owner_consent_nonce_hash IS NOT NULL AND owner_consent_hash IS NOT NULL AND entitlement_decision_id IS NOT NULL AND entitlement_request_generation IS NOT NULL AND entitlement_evaluated_at_ms IS NOT NULL) OR (operation='unsponsor' AND consent_space_id IS NULL AND owner_participant_id IS NULL AND owner_device_id IS NULL AND consent_membership_revision IS NULL AND consent_issued_at IS NULL AND owner_consent_nonce_hash IS NULL AND owner_consent_hash IS NULL AND entitlement_decision_id IS NULL AND entitlement_request_generation IS NULL AND entitlement_evaluated_at_ms IS NULL))
) STRICT;

CREATE TABLE billing_window_sponsorships__new(
 window_lineage_id TEXT PRIMARY KEY REFERENCES moment_space_lineages(id) ON DELETE RESTRICT,
 billing_account_id TEXT REFERENCES billing_accounts(id) ON DELETE RESTRICT,
 state TEXT NOT NULL CHECK(state IN('active','unsponsored')), generation INTEGER NOT NULL CHECK(generation>0),
 sponsored_at INTEGER, updated_at INTEGER NOT NULL,
 last_request_id TEXT NOT NULL UNIQUE REFERENCES billing_window_sponsorship_requests__new(client_request_id) ON DELETE RESTRICT, last_owner_detach_request_id TEXT
 REFERENCES billing_window_sponsorship_owner_detach_requests(client_request_id)
 ON DELETE RESTRICT,
 CHECK((state='active' AND billing_account_id IS NOT NULL AND sponsored_at IS NOT NULL) OR (state='unsponsored' AND billing_account_id IS NULL))
) STRICT;

INSERT INTO billing_transaction_lineages__new(original_transaction_id, billing_account_id, environment, subscription_group_id, created_at) SELECT old.original_transaction_id, old.billing_account_id, old.environment, old.subscription_group_id, old.created_at FROM billing_transaction_lineages old;

INSERT INTO billing_account_apple_identities__new(billing_account_id, app_transaction_id_hash, environment, first_original_transaction_id, created_at) SELECT old.billing_account_id, old.app_transaction_id_hash, old.environment, old.first_original_transaction_id, old.created_at FROM billing_account_apple_identities old;

INSERT INTO billing_account_recovery_requests__new(environment, client_request_id, request_hash, billing_account_id, expected_generation, expected_transaction_id, expected_original_transaction_id, app_transaction_id_hash, replaced_billing_key_id, new_billing_key_id, new_signing_public_key, recovered_at) SELECT lineage.environment, old.client_request_id, old.request_hash, old.billing_account_id, old.expected_generation, old.expected_transaction_id, old.expected_original_transaction_id, old.app_transaction_id_hash, old.replaced_billing_key_id, old.new_billing_key_id, old.new_signing_public_key, old.recovered_at FROM billing_account_recovery_requests old JOIN billing_transaction_lineages lineage ON lineage.original_transaction_id = old.expected_original_transaction_id;

INSERT INTO billing_apple_notification_events__new(notification_uuid, payload_hash, notification_type, subtype, signed_date_ms, environment, apple_status, relevance, transaction_id, original_transaction_id, billing_account_id, received_at) SELECT old.notification_uuid, old.payload_hash, old.notification_type, old.subtype, old.signed_date_ms, old.environment, old.apple_status, old.relevance, old.transaction_id, old.original_transaction_id, old.billing_account_id, old.received_at FROM billing_apple_notification_events old;

INSERT INTO billing_apple_notification_history_page_commits__new(environment, generation, page_index, gate_generation, lease_token, input_cursor_hash, next_cursor_hash, has_more, record_count, committed_at) SELECT state.store_environment, old.generation, old.page_index, old.gate_generation, old.lease_token, old.input_cursor_hash, old.next_cursor_hash, old.has_more, old.record_count, old.committed_at FROM billing_apple_notification_history_page_commits old JOIN billing_apple_notification_history_recovery state ON state.generation = old.generation AND state.store_environment IS NOT NULL;

INSERT INTO billing_apple_notification_history_page_finalizations__new(environment, generation, page_index, finalized_at) SELECT state.store_environment, old.generation, old.page_index, old.finalized_at FROM billing_apple_notification_history_page_finalizations old JOIN billing_apple_notification_history_recovery state ON state.generation = old.generation AND state.store_environment IS NOT NULL;

INSERT INTO billing_apple_notification_history_page_records__new(environment, generation, page_index, record_index, notification_uuid, payload_hash) SELECT state.store_environment, old.generation, old.page_index, old.record_index, old.notification_uuid, old.payload_hash FROM billing_apple_notification_history_page_records old JOIN billing_apple_notification_history_recovery state ON state.generation = old.generation AND state.store_environment IS NOT NULL;

INSERT INTO billing_apple_notification_history_recovery__new(environment, generation, state, store_environment, bundle_id, frozen_start_date_ms, frozen_end_date_ms, pagination_cursor, committed_page_count, committed_record_count, cursor_reset_count, attempts, not_before, lease_token, lease_expires_at, claimed_gate_generation, last_error_code, started_at, completed_at, updated_at) SELECT old.store_environment, old.generation, old.state, old.store_environment, old.bundle_id, old.frozen_start_date_ms, old.frozen_end_date_ms, old.pagination_cursor, old.committed_page_count, old.committed_record_count, old.cursor_reset_count, old.attempts, old.not_before, old.lease_token, old.lease_expires_at, old.claimed_gate_generation, old.last_error_code, old.started_at, old.completed_at, old.updated_at FROM billing_apple_notification_history_recovery old WHERE old.state <> 'idle';

INSERT OR IGNORE INTO billing_apple_notification_history_recovery__new(environment) VALUES ('Production'), ('Sandbox');

INSERT INTO billing_apple_notification_reconciliation_causes__new(environment, notification_uuid, original_transaction_id, requested_at) SELECT event.environment, old.notification_uuid, old.original_transaction_id, old.requested_at FROM billing_apple_notification_reconciliation_causes old JOIN billing_apple_notification_events event ON event.notification_uuid = old.notification_uuid;

INSERT INTO billing_subscription_authority_observations__new(observation_fingerprint, original_transaction_id, billing_account_id, environment, subscription_group_id, apple_status, transaction_id, product_id, expires_date_ms, revocation_date_ms, revocation_reason, is_upgraded, auto_renew_product_id, auto_renew_status, is_in_billing_retry_period, grace_period_expires_date_ms, renewal_date_ms, transaction_signed_date_ms, renewal_signed_date_ms, fetched_at_ms, recorded_at, ownership_type) SELECT old.observation_fingerprint, old.original_transaction_id, old.billing_account_id, old.environment, old.subscription_group_id, old.apple_status, old.transaction_id, old.product_id, old.expires_date_ms, old.revocation_date_ms, old.revocation_reason, old.is_upgraded, old.auto_renew_product_id, old.auto_renew_status, old.is_in_billing_retry_period, old.grace_period_expires_date_ms, old.renewal_date_ms, old.transaction_signed_date_ms, old.renewal_signed_date_ms, old.fetched_at_ms, old.recorded_at, old.ownership_type FROM billing_subscription_authority_observations old;

INSERT INTO billing_effective_entitlement_decisions__new(decision_id, observation_fingerprint, original_transaction_id, billing_account_id, environment, subscription_group_id, ownership_type, request_generation, lease_token, apple_status, transaction_id, product_id, expires_date_ms, revocation_date_ms, revocation_reason, is_upgraded, grace_period_expires_date_ms, source_fetched_at_ms, decision_status, grants_plus, access_until_ms, authority_stale_at_ms, evaluated_at_ms, recorded_at) SELECT old.decision_id, old.observation_fingerprint, old.original_transaction_id, old.billing_account_id, old.environment, old.subscription_group_id, old.ownership_type, old.request_generation, old.lease_token, old.apple_status, old.transaction_id, old.product_id, old.expires_date_ms, old.revocation_date_ms, old.revocation_reason, old.is_upgraded, old.grace_period_expires_date_ms, old.source_fetched_at_ms, old.decision_status, old.grants_plus, old.access_until_ms, old.authority_stale_at_ms, old.evaluated_at_ms, old.recorded_at FROM billing_effective_entitlement_decisions old;

INSERT INTO billing_effective_entitlement_current__new(original_transaction_id, billing_account_id, environment, subscription_group_id, decision_id, observation_fingerprint, ownership_type, request_generation, lease_token, apple_status, transaction_id, product_id, expires_date_ms, revocation_date_ms, revocation_reason, is_upgraded, grace_period_expires_date_ms, source_fetched_at_ms, materialized_status, materialized_grants_plus, access_until_ms, authority_stale_at_ms, evaluated_at_ms, updated_at) SELECT old.original_transaction_id, old.billing_account_id, old.environment, old.subscription_group_id, old.decision_id, old.observation_fingerprint, old.ownership_type, old.request_generation, old.lease_token, old.apple_status, old.transaction_id, old.product_id, old.expires_date_ms, old.revocation_date_ms, old.revocation_reason, old.is_upgraded, old.grace_period_expires_date_ms, old.source_fetched_at_ms, old.materialized_status, old.materialized_grants_plus, old.access_until_ms, old.authority_stale_at_ms, old.evaluated_at_ms, old.updated_at FROM billing_effective_entitlement_current old;

INSERT INTO billing_reconciliation_jobs__new(environment, original_transaction_id, requested_at, not_before, request_generation, attempts, lease_token, lease_expires_at, last_error_code, updated_at) SELECT lineage.environment, old.original_transaction_id, old.requested_at, old.not_before, old.request_generation, old.attempts, old.lease_token, old.lease_expires_at, old.last_error_code, old.updated_at FROM billing_reconciliation_jobs old JOIN billing_transaction_lineages lineage ON lineage.original_transaction_id = old.original_transaction_id;

INSERT INTO billing_transaction_events__new(event_fingerprint, transaction_id, original_transaction_id, billing_account_id, submitted_by_billing_key_id, source, product_id, subscription_group_id, environment, ownership_type, transaction_reason, purchase_date_ms, original_purchase_date_ms, expires_date_ms, signed_date_ms, revocation_date_ms, revocation_reason, is_upgraded, received_at) SELECT old.event_fingerprint, old.transaction_id, old.original_transaction_id, old.billing_account_id, old.submitted_by_billing_key_id, old.source, old.product_id, old.subscription_group_id, old.environment, old.ownership_type, old.transaction_reason, old.purchase_date_ms, old.original_purchase_date_ms, old.expires_date_ms, old.signed_date_ms, old.revocation_date_ms, old.revocation_reason, old.is_upgraded, old.received_at FROM billing_transaction_events old;

INSERT INTO billing_window_sponsorship_requests__new(client_request_id, request_hash, operation, billing_account_id, submitted_by_billing_key_id, window_lineage_id, expected_generation, expected_current_billing_account_id, consent_space_id, owner_participant_id, owner_device_id, consent_membership_revision, consent_issued_at, owner_consent_nonce_hash, owner_consent_hash, entitlement_decision_id, entitlement_request_generation, entitlement_evaluated_at_ms, resulting_generation, recorded_at) SELECT old.client_request_id, old.request_hash, old.operation, old.billing_account_id, old.submitted_by_billing_key_id, old.window_lineage_id, old.expected_generation, old.expected_current_billing_account_id, old.consent_space_id, old.owner_participant_id, old.owner_device_id, old.consent_membership_revision, old.consent_issued_at, old.owner_consent_nonce_hash, old.owner_consent_hash, old.entitlement_decision_id, old.entitlement_request_generation, old.entitlement_evaluated_at_ms, old.resulting_generation, old.recorded_at FROM billing_window_sponsorship_requests old;

INSERT INTO billing_window_sponsorships__new(window_lineage_id, billing_account_id, state, generation, sponsored_at, updated_at, last_request_id, last_owner_detach_request_id) SELECT old.window_lineage_id, old.billing_account_id, old.state, old.generation, old.sponsored_at, old.updated_at, old.last_request_id, old.last_owner_detach_request_id FROM billing_window_sponsorships old;

DROP TRIGGER billing_transaction_events_require_matching_submitter;

DROP TRIGGER billing_transaction_lineages_are_immutable;

DROP TRIGGER billing_transaction_lineages_cannot_be_deleted;

DROP TRIGGER billing_transaction_events_are_immutable;

DROP TRIGGER billing_transaction_events_cannot_be_deleted;

DROP TRIGGER billing_apple_notification_events_are_immutable;

DROP TRIGGER billing_apple_notification_events_cannot_be_deleted;

DROP TRIGGER billing_authority_observations_are_immutable;

DROP TRIGGER billing_authority_observations_cannot_be_deleted;

DROP TRIGGER billing_entitlement_decisions_are_immutable;

DROP TRIGGER billing_entitlement_decisions_cannot_be_deleted;

DROP TRIGGER billing_entitlement_decisions_require_claimed_job;

DROP TRIGGER billing_entitlement_current_requires_matching_decision_on_insert;

DROP TRIGGER billing_entitlement_current_requires_matching_decision_on_update;

DROP TRIGGER billing_entitlement_current_restrict_update;

DROP TRIGGER billing_recovery_validate_before_insert;

DROP TRIGGER billing_recovery_rotate_after_insert;

DROP TRIGGER billing_account_apple_identities_are_immutable;

DROP TRIGGER billing_account_apple_identities_cannot_be_deleted;

DROP TRIGGER billing_account_recovery_requests_are_immutable;

DROP TRIGGER billing_account_recovery_requests_cannot_be_deleted;

DROP TRIGGER billing_account_key_state_requires_cas;

DROP TRIGGER billing_window_sponsorship_request_validate;

DROP TRIGGER billing_window_sponsorship_requests_are_immutable;

DROP TRIGGER billing_window_sponsorship_requests_cannot_be_deleted;

DROP TRIGGER billing_window_sponsorships_cannot_be_deleted;

DROP TRIGGER billing_window_owner_detach_request_validate;

DROP TRIGGER billing_window_sponsorship_apply;

DROP TRIGGER billing_window_owner_detach_apply;

DROP TRIGGER billing_window_sponsorship_state_validate_insert;

DROP TRIGGER billing_window_sponsorship_state_validate_update;

DROP TRIGGER billing_apple_notification_reconciliation_cause_matches_event;

DROP TRIGGER billing_apple_notification_reconciliation_cause_queues_once;

DROP TRIGGER billing_apple_notification_reconciliation_causes_are_immutable;

DROP TRIGGER billing_apple_notification_reconciliation_causes_cannot_be_deleted;

DROP TRIGGER billing_apple_notification_history_page_commit_requires_lease;

DROP TRIGGER billing_apple_notification_history_page_record_requires_event;

DROP TRIGGER billing_apple_notification_history_page_finalize_requires_advance;

DROP TRIGGER billing_apple_notification_history_recovery_requires_transition;

DROP TRIGGER billing_apple_notification_history_recovery_cannot_be_deleted;

DROP TRIGGER billing_apple_notification_history_page_commits_are_immutable;

DROP TRIGGER billing_apple_notification_history_page_commits_cannot_be_deleted;

DROP TRIGGER billing_apple_notification_history_page_records_are_immutable;

DROP TRIGGER billing_apple_notification_history_page_records_cannot_be_deleted;

DROP TRIGGER billing_apple_notification_history_page_finalizations_are_immutable;

DROP TRIGGER billing_apple_notification_history_page_finalizations_cannot_be_deleted;

DROP TRIGGER billing_window_support_request_validate;

DROP TRIGGER billing_window_support_approval_validate;

DROP TRIGGER billing_window_support_commit_validate;

DROP TRIGGER billing_window_support_commit_apply;

DROP TRIGGER group_creation_policy;

DROP TRIGGER group_delivery_policy;

DROP TRIGGER family_notebook_payer_event_validate;

DROP TRIGGER family_notebook_admission_validate;

DROP TRIGGER family_notebook_crypto_check_validate;

DROP TRIGGER family_notebook_governance_validate;

DROP VIEW billing_window_support_live_requests;

DROP VIEW group_verified_plus_people;

DROP TABLE billing_window_sponsorships;

DROP TABLE billing_window_sponsorship_requests;

DROP TABLE billing_transaction_events;

DROP TABLE billing_reconciliation_jobs;

DROP TABLE billing_effective_entitlement_current;

DROP TABLE billing_effective_entitlement_decisions;

DROP TABLE billing_subscription_authority_observations;

DROP TABLE billing_apple_notification_reconciliation_causes;

DROP TABLE billing_apple_notification_history_recovery;

DROP TABLE billing_apple_notification_history_page_records;

DROP TABLE billing_apple_notification_history_page_finalizations;

DROP TABLE billing_apple_notification_history_page_commits;

DROP TABLE billing_apple_notification_events;

DROP TABLE billing_account_recovery_requests;

DROP TABLE billing_account_apple_identities;

DROP TABLE billing_transaction_lineages;

ALTER TABLE billing_transaction_lineages__new RENAME TO billing_transaction_lineages;

ALTER TABLE billing_account_apple_identities__new RENAME TO billing_account_apple_identities;

ALTER TABLE billing_account_recovery_requests__new RENAME TO billing_account_recovery_requests;

ALTER TABLE billing_apple_notification_events__new RENAME TO billing_apple_notification_events;

ALTER TABLE billing_apple_notification_history_page_commits__new RENAME TO billing_apple_notification_history_page_commits;

ALTER TABLE billing_apple_notification_history_page_finalizations__new RENAME TO billing_apple_notification_history_page_finalizations;

ALTER TABLE billing_apple_notification_history_page_records__new RENAME TO billing_apple_notification_history_page_records;

ALTER TABLE billing_apple_notification_history_recovery__new RENAME TO billing_apple_notification_history_recovery;

ALTER TABLE billing_apple_notification_reconciliation_causes__new RENAME TO billing_apple_notification_reconciliation_causes;

ALTER TABLE billing_subscription_authority_observations__new RENAME TO billing_subscription_authority_observations;

ALTER TABLE billing_effective_entitlement_decisions__new RENAME TO billing_effective_entitlement_decisions;

ALTER TABLE billing_effective_entitlement_current__new RENAME TO billing_effective_entitlement_current;

ALTER TABLE billing_reconciliation_jobs__new RENAME TO billing_reconciliation_jobs;

ALTER TABLE billing_transaction_events__new RENAME TO billing_transaction_events;

ALTER TABLE billing_window_sponsorship_requests__new RENAME TO billing_window_sponsorship_requests;

ALTER TABLE billing_window_sponsorships__new RENAME TO billing_window_sponsorships;

CREATE INDEX billing_transaction_events_lineage_order
    ON billing_transaction_events(environment, original_transaction_id, signed_date_ms DESC);

CREATE INDEX billing_transaction_events_account_order
    ON billing_transaction_events(billing_account_id, signed_date_ms DESC);

CREATE INDEX billing_apple_notifications_lineage_order
    ON billing_apple_notification_events(environment, original_transaction_id, signed_date_ms DESC)
    WHERE original_transaction_id IS NOT NULL;

CREATE INDEX billing_reconciliation_jobs_due
    ON billing_reconciliation_jobs(not_before, requested_at, original_transaction_id);

CREATE INDEX billing_authority_account_order
    ON billing_subscription_authority_observations(
      billing_account_id, fetched_at_ms DESC, observation_fingerprint DESC
    );

CREATE INDEX billing_authority_lineage_order
    ON billing_subscription_authority_observations(
      original_transaction_id, fetched_at_ms DESC, observation_fingerprint DESC
    );

CREATE INDEX billing_entitlement_decisions_lineage_order
    ON billing_effective_entitlement_decisions(
      original_transaction_id, evaluated_at_ms DESC, decision_id DESC
    );

CREATE INDEX billing_entitlement_current_account_order
    ON billing_effective_entitlement_current(
      billing_account_id, source_fetched_at_ms DESC, original_transaction_id
    );

CREATE INDEX billing_window_sponsorship_account_active ON billing_window_sponsorships(billing_account_id,window_lineage_id) WHERE state='active';

CREATE UNIQUE INDEX billing_window_sponsorship_last_owner_detach
 ON billing_window_sponsorships(last_owner_detach_request_id)
 WHERE last_owner_detach_request_id IS NOT NULL;

CREATE UNIQUE INDEX billing_apple_notification_history_cursor_once_per_generation
    ON billing_apple_notification_history_page_commits(environment, generation, next_cursor_hash)
    WHERE next_cursor_hash IS NOT NULL;

CREATE VIEW billing_window_support_live_requests AS
SELECT r.* FROM billing_window_support_requests r
 JOIN moment_spaces s ON s.space_id=r.space_id AND s.lineage_id=r.window_lineage_id
 JOIN spaces legacy ON legacy.id=s.space_id
 JOIN members m ON m.id=r.requester_member_id AND m.space_id=r.space_id
 JOIN moment_participants p ON p.id=r.requester_participant_id AND p.legacy_member_id=m.id AND p.space_id=s.space_id
 JOIN moment_devices d ON d.id=r.requester_device_id AND d.participant_id=p.id
 JOIN billing_account_keys k ON k.id=r.billing_key_id AND k.billing_account_id=r.billing_account_id
 JOIN billing_runtime_gate gate ON gate.singleton=1
 LEFT JOIN billing_window_sponsorships sponsor ON sponsor.window_lineage_id=r.window_lineage_id
WHERE gate.window_sponsorship_enabled=1 AND gate.effective_entitlement_enabled=1
 AND s.state='active' AND legacy.state='active' AND m.state='active' AND p.state='active' AND d.state='active' AND k.state='active'
 AND p.role=(CASE m.role WHEN 'owner' THEN 'owner' ELSE 'member' END)
 AND s.membership_revision=r.membership_revision AND r.expires_at>unixepoch()
 AND COALESCE(sponsor.generation,0)=r.expected_generation
 AND (CASE WHEN sponsor.state='active' THEN sponsor.billing_account_id END) IS r.expected_current_billing_account_id
 AND NOT EXISTS(SELECT 1 FROM moment_blocks b WHERE b.space_id=r.space_id AND b.state='active')
 AND EXISTS(SELECT 1 FROM billing_effective_entitlement_current c WHERE c.billing_account_id=r.billing_account_id
   AND c.materialized_grants_plus=1 AND c.ownership_type='PURCHASED' AND c.materialized_status IN('active','gracePeriod')
   AND c.revocation_date_ms IS NULL AND c.revocation_reason IS NULL AND c.is_upgraded=0
   AND c.access_until_ms>CAST(unixepoch('subsec')*1000 AS INTEGER) AND c.authority_stale_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER))
 AND (r.expected_current_billing_account_id IS NULL OR (
   NOT EXISTS(SELECT 1 FROM billing_effective_entitlement_current c WHERE c.billing_account_id=r.expected_current_billing_account_id
     AND c.materialized_grants_plus=1 AND c.ownership_type='PURCHASED' AND c.materialized_status IN('active','gracePeriod')
     AND c.revocation_date_ms IS NULL AND c.revocation_reason IS NULL AND c.is_upgraded=0
     AND c.access_until_ms>CAST(unixepoch('subsec')*1000 AS INTEGER) AND c.authority_stale_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER))
   AND (SELECT c.ownership_type='PURCHASED' AND (c.apple_status IN(2,3,5) OR c.revocation_date_ms IS NOT NULL
       OR c.revocation_reason IS NOT NULL OR c.is_upgraded=1
       OR (CASE WHEN c.apple_status=4 THEN c.grace_period_expires_date_ms ELSE c.expires_date_ms END) IS NULL
       OR (CASE WHEN c.apple_status=4 THEN c.grace_period_expires_date_ms ELSE c.expires_date_ms END)<=CAST(unixepoch('subsec')*1000 AS INTEGER))
     FROM billing_effective_entitlement_current c WHERE c.billing_account_id=r.expected_current_billing_account_id
     ORDER BY c.evaluated_at_ms DESC,c.original_transaction_id ASC LIMIT 1)
 ));

CREATE VIEW group_verified_plus_people AS
SELECT DISTINCT link.person_id,authority.environment
FROM group_billing_connections link
JOIN billing_effective_entitlement_current authority ON authority.billing_account_id=link.billing_account_id
JOIN billing_runtime_gate gate ON gate.singleton=1
WHERE gate.effective_entitlement_enabled=1
    AND authority.ownership_type ='PURCHASED'
    AND authority.product_id='jp.nekowidget.plus.monthly'
    AND authority.apple_status IN (1,4)
    AND authority.revocation_date_ms IS NULL AND authority.revocation_reason IS NULL AND authority.is_upgraded=0
    AND (CASE WHEN authority.apple_status=4 THEN authority.grace_period_expires_date_ms ELSE authority.expires_date_ms END)>CAST(unixepoch('subsec')*1000 AS INTEGER)
    AND authority.authority_stale_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER);

CREATE TRIGGER billing_transaction_events_require_matching_submitter
BEFORE INSERT ON billing_transaction_events WHEN NEW.source = 'app'
BEGIN
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM billing_account_keys
     WHERE id = NEW.submitted_by_billing_key_id
       AND billing_account_id = NEW.billing_account_id AND state = 'active'
  ) THEN RAISE(ABORT, 'billing transaction submitter does not own billing account') END);
END;

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

CREATE TRIGGER billing_entitlement_decisions_are_immutable
BEFORE UPDATE ON billing_effective_entitlement_decisions
BEGIN SELECT RAISE(ABORT, 'billing entitlement decisions are immutable'); END;

CREATE TRIGGER billing_entitlement_decisions_cannot_be_deleted
BEFORE DELETE ON billing_effective_entitlement_decisions
BEGIN SELECT RAISE(ABORT, 'billing entitlement decisions cannot be deleted'); END;

CREATE TRIGGER billing_entitlement_decisions_require_claimed_job
BEFORE INSERT ON billing_effective_entitlement_decisions
WHEN NOT EXISTS (
  SELECT 1 FROM billing_reconciliation_jobs
   WHERE environment = NEW.environment AND original_transaction_id = NEW.original_transaction_id
     AND request_generation = NEW.request_generation
     AND lease_token = NEW.lease_token
     AND lease_expires_at > unixepoch()
)
BEGIN SELECT RAISE(ABORT, 'billing entitlement decision requires claimed job'); END;

CREATE TRIGGER billing_entitlement_current_requires_matching_decision_on_insert
BEFORE INSERT ON billing_effective_entitlement_current
WHEN NOT EXISTS (
  SELECT 1 FROM billing_effective_entitlement_decisions AS decision
   WHERE decision.decision_id = NEW.decision_id
     AND decision.observation_fingerprint = NEW.observation_fingerprint
     AND decision.original_transaction_id = NEW.original_transaction_id
     AND decision.billing_account_id = NEW.billing_account_id
     AND decision.environment = NEW.environment
     AND decision.subscription_group_id = NEW.subscription_group_id
     AND decision.ownership_type = NEW.ownership_type
     AND decision.request_generation = NEW.request_generation
     AND decision.lease_token = NEW.lease_token
     AND decision.apple_status = NEW.apple_status
     AND decision.transaction_id = NEW.transaction_id
     AND decision.product_id = NEW.product_id
     AND decision.expires_date_ms = NEW.expires_date_ms
     AND decision.revocation_date_ms IS NEW.revocation_date_ms
     AND decision.revocation_reason IS NEW.revocation_reason
     AND decision.is_upgraded = NEW.is_upgraded
     AND decision.grace_period_expires_date_ms IS NEW.grace_period_expires_date_ms
     AND decision.source_fetched_at_ms = NEW.source_fetched_at_ms
     AND decision.decision_status = NEW.materialized_status
     AND decision.grants_plus = NEW.materialized_grants_plus
     AND decision.access_until_ms IS NEW.access_until_ms
     AND decision.authority_stale_at_ms = NEW.authority_stale_at_ms
     AND decision.evaluated_at_ms = NEW.evaluated_at_ms
)
BEGIN SELECT RAISE(ABORT, 'billing entitlement current requires matching decision'); END;

CREATE TRIGGER billing_entitlement_current_requires_matching_decision_on_update
BEFORE UPDATE ON billing_effective_entitlement_current
WHEN NOT EXISTS (
  SELECT 1 FROM billing_effective_entitlement_decisions AS decision
   WHERE decision.decision_id = NEW.decision_id
     AND decision.observation_fingerprint = NEW.observation_fingerprint
     AND decision.original_transaction_id = NEW.original_transaction_id
     AND decision.billing_account_id = NEW.billing_account_id
     AND decision.environment = NEW.environment
     AND decision.subscription_group_id = NEW.subscription_group_id
     AND decision.ownership_type = NEW.ownership_type
     AND decision.request_generation = NEW.request_generation
     AND decision.lease_token = NEW.lease_token
     AND decision.apple_status = NEW.apple_status
     AND decision.transaction_id = NEW.transaction_id
     AND decision.product_id = NEW.product_id
     AND decision.expires_date_ms = NEW.expires_date_ms
     AND decision.revocation_date_ms IS NEW.revocation_date_ms
     AND decision.revocation_reason IS NEW.revocation_reason
     AND decision.is_upgraded = NEW.is_upgraded
     AND decision.grace_period_expires_date_ms IS NEW.grace_period_expires_date_ms
     AND decision.source_fetched_at_ms = NEW.source_fetched_at_ms
     AND decision.decision_status = NEW.materialized_status
     AND decision.grants_plus = NEW.materialized_grants_plus
     AND decision.access_until_ms IS NEW.access_until_ms
     AND decision.authority_stale_at_ms = NEW.authority_stale_at_ms
     AND decision.evaluated_at_ms = NEW.evaluated_at_ms
)
BEGIN SELECT RAISE(ABORT, 'billing entitlement current requires matching decision'); END;

CREATE TRIGGER billing_entitlement_current_restrict_update
BEFORE UPDATE ON billing_effective_entitlement_current
WHEN NEW.original_transaction_id <> OLD.original_transaction_id
  OR NEW.billing_account_id <> OLD.billing_account_id
  OR NEW.environment <> OLD.environment
  OR NEW.subscription_group_id <> OLD.subscription_group_id
  OR NEW.request_generation < OLD.request_generation
  OR (NEW.request_generation = OLD.request_generation
      AND NEW.evaluated_at_ms < OLD.evaluated_at_ms)
  OR NEW.updated_at <> unixepoch()
BEGIN SELECT RAISE(ABORT, 'invalid billing entitlement current transition'); END;

CREATE TRIGGER billing_recovery_validate_before_insert
BEFORE INSERT ON billing_account_recovery_requests
BEGIN
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM billing_account_key_state
     WHERE billing_account_id = NEW.billing_account_id
       AND generation = NEW.expected_generation
  ) THEN RAISE(ABORT, 'billing recovery generation conflict') END);
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM billing_account_keys
     WHERE id = NEW.replaced_billing_key_id
       AND billing_account_id = NEW.billing_account_id AND state = 'active'
  ) THEN RAISE(ABORT, 'billing recovery active key conflict') END);
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM billing_transaction_lineages
     WHERE environment = NEW.environment AND original_transaction_id = NEW.expected_original_transaction_id
       AND billing_account_id = NEW.billing_account_id
  ) THEN RAISE(ABORT, 'billing recovery lineage conflict') END);
  SELECT (CASE WHEN EXISTS (
    SELECT 1 FROM billing_account_apple_identities
     WHERE environment = NEW.environment AND billing_account_id = NEW.billing_account_id
       AND app_transaction_id_hash <> NEW.app_transaction_id_hash
  ) OR EXISTS (
    SELECT 1 FROM billing_account_apple_identities
     WHERE environment = NEW.environment AND app_transaction_id_hash = NEW.app_transaction_id_hash
       AND billing_account_id <> NEW.billing_account_id
  ) THEN RAISE(ABORT, 'billing recovery Apple identity conflict') END);
  SELECT (CASE WHEN EXISTS (
    SELECT 1 FROM billing_account_keys
     WHERE signing_public_key = NEW.new_signing_public_key
  ) THEN RAISE(ABORT, 'billing recovery signing key conflict') END);
END;

CREATE TRIGGER billing_recovery_rotate_after_insert
AFTER INSERT ON billing_account_recovery_requests
BEGIN
  INSERT OR IGNORE INTO billing_account_apple_identities(
    billing_account_id, app_transaction_id_hash, environment, first_original_transaction_id
  ) VALUES (
    NEW.billing_account_id, NEW.app_transaction_id_hash,
    NEW.environment,
    NEW.expected_original_transaction_id
  );
  UPDATE billing_account_keys SET state = 'revoked', revoked_at = unixepoch()
   WHERE id = NEW.replaced_billing_key_id AND billing_account_id = NEW.billing_account_id
     AND state = 'active';
  INSERT INTO billing_account_keys(
    id, billing_account_id, signing_public_key, state
  ) VALUES (NEW.new_billing_key_id, NEW.billing_account_id, NEW.new_signing_public_key, 'active');
  UPDATE billing_account_key_state
     SET generation = generation + 1, updated_at = unixepoch()
   WHERE billing_account_id = NEW.billing_account_id
     AND generation = NEW.expected_generation;
END;

CREATE TRIGGER billing_account_apple_identities_are_immutable
BEFORE UPDATE ON billing_account_apple_identities
BEGIN SELECT RAISE(ABORT, 'billing Apple identities are immutable'); END;

CREATE TRIGGER billing_account_apple_identities_cannot_be_deleted
BEFORE DELETE ON billing_account_apple_identities
BEGIN SELECT RAISE(ABORT, 'billing Apple identities cannot be deleted'); END;

CREATE TRIGGER billing_account_recovery_requests_are_immutable
BEFORE UPDATE ON billing_account_recovery_requests
BEGIN SELECT RAISE(ABORT, 'billing recovery requests are immutable'); END;

CREATE TRIGGER billing_account_recovery_requests_cannot_be_deleted
BEFORE DELETE ON billing_account_recovery_requests
BEGIN SELECT RAISE(ABORT, 'billing recovery requests cannot be deleted'); END;

CREATE TRIGGER billing_account_key_state_requires_cas
BEFORE UPDATE ON billing_account_key_state
WHEN NEW.billing_account_id <> OLD.billing_account_id
 OR NEW.generation <> OLD.generation + 1
 OR NEW.updated_at <> unixepoch()
 OR NOT EXISTS (
   SELECT 1 FROM billing_account_recovery_requests
    WHERE billing_account_id = OLD.billing_account_id
      AND expected_generation = OLD.generation
 )
BEGIN SELECT RAISE(ABORT, 'billing key state requires generation CAS'); END;

CREATE TRIGGER billing_window_sponsorship_request_validate BEFORE INSERT ON billing_window_sponsorship_requests BEGIN
 SELECT (CASE WHEN NOT EXISTS(
   SELECT 1 FROM billing_runtime_gate
    WHERE singleton=1
      AND window_sponsorship_enabled=1
      AND (NEW.operation='unsponsor' OR effective_entitlement_enabled=1)
 ) THEN RAISE(ABORT,'sponsorship runtime gate closed') END);
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch() THEN RAISE(ABORT,'sponsorship audit requires database time') END);
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM billing_account_keys WHERE id=NEW.submitted_by_billing_key_id AND billing_account_id=NEW.billing_account_id AND state='active') THEN RAISE(ABORT,'active billing key required') END);
 SELECT (CASE WHEN COALESCE((SELECT generation FROM billing_window_sponsorships WHERE window_lineage_id=NEW.window_lineage_id),0)<>NEW.expected_generation THEN RAISE(ABORT,'sponsorship generation conflict') END);
 SELECT (CASE WHEN (SELECT billing_account_id FROM billing_window_sponsorships WHERE window_lineage_id=NEW.window_lineage_id AND state='active') IS NOT NEW.expected_current_billing_account_id THEN RAISE(ABORT,'current sponsor conflict') END);
 SELECT (CASE WHEN NEW.operation='unsponsor' AND (NEW.expected_current_billing_account_id IS NOT NEW.billing_account_id OR NOT EXISTS(SELECT 1 FROM billing_window_sponsorships WHERE window_lineage_id=NEW.window_lineage_id AND state='active' AND billing_account_id=NEW.billing_account_id)) THEN RAISE(ABORT,'unsponsor requires current payer') END);
 SELECT (CASE WHEN NEW.operation='sponsor' AND NOT EXISTS(SELECT 1 FROM moment_spaces s JOIN moment_participants p ON p.space_id=s.space_id JOIN moment_devices d ON d.participant_id=p.id WHERE s.space_id=NEW.consent_space_id AND s.lineage_id=NEW.window_lineage_id AND s.state='active' AND s.membership_revision=NEW.consent_membership_revision AND p.id=NEW.owner_participant_id AND p.role='owner' AND p.state='active' AND d.id=NEW.owner_device_id AND d.state='active' AND NOT EXISTS(SELECT 1 FROM moment_blocks b WHERE b.space_id=s.space_id AND b.state='active')) THEN RAISE(ABORT,'current unblocked owner consent required') END);
 SELECT (CASE WHEN NEW.operation='sponsor' AND (NEW.consent_issued_at<unixepoch()-300 OR NEW.consent_issued_at>unixepoch()+300) THEN RAISE(ABORT,'owner consent stale') END);
 SELECT (CASE WHEN NEW.operation='sponsor' AND (SELECT COUNT(*) FROM billing_window_sponsorships WHERE billing_account_id=NEW.billing_account_id AND state='active' AND window_lineage_id<>NEW.window_lineage_id)>=3 THEN RAISE(ABORT,'sponsorship limit reached') END);
 SELECT (CASE WHEN NEW.operation='sponsor' AND NOT EXISTS(SELECT 1 FROM billing_effective_entitlement_current c JOIN billing_effective_entitlement_decisions d ON d.decision_id=c.decision_id WHERE c.billing_account_id=NEW.billing_account_id AND c.decision_id=NEW.entitlement_decision_id AND c.request_generation=NEW.entitlement_request_generation AND c.evaluated_at_ms=NEW.entitlement_evaluated_at_ms AND c.materialized_grants_plus=1 AND c.ownership_type='PURCHASED' AND c.materialized_status IN('active','gracePeriod') AND c.revocation_date_ms IS NULL AND c.revocation_reason IS NULL AND c.is_upgraded=0 AND c.access_until_ms>unixepoch()*1000 AND c.authority_stale_at_ms>unixepoch()*1000) THEN RAISE(ABORT,'fresh Plus entitlement required') END);
END;

CREATE TRIGGER billing_window_sponsorship_requests_are_immutable BEFORE UPDATE ON billing_window_sponsorship_requests BEGIN SELECT RAISE(ABORT,'sponsorship audit immutable'); END;

CREATE TRIGGER billing_window_sponsorship_requests_cannot_be_deleted BEFORE DELETE ON billing_window_sponsorship_requests BEGIN SELECT RAISE(ABORT,'sponsorship audit cannot be deleted'); END;

CREATE TRIGGER billing_window_sponsorships_cannot_be_deleted BEFORE DELETE ON billing_window_sponsorships BEGIN SELECT RAISE(ABORT,'sponsorship state cannot be deleted'); END;

CREATE TRIGGER billing_window_owner_detach_request_validate
BEFORE INSERT ON billing_window_sponsorship_owner_detach_requests BEGIN
 SELECT (CASE WHEN NOT EXISTS(
   SELECT 1 FROM billing_runtime_gate
    WHERE singleton=1 AND window_sponsorship_enabled=1
 ) THEN RAISE(ABORT,'sponsorship runtime gate closed') END);
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch() THEN RAISE(ABORT,'owner detach audit requires database time') END);
 SELECT (CASE WHEN NOT EXISTS(
   SELECT 1
     FROM billing_window_sponsorships current
    WHERE current.window_lineage_id=NEW.window_lineage_id
      AND current.state='active'
      AND current.generation=NEW.expected_generation
      AND current.billing_account_id=NEW.expected_billing_account_id
 ) THEN RAISE(ABORT,'owner detach sponsorship conflict') END);
 SELECT (CASE WHEN NOT EXISTS(
   SELECT 1
     FROM moment_spaces space
     JOIN moment_participants owner ON owner.space_id=space.space_id
     JOIN moment_devices device ON device.participant_id=owner.id
    WHERE space.space_id=NEW.space_id
      AND space.lineage_id=NEW.window_lineage_id
      AND space.state='active'
      AND space.membership_revision=NEW.membership_revision
      AND owner.id=NEW.owner_participant_id
      AND owner.role='owner'
      AND owner.state='active'
      AND device.id=NEW.owner_device_id
      AND device.state='active'
      AND NOT EXISTS(
        SELECT 1 FROM moment_blocks block
         WHERE block.space_id=space.space_id AND block.state='active'
      )
 ) THEN RAISE(ABORT,'current unblocked owner required') END);
END;

CREATE TRIGGER billing_window_sponsorship_apply
AFTER INSERT ON billing_window_sponsorship_requests BEGIN
 INSERT INTO billing_window_sponsorships(
   window_lineage_id,billing_account_id,state,generation,sponsored_at,
   updated_at,last_request_id,last_owner_detach_request_id
 ) VALUES(
   NEW.window_lineage_id,
   (CASE WHEN NEW.operation='sponsor' THEN NEW.billing_account_id ELSE NULL END),
   (CASE WHEN NEW.operation='sponsor' THEN 'active' ELSE 'unsponsored' END),
   NEW.resulting_generation,
   (CASE WHEN NEW.operation='sponsor' THEN NEW.recorded_at ELSE NULL END),
   NEW.recorded_at,NEW.client_request_id,NULL
 )
 ON CONFLICT(window_lineage_id) DO UPDATE SET
   billing_account_id=excluded.billing_account_id,
   state=excluded.state,
   generation=excluded.generation,
   sponsored_at=(CASE
     WHEN excluded.state='active' THEN excluded.updated_at
     ELSE billing_window_sponsorships.sponsored_at
   END),
   updated_at=excluded.updated_at,
   last_request_id=excluded.last_request_id,
   last_owner_detach_request_id=NULL;
END;

CREATE TRIGGER billing_window_owner_detach_apply
AFTER INSERT ON billing_window_sponsorship_owner_detach_requests BEGIN
 UPDATE billing_window_sponsorships
    SET billing_account_id=NULL,
        state='unsponsored',
        generation=NEW.resulting_generation,
        updated_at=NEW.recorded_at,
        last_owner_detach_request_id=NEW.client_request_id
  WHERE window_lineage_id=NEW.window_lineage_id;
END;

CREATE TRIGGER billing_window_sponsorship_state_validate_insert
BEFORE INSERT ON billing_window_sponsorships
WHEN NEW.last_owner_detach_request_id IS NOT NULL OR NOT EXISTS(
 SELECT 1 FROM billing_window_sponsorship_requests audit
 WHERE audit.client_request_id=NEW.last_request_id
   AND audit.window_lineage_id=NEW.window_lineage_id
   AND audit.resulting_generation=NEW.generation
   AND audit.recorded_at=NEW.updated_at
   AND (
     (audit.operation='sponsor'
       AND audit.billing_account_id=NEW.billing_account_id
       AND NEW.state='active'
       AND audit.recorded_at=NEW.sponsored_at
       AND (
         (audit.expected_generation=0
           AND audit.expected_current_billing_account_id IS NULL
           AND NOT EXISTS(
             SELECT 1 FROM billing_window_sponsorships current
              WHERE current.window_lineage_id=NEW.window_lineage_id
           ))
         OR EXISTS(
           SELECT 1 FROM billing_window_sponsorships current
            WHERE current.window_lineage_id=NEW.window_lineage_id
              AND current.generation=audit.expected_generation
              AND (
                (current.state='active'
                  AND audit.expected_current_billing_account_id IS current.billing_account_id)
                OR
                (current.state='unsponsored'
                  AND audit.expected_current_billing_account_id IS NULL)
              )
         )
       ))
     OR
     (audit.operation='unsponsor'
       AND NEW.state='unsponsored'
       AND NEW.billing_account_id IS NULL
       AND NEW.sponsored_at IS NULL
       AND EXISTS(
         SELECT 1 FROM billing_window_sponsorships current
          WHERE current.window_lineage_id=NEW.window_lineage_id
            AND current.state='active'
            AND current.generation=audit.expected_generation
            AND current.billing_account_id=audit.billing_account_id
            AND audit.expected_current_billing_account_id IS current.billing_account_id
       ))
   )
)
BEGIN SELECT RAISE(ABORT,'sponsorship insert requires exact audit'); END;

CREATE TRIGGER billing_window_sponsorship_state_validate_update
BEFORE UPDATE ON billing_window_sponsorships
WHEN NEW.window_lineage_id<>OLD.window_lineage_id OR NOT (
  (
    NEW.last_owner_detach_request_id IS NULL
    AND EXISTS(
      SELECT 1 FROM billing_window_sponsorship_requests audit
       WHERE audit.client_request_id=NEW.last_request_id
         AND audit.window_lineage_id=OLD.window_lineage_id
         AND audit.expected_generation=OLD.generation
         AND audit.resulting_generation=NEW.generation
         AND audit.recorded_at=NEW.updated_at
         AND (
           (audit.operation='sponsor'
             AND NEW.state='active'
             AND NEW.billing_account_id=audit.billing_account_id
             AND NEW.sponsored_at=audit.recorded_at)
           OR
           (audit.operation='unsponsor'
             AND audit.billing_account_id=OLD.billing_account_id
             AND audit.expected_current_billing_account_id IS OLD.billing_account_id
             AND NEW.state='unsponsored'
             AND NEW.billing_account_id IS NULL
             AND NEW.sponsored_at IS OLD.sponsored_at)
         )
    )
  )
  OR
  (
    NEW.last_request_id IS OLD.last_request_id
    AND NEW.last_owner_detach_request_id IS NOT NULL
    AND EXISTS(
      SELECT 1 FROM billing_window_sponsorship_owner_detach_requests audit
       WHERE audit.client_request_id=NEW.last_owner_detach_request_id
         AND audit.window_lineage_id=OLD.window_lineage_id
         AND audit.expected_generation=OLD.generation
         AND audit.resulting_generation=NEW.generation
         AND audit.expected_billing_account_id IS OLD.billing_account_id
         AND audit.recorded_at=NEW.updated_at
         AND OLD.state='active'
         AND NEW.state='unsponsored'
         AND NEW.billing_account_id IS NULL
         AND NEW.sponsored_at IS OLD.sponsored_at
    )
  )
)
BEGIN SELECT RAISE(ABORT,'sponsorship update requires exact audit'); END;

CREATE TRIGGER billing_apple_notification_reconciliation_cause_matches_event
BEFORE INSERT ON billing_apple_notification_reconciliation_causes
WHEN NEW.requested_at <> unixepoch()
  OR NOT EXISTS (
    SELECT 1
      FROM billing_apple_notification_events AS event
      JOIN billing_transaction_lineages AS lineage
        ON lineage.original_transaction_id = event.original_transaction_id
     WHERE event.environment = NEW.environment AND event.notification_uuid = NEW.notification_uuid
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

CREATE TRIGGER billing_apple_notification_reconciliation_cause_queues_once
AFTER INSERT ON billing_apple_notification_reconciliation_causes
BEGIN
  INSERT INTO billing_reconciliation_jobs(
    environment, original_transaction_id, requested_at, not_before, request_generation
  ) VALUES (NEW.environment, NEW.original_transaction_id, NEW.requested_at, NEW.requested_at, COALESCE((SELECT request_generation + 1 FROM billing_effective_entitlement_current WHERE environment = NEW.environment AND original_transaction_id = NEW.original_transaction_id), 1))
  ON CONFLICT(environment, original_transaction_id) DO UPDATE SET
    requested_at = MAX(billing_reconciliation_jobs.requested_at, excluded.requested_at),
    not_before = MIN(billing_reconciliation_jobs.not_before, excluded.not_before),
    request_generation = MAX(billing_reconciliation_jobs.request_generation + 1, excluded.request_generation),
    updated_at = unixepoch();
END;

CREATE TRIGGER billing_apple_notification_reconciliation_causes_are_immutable
BEFORE UPDATE ON billing_apple_notification_reconciliation_causes
BEGIN SELECT RAISE(ABORT, 'notification reconciliation causes are immutable'); END;

CREATE TRIGGER billing_apple_notification_reconciliation_causes_cannot_be_deleted
BEFORE DELETE ON billing_apple_notification_reconciliation_causes
BEGIN SELECT RAISE(ABORT, 'notification reconciliation causes cannot be deleted'); END;

CREATE TRIGGER billing_apple_notification_history_page_commit_requires_lease
BEFORE INSERT ON billing_apple_notification_history_page_commits
WHEN NOT EXISTS (
  SELECT 1
    FROM billing_apple_notification_history_recovery AS recovery
   WHERE recovery.environment = NEW.environment
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
          WHERE previous.environment = NEW.environment AND previous.generation = NEW.generation
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

CREATE TRIGGER billing_apple_notification_history_page_record_requires_event
BEFORE INSERT ON billing_apple_notification_history_page_records
WHEN NOT EXISTS (
  SELECT 1
    FROM billing_apple_notification_history_page_commits AS page
    JOIN billing_apple_notification_history_recovery AS recovery
      ON recovery.environment = NEW.environment
     AND recovery.generation = page.generation
    JOIN billing_apple_notification_events AS event
      ON event.environment = NEW.environment AND event.notification_uuid = NEW.notification_uuid
     AND event.payload_hash = NEW.payload_hash
   WHERE page.environment = NEW.environment AND page.generation = NEW.generation
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
          WHERE cause.environment = event.environment AND cause.notification_uuid = event.notification_uuid
            AND cause.original_transaction_id = event.original_transaction_id
       )
     )
)
BEGIN SELECT RAISE(ABORT, 'notification history page record requires durable event'); END;

CREATE TRIGGER billing_apple_notification_history_page_finalize_requires_advance
BEFORE INSERT ON billing_apple_notification_history_page_finalizations
WHEN NOT EXISTS (
  SELECT 1
    FROM billing_apple_notification_history_page_commits AS page
    JOIN billing_apple_notification_history_recovery AS recovery
      ON recovery.environment = NEW.environment
    JOIN billing_runtime_gate AS gate ON gate.singleton = 1
   WHERE page.environment = NEW.environment AND page.generation = NEW.generation
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
        WHERE record.environment = page.environment AND record.generation = page.generation
          AND record.page_index = page.page_index
     ) = page.record_count
     AND gate.apple_notification_history_recovery_enabled = 1
     AND gate.generation = page.gate_generation
)
BEGIN SELECT RAISE(ABORT, 'notification history page advance was not finalized'); END;

CREATE TRIGGER billing_apple_notification_history_recovery_requires_transition
BEFORE UPDATE ON billing_apple_notification_history_recovery
WHEN NEW.environment <> OLD.environment OR NEW.updated_at <> unixepoch()
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
             WHERE page.environment = NEW.environment AND page.generation = NEW.generation
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

CREATE TRIGGER billing_window_support_request_validate AFTER INSERT ON billing_window_support_requests BEGIN
 SELECT (CASE WHEN NEW.created_at<>unixepoch() OR NOT EXISTS(SELECT 1 FROM billing_window_support_live_requests WHERE id=NEW.id)
   THEN RAISE(ABORT,'invalid support request context') END);
END;

CREATE TRIGGER billing_window_support_approval_validate BEFORE INSERT ON billing_window_support_approvals BEGIN
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch() OR NOT EXISTS(
   SELECT 1 FROM billing_window_support_live_requests r
    JOIN moment_participants p ON p.space_id=r.space_id AND p.id=NEW.owner_participant_id AND p.role='owner' AND p.state='active'
    JOIN moment_devices d ON d.participant_id=p.id AND d.id=NEW.owner_device_id AND d.state='active'
   WHERE r.id=NEW.request_id)
   THEN RAISE(ABORT,'invalid support approval context') END);
END;

CREATE TRIGGER billing_window_support_commit_validate BEFORE INSERT ON billing_window_support_commits BEGIN
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch() OR NOT EXISTS(
   SELECT 1 FROM billing_window_support_live_requests r JOIN billing_window_support_approvals a ON a.request_id=r.id
    JOIN moment_participants p ON p.space_id=r.space_id AND p.id=a.owner_participant_id AND p.role='owner' AND p.state='active'
    JOIN moment_devices d ON d.participant_id=p.id AND d.id=a.owner_device_id AND d.state='active'
   WHERE r.id=NEW.request_id AND a.recorded_at>unixepoch()-300)
   THEN RAISE(ABORT,'invalid support commit context') END);
END;

CREATE TRIGGER billing_window_support_commit_apply AFTER INSERT ON billing_window_support_commits BEGIN
 INSERT INTO billing_window_sponsorship_requests(
   client_request_id,request_hash,operation,billing_account_id,submitted_by_billing_key_id,window_lineage_id,
   expected_generation,expected_current_billing_account_id,consent_space_id,owner_participant_id,owner_device_id,
   consent_membership_revision,consent_issued_at,owner_consent_nonce_hash,owner_consent_hash,
   entitlement_decision_id,entitlement_request_generation,entitlement_evaluated_at_ms,resulting_generation)
 SELECT NEW.client_request_id,NEW.request_hash,'sponsor',r.billing_account_id,r.billing_key_id,r.window_lineage_id,
   r.expected_generation,r.expected_current_billing_account_id,r.space_id,a.owner_participant_id,a.owner_device_id,
   r.membership_revision,a.recorded_at,a.consent_nonce_hash,a.consent_hash,
   c.decision_id,c.request_generation,c.evaluated_at_ms,r.expected_generation+1
 FROM billing_window_support_requests r JOIN billing_window_support_approvals a ON a.request_id=r.id
 JOIN billing_effective_entitlement_current c ON c.billing_account_id=r.billing_account_id
 WHERE r.id=NEW.request_id AND c.materialized_grants_plus=1 AND c.ownership_type='PURCHASED'
   AND c.materialized_status IN('active','gracePeriod') AND c.revocation_date_ms IS NULL AND c.revocation_reason IS NULL
   AND c.is_upgraded=0 AND c.access_until_ms>CAST(unixepoch('subsec')*1000 AS INTEGER)
   AND c.authority_stale_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER)
 ORDER BY MIN(c.access_until_ms,c.authority_stale_at_ms) DESC,c.original_transaction_id ASC LIMIT 1;
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM billing_window_sponsorship_requests WHERE client_request_id=NEW.client_request_id)
   THEN RAISE(ABORT,'support commit was not applied') END);
END;

CREATE TRIGGER group_creation_policy BEFORE INSERT ON group_creation_policy_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_windows WHERE space_id=NEW.space_id AND owner_person_id=NEW.owner_person_id)
        THEN RAISE(ABORT,'group_billing_connection_invalid') END);
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_members WHERE person_id=NEW.owner_person_id AND role='owner' AND state='active')>5
        THEN RAISE(ABORT,'group_owned_window_limit') END);
    SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.owner_person_id AND environment=NEW.store_environment)
        THEN RAISE(ABORT,'group_owner_plus_required') END);
END;

CREATE TRIGGER group_delivery_policy BEFORE INSERT ON group_delivery_policy_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_window_owner_policy w JOIN group_verified_plus_people p ON p.person_id=w.owner_person_id
        WHERE w.space_id=NEW.space_id AND p.environment=NEW.store_environment)
        THEN RAISE(ABORT,'group_window_paused') END);
END;

CREATE TRIGGER family_notebook_payer_event_validate BEFORE INSERT ON family_notebook_payer_events
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NEW.recorded_at<>unixepoch()
    THEN RAISE(ABORT,'family_notebook_invalid_time') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.actor_device_id AND d.person_id=NEW.actor_person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE f.id=NEW.family_id AND f.state='active' AND m.person_id=NEW.actor_person_id AND m.state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN (SELECT generation FROM family_notebook_spaces WHERE id=NEW.family_id)<>NEW.expected_generation
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.operation='claim' AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces f JOIN family_notebook_members m ON m.family_id=f.id
    WHERE f.id=NEW.family_id AND f.payer_person_id IS NULL AND f.nominated_person_id IS NULL
      AND m.person_id=NEW.actor_person_id AND m.state='active'
      AND m.admitted_generation<=f.payer_absent_since_generation)
    THEN RAISE(ABORT,'family_notebook_claim_unavailable') END);
  -- The verified authority view rechecks revocation, expiry, grace, current
  -- environment and lower billing gate at COMMIT time. Neither a local Plus
  -- boolean nor a billing connection alone is evidence of paid membership.
  SELECT (CASE WHEN NEW.operation='claim' AND NOT EXISTS(
    SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.actor_person_id AND environment=NEW.store_environment)
    THEN RAISE(ABORT,'family_notebook_plus_required') END);
END;

CREATE TRIGGER family_notebook_admission_validate BEFORE INSERT ON family_notebook_admission_events
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NEW.recorded_at<>unixepoch() OR NOT EXISTS(
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.actor_device_id AND d.person_id=NEW.actor_person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NEW.operation='create' AND (NEW.expected_generation<>0 OR EXISTS(
    SELECT 1 FROM family_notebook_spaces WHERE id=NEW.family_id))
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.operation<>'create' AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces WHERE id=NEW.family_id AND state='active' AND generation=NEW.expected_generation)
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  -- The unique-family rule is checked inside the same serialized transaction
  -- as admission, including races between invitations to different families.
  SELECT (CASE WHEN NEW.operation IN ('create','join') AND EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE m.person_id=NEW.actor_person_id AND m.state='active' AND f.state='active')
    THEN RAISE(ABORT,'family_notebook_already_in_family') END);
  SELECT (CASE WHEN NEW.operation NOT IN ('create','join') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_members WHERE family_id=NEW.family_id AND person_id=NEW.actor_person_id AND state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN NEW.operation='create' AND NOT EXISTS(
    SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.actor_person_id AND environment=NEW.store_environment)
    THEN RAISE(ABORT,'family_notebook_plus_required') END);
  SELECT (CASE WHEN NEW.operation IN ('invite','join','approve') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces f JOIN group_verified_plus_people p ON p.person_id=f.payer_person_id
    WHERE f.id=NEW.family_id AND p.environment=NEW.store_environment)
    THEN RAISE(ABORT,'family_notebook_paused') END);
  SELECT (CASE WHEN NEW.operation='join' AND NOT EXISTS(
    SELECT 1 FROM family_notebook_invitations i JOIN family_notebook_members m
      ON m.family_id=i.family_id AND m.person_id=i.creator_person_id
      JOIN group_person_devices d ON d.id=i.creator_device_id
      JOIN group_people p ON p.id=i.creator_person_id
    WHERE i.id=NEW.invitation_id AND i.family_id=NEW.family_id AND i.state='active'
      AND i.expires_at>unixepoch() AND m.state='active' AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invitation_unavailable') END);
  SELECT (CASE WHEN NEW.operation='revoke' AND NOT EXISTS(
    SELECT 1 FROM family_notebook_invitations i JOIN family_notebook_spaces f ON f.id=i.family_id
    WHERE i.id=NEW.invitation_id AND i.family_id=NEW.family_id
      AND (i.creator_person_id=NEW.actor_person_id OR f.payer_person_id=NEW.actor_person_id))
    THEN RAISE(ABORT,'family_notebook_not_allowed') END);
  SELECT (CASE WHEN NEW.operation IN ('approve','reject') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_join_requests j JOIN family_notebook_invitations i ON i.id=j.invitation_id
      JOIN family_notebook_spaces f ON f.id=j.family_id
      JOIN family_notebook_members m ON m.family_id=f.id AND m.person_id=i.creator_person_id
      JOIN group_people inviter ON inviter.id=i.creator_person_id
      JOIN group_person_devices inviter_device ON inviter_device.id=i.creator_device_id
      JOIN group_people p ON p.id=j.person_id JOIN group_person_devices d ON d.id=j.device_id AND d.person_id=j.person_id
    WHERE j.id=NEW.join_id AND j.family_id=NEW.family_id AND j.state='pending' AND j.expires_at>unixepoch()
      AND i.state='used' AND m.state='active' AND p.state='active' AND d.state='active'
      AND inviter.state='active' AND inviter_device.state='active'
      AND (i.creator_person_id=NEW.actor_person_id OR f.payer_person_id=NEW.actor_person_id))
    THEN RAISE(ABORT,'family_notebook_request_not_pending') END);
  SELECT (CASE WHEN NEW.operation='approve' AND EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE m.person_id=(SELECT person_id FROM family_notebook_join_requests WHERE id=NEW.join_id)
      AND m.state='active' AND f.state='active')
    THEN RAISE(ABORT,'family_notebook_already_in_family') END);
  SELECT (CASE WHEN NEW.operation='approve' AND (
    SELECT COUNT(*) FROM family_notebook_members WHERE family_id=NEW.family_id AND state='active')>=NEW.maximum_members
    THEN RAISE(ABORT,'family_notebook_member_limit') END);
  SELECT (CASE WHEN NEW.operation='invite' AND (
    SELECT COUNT(*) FROM family_notebook_invitations WHERE family_id=NEW.family_id AND state='active' AND expires_at>unixepoch())>=32
    THEN RAISE(ABORT,'family_notebook_rate_limited') END);
END;

CREATE TRIGGER family_notebook_crypto_check_validate BEFORE INSERT ON family_notebook_crypto_checks
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.device_id AND d.person_id=NEW.person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE m.family_id=NEW.family_id AND m.person_id=NEW.person_id AND m.state='active' AND f.state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN (SELECT generation FROM family_notebook_spaces WHERE id=NEW.family_id)<>NEW.generation
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.epoch IS NOT NULL AND COALESCE((SELECT epoch FROM family_notebook_crypto_heads WHERE family_id=NEW.family_id),0)<>NEW.epoch
    THEN RAISE(ABORT,'family_notebook_crypto_stale') END);
  SELECT (CASE WHEN NEW.mode IN ('key','operation','ready') AND NOT EXISTS (
    SELECT 1 FROM family_notebook_crypto_ready WHERE family_id=NEW.family_id)
    THEN RAISE(ABORT,'family_notebook_crypto_stale') END);
  SELECT (CASE WHEN NEW.mode='operation' AND NOT EXISTS (
    SELECT 1 FROM family_notebook_spaces f JOIN group_verified_plus_people p ON p.person_id=f.payer_person_id
    WHERE f.id=NEW.family_id AND p.environment=NEW.store_environment)
    THEN RAISE(ABORT,'family_notebook_paused') END);
END;

CREATE TRIGGER family_notebook_governance_validate BEFORE INSERT ON family_notebook_governance_events
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NEW.recorded_at<>unixepoch() THEN RAISE(ABORT,'family_notebook_invalid_time') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.actor_device_id AND d.person_id=NEW.actor_person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE m.family_id=NEW.family_id AND m.person_id=NEW.actor_person_id AND m.state='active' AND f.state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN (SELECT generation FROM family_notebook_spaces WHERE id=NEW.family_id)<>NEW.expected_generation
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.action IN ('remove','dissolve','nominate') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces WHERE id=NEW.family_id AND payer_person_id=NEW.actor_person_id)
    THEN RAISE(ABORT,'family_notebook_not_allowed') END);
  SELECT (CASE WHEN NEW.action IN ('remove','nominate') AND (NEW.target_person_id=NEW.actor_person_id OR NOT EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN group_people p ON p.id=m.person_id
    WHERE m.family_id=NEW.family_id AND m.person_id=NEW.target_person_id AND m.state='active'
      AND (NEW.action='remove' OR p.state='active')))
    THEN RAISE(ABORT,'family_notebook_not_allowed') END);
  SELECT (CASE WHEN NEW.action='nominate' AND (
    NEW.nomination_id<>NEW.operation_id OR EXISTS(SELECT 1 FROM family_notebook_handover_current WHERE family_id=NEW.family_id)
    OR (SELECT nominated_person_id FROM family_notebook_spaces WHERE id=NEW.family_id) IS NOT NULL)
    THEN RAISE(ABORT,'family_notebook_nomination_changed') END);
  SELECT (CASE WHEN NEW.action IN ('accept','cancel') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_handover_current h JOIN family_notebook_spaces f ON f.id=h.family_id
      JOIN family_notebook_members m ON m.family_id=h.family_id AND m.person_id=h.nominee_person_id
    WHERE h.family_id=NEW.family_id AND h.nomination_id=NEW.nomination_id AND h.nominee_person_id=NEW.target_person_id
      AND f.nominated_person_id=h.nominee_person_id AND m.state='active'
      AND ((NEW.action='accept' AND h.nominee_person_id=NEW.actor_person_id)
        OR (NEW.action='cancel' AND (f.payer_person_id=NEW.actor_person_id OR h.nominee_person_id=NEW.actor_person_id))))
    THEN RAISE(ABORT,'family_notebook_nomination_changed') END);
  SELECT (CASE WHEN NEW.action='accept' AND NOT EXISTS(
    SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.actor_person_id AND environment=NEW.store_environment)
    THEN RAISE(ABORT,'family_notebook_plus_required') END);
END;

CREATE TRIGGER billing_apple_notification_history_page_commits_legacy_0061_no_insert BEFORE INSERT ON billing_apple_notification_history_page_commits_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_commits_legacy_0061_no_update BEFORE UPDATE ON billing_apple_notification_history_page_commits_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_commits_legacy_0061_no_delete BEFORE DELETE ON billing_apple_notification_history_page_commits_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_finalizations_legacy_0061_no_insert BEFORE INSERT ON billing_apple_notification_history_page_finalizations_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_finalizations_legacy_0061_no_update BEFORE UPDATE ON billing_apple_notification_history_page_finalizations_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_finalizations_legacy_0061_no_delete BEFORE DELETE ON billing_apple_notification_history_page_finalizations_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_records_legacy_0061_no_insert BEFORE INSERT ON billing_apple_notification_history_page_records_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_records_legacy_0061_no_update BEFORE UPDATE ON billing_apple_notification_history_page_records_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_page_records_legacy_0061_no_delete BEFORE DELETE ON billing_apple_notification_history_page_records_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_recovery_legacy_0061_no_insert BEFORE INSERT ON billing_apple_notification_history_recovery_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_recovery_legacy_0061_no_update BEFORE UPDATE ON billing_apple_notification_history_recovery_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

CREATE TRIGGER billing_apple_notification_history_recovery_legacy_0061_no_delete BEFORE DELETE ON billing_apple_notification_history_recovery_legacy_0061 BEGIN SELECT RAISE(ABORT, 'legacy history is immutable'); END;

DROP TABLE billing_environment_migration_guard;
