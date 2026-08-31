PRAGMA foreign_keys = ON;

-- Reading an effective Plus decision is independently bounded. Enabling
-- bootstrap, transaction intake, notifications or reconciliation never opens
-- this path by implication.
ALTER TABLE billing_runtime_gate
  ADD COLUMN effective_entitlement_enabled INTEGER NOT NULL DEFAULT 0
  CHECK (effective_entitlement_enabled IN (0, 1));

-- 0020 predates effective entitlement decisions. Existing observations stay
-- usable as audit evidence but cannot grant until a new reconciliation records
-- the verified ownership type explicitly.
ALTER TABLE billing_subscription_authority_observations
  ADD COLUMN ownership_type TEXT
  CHECK (ownership_type IN ('PURCHASED', 'FAMILY_SHARED'));

-- Every materialized decision has an immutable audit record. A decision is
-- inserted only while the reconciliation generation and lease are still the
-- claimed job, so a late response cannot become current authority.
CREATE TABLE billing_effective_entitlement_decisions (
    decision_id TEXT PRIMARY KEY CHECK (
      length(decision_id) = 22 AND decision_id NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    observation_fingerprint TEXT NOT NULL
      REFERENCES billing_subscription_authority_observations(observation_fingerprint)
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
    ) REFERENCES billing_transaction_lineages(
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

CREATE INDEX billing_entitlement_decisions_lineage_order
    ON billing_effective_entitlement_decisions(
      original_transaction_id, evaluated_at_ms DESC, decision_id DESC
    );

-- This is the only mutable entitlement table. It is a cache of the latest
-- fenced decision, never a source independent of its immutable audit row.
CREATE TABLE billing_effective_entitlement_current (
    original_transaction_id TEXT PRIMARY KEY,
    billing_account_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    subscription_group_id TEXT NOT NULL,
    decision_id TEXT NOT NULL UNIQUE
      REFERENCES billing_effective_entitlement_decisions(decision_id) ON DELETE RESTRICT,
    observation_fingerprint TEXT NOT NULL
      REFERENCES billing_subscription_authority_observations(observation_fingerprint)
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
    ) REFERENCES billing_transaction_lineages(
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
    )
) STRICT;

CREATE INDEX billing_entitlement_current_account_order
    ON billing_effective_entitlement_current(
      billing_account_id, source_fetched_at_ms DESC, original_transaction_id
    );

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
   WHERE original_transaction_id = NEW.original_transaction_id
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
