PRAGMA foreign_keys = ON;

-- Keep the existing single-store check tables/triggers for old Worker code.
-- These transient guards are inserted/deleted inside the accepting mutation;
-- no room, membership, billing fact, or photo is rewritten by this migration.
CREATE TABLE group_creation_environment_checks (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    owner_person_id TEXT NOT NULL REFERENCES group_people(id),
    store_environment TEXT CHECK (store_environment IN ('Production','Sandbox')),
    accept_sandbox_in_production INTEGER NOT NULL DEFAULT 0 CHECK (
        accept_sandbox_in_production IN (0,1)
        AND (accept_sandbox_in_production = 0 OR store_environment IS 'Production')
    )
) STRICT;

CREATE TRIGGER group_creation_environment_policy BEFORE INSERT ON group_creation_environment_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_windows WHERE space_id=NEW.space_id AND owner_person_id=NEW.owner_person_id)
        THEN RAISE(ABORT,'group_billing_connection_invalid') END);
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_members WHERE person_id=NEW.owner_person_id AND role='owner' AND state='active')>5
        THEN RAISE(ABORT,'group_owned_window_limit') END);
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.owner_person_id
            AND (environment=NEW.store_environment
                OR (NEW.store_environment='Production' AND NEW.accept_sandbox_in_production=1 AND environment='Sandbox')))
        THEN RAISE(ABORT,'group_owner_plus_required') END);
END;

CREATE TABLE group_delivery_environment_checks (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    store_environment TEXT CHECK (store_environment IN ('Production','Sandbox')),
    accept_sandbox_in_production INTEGER NOT NULL DEFAULT 0 CHECK (
        accept_sandbox_in_production IN (0,1)
        AND (accept_sandbox_in_production = 0 OR store_environment IS 'Production')
    )
) STRICT;

CREATE TRIGGER group_delivery_environment_policy BEFORE INSERT ON group_delivery_environment_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_window_owner_policy w JOIN group_verified_plus_people p ON p.person_id=w.owner_person_id
        WHERE w.space_id=NEW.space_id
            AND (p.environment=NEW.store_environment
                OR (NEW.store_environment='Production' AND NEW.accept_sandbox_in_production=1 AND p.environment='Sandbox')))
        THEN RAISE(ABORT,'group_window_paused') END);
END;
