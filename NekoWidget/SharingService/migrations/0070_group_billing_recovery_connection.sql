PRAGMA foreign_keys = ON;

-- A successful, device-bound Apple recovery authorizes one connection move.
-- Keep no person, Apple transaction ID, receipt, or key material in its tombstone.
CREATE TABLE group_billing_recovery_uses (
    billing_key_id TEXT PRIMARY KEY REFERENCES billing_account_keys(id),
    billing_account_id TEXT NOT NULL REFERENCES billing_accounts(id),
    generation INTEGER NOT NULL CHECK (generation > 0),
    consumed_at INTEGER NOT NULL CHECK (consumed_at > 0),
    UNIQUE (billing_account_id, generation)
) STRICT;
CREATE TRIGGER group_billing_recovery_use_authority BEFORE INSERT ON group_billing_recovery_uses
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM billing_account_recovery_requests r
        JOIN billing_account_keys k ON k.id=r.new_billing_key_id AND k.billing_account_id=r.billing_account_id
        JOIN billing_account_key_state s ON s.billing_account_id=r.billing_account_id
        WHERE r.billing_account_id=NEW.billing_account_id AND r.new_billing_key_id=NEW.billing_key_id
            AND k.state='active' AND s.generation=NEW.generation AND r.expected_generation+1=s.generation
    ) THEN RAISE(ABORT,'group_billing_connection_recovery_denied') END);
END;
CREATE TRIGGER group_billing_recovery_use_immutable BEFORE UPDATE ON group_billing_recovery_uses
BEGIN SELECT RAISE(ABORT,'group_billing_connection_recovery_denied'); END;
CREATE TRIGGER group_billing_recovery_use_retained BEFORE DELETE ON group_billing_recovery_uses
BEGIN SELECT RAISE(ABORT,'group_billing_connection_recovery_denied'); END;

-- The command, billing nonce and group authorization recheck share one batch.
-- The group nonce was already claimed before the handler and stays consumed
-- on failure. The caller deletes this command in the batch; no person/device
-- history is retained here.
CREATE TABLE group_billing_recovery_commands (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    billing_account_id TEXT NOT NULL,
    billing_key_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;
CREATE TRIGGER group_billing_recovery_command_authority BEFORE INSERT ON group_billing_recovery_commands
BEGIN
    SELECT (CASE WHEN EXISTS (
        SELECT 1 FROM group_billing_recovery_uses WHERE billing_key_id=NEW.billing_key_id
    ) OR EXISTS (
        SELECT 1 FROM group_billing_connections WHERE person_id=NEW.person_id AND billing_account_id<>NEW.billing_account_id
    ) OR NOT EXISTS (
        SELECT 1 FROM billing_runtime_gate WHERE singleton=1 AND effective_entitlement_enabled=1
    ) THEN RAISE(ABORT,'group_billing_connection_recovery_denied') END);
END;
CREATE TRIGGER group_billing_recovery_command_apply AFTER INSERT ON group_billing_recovery_commands
BEGIN
    INSERT INTO group_billing_recovery_uses VALUES (NEW.billing_key_id,NEW.billing_account_id,NEW.generation,NEW.created_at);
    DELETE FROM group_billing_connections WHERE billing_account_id=NEW.billing_account_id;
    -- The existing connection authority trigger validates active target person,
    -- device and billing key. Any failure rolls back the old link and use too.
    INSERT INTO group_billing_connections VALUES (NEW.person_id,NEW.billing_account_id,NEW.device_id,NEW.billing_key_id,NEW.created_at);
END;
CREATE TRIGGER group_billing_recovery_command_immutable BEFORE UPDATE ON group_billing_recovery_commands
BEGIN SELECT RAISE(ABORT,'group_billing_connection_recovery_denied'); END;
