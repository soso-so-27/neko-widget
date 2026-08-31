PRAGMA foreign_keys = ON;

ALTER TABLE billing_runtime_gate
  ADD COLUMN account_recovery_enabled INTEGER NOT NULL DEFAULT 0
  CHECK (account_recovery_enabled IN (0, 1));

CREATE TABLE billing_account_apple_identities (
    billing_account_id TEXT PRIMARY KEY REFERENCES billing_accounts(id) ON DELETE RESTRICT,
    app_transaction_id_hash TEXT NOT NULL UNIQUE CHECK (
      length(app_transaction_id_hash) = 43
      AND app_transaction_id_hash NOT GLOB '*[^A-Za-z0-9_-]*'
      AND substr(app_transaction_id_hash, 43, 1) GLOB '[AEIMQUYcgkosw048]'
    ),
    environment TEXT NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    first_original_transaction_id TEXT NOT NULL
      REFERENCES billing_transaction_lineages(original_transaction_id) ON DELETE RESTRICT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE TABLE billing_account_key_state (
    billing_account_id TEXT PRIMARY KEY REFERENCES billing_accounts(id) ON DELETE RESTRICT,
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;
INSERT INTO billing_account_key_state(billing_account_id) SELECT id FROM billing_accounts;

CREATE TRIGGER billing_accounts_initialize_key_state
AFTER INSERT ON billing_accounts
BEGIN
  INSERT INTO billing_account_key_state(billing_account_id) VALUES (NEW.id);
END;

CREATE TABLE billing_account_recovery_requests (
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
    expected_original_transaction_id TEXT NOT NULL
      REFERENCES billing_transaction_lineages(original_transaction_id) ON DELETE RESTRICT,
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
    recovered_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE TRIGGER billing_recovery_validate_before_insert
BEFORE INSERT ON billing_account_recovery_requests
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM billing_account_key_state
     WHERE billing_account_id = NEW.billing_account_id
       AND generation = NEW.expected_generation
  ) THEN RAISE(ABORT, 'billing recovery generation conflict') END;
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM billing_account_keys
     WHERE id = NEW.replaced_billing_key_id
       AND billing_account_id = NEW.billing_account_id AND state = 'active'
  ) THEN RAISE(ABORT, 'billing recovery active key conflict') END;
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM billing_transaction_lineages
     WHERE original_transaction_id = NEW.expected_original_transaction_id
       AND billing_account_id = NEW.billing_account_id
  ) THEN RAISE(ABORT, 'billing recovery lineage conflict') END;
  SELECT CASE WHEN EXISTS (
    SELECT 1 FROM billing_account_apple_identities
     WHERE billing_account_id = NEW.billing_account_id
       AND app_transaction_id_hash <> NEW.app_transaction_id_hash
  ) OR EXISTS (
    SELECT 1 FROM billing_account_apple_identities
     WHERE app_transaction_id_hash = NEW.app_transaction_id_hash
       AND billing_account_id <> NEW.billing_account_id
  ) THEN RAISE(ABORT, 'billing recovery Apple identity conflict') END;
  SELECT CASE WHEN EXISTS (
    SELECT 1 FROM billing_account_keys
     WHERE signing_public_key = NEW.new_signing_public_key
  ) THEN RAISE(ABORT, 'billing recovery signing key conflict') END;
END;

CREATE TRIGGER billing_recovery_rotate_after_insert
AFTER INSERT ON billing_account_recovery_requests
BEGIN
  INSERT OR IGNORE INTO billing_account_apple_identities(
    billing_account_id, app_transaction_id_hash, environment, first_original_transaction_id
  ) VALUES (
    NEW.billing_account_id, NEW.app_transaction_id_hash,
    (SELECT environment FROM billing_transaction_lineages
      WHERE original_transaction_id = NEW.expected_original_transaction_id),
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
CREATE TRIGGER billing_account_key_state_cannot_be_deleted
BEFORE DELETE ON billing_account_key_state
BEGIN SELECT RAISE(ABORT, 'billing key state cannot be deleted'); END;
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
