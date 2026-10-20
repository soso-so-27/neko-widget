PRAGMA foreign_keys = ON;

-- Group ownership is not an Apple account. Linking requires signatures from
-- BOTH an active group device and an active billing key over the same request.
-- One billing identity cannot manufacture an unlimited number of group people.
CREATE TABLE group_billing_connections (
    person_id TEXT PRIMARY KEY REFERENCES group_people(id),
    billing_account_id TEXT NOT NULL UNIQUE REFERENCES billing_accounts(id),
    linked_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    linked_billing_key_id TEXT NOT NULL REFERENCES billing_account_keys(id),
    created_at INTEGER NOT NULL
) STRICT;
CREATE TRIGGER group_billing_connection_authority BEFORE INSERT ON group_billing_connections
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
        JOIN billing_account_keys k ON k.id=NEW.linked_billing_key_id
        WHERE d.id=NEW.linked_device_id AND d.person_id=NEW.person_id AND d.state='active'
            AND p.state='active' AND k.billing_account_id=NEW.billing_account_id AND k.state='active')
        THEN RAISE(ABORT,'group_billing_connection_invalid') END);
END;
CREATE TRIGGER group_billing_connection_identity BEFORE UPDATE ON group_billing_connections
BEGIN SELECT RAISE(ABORT,'group_billing_connection_immutable'); END;
CREATE TABLE group_billing_connection_checks (
    id TEXT PRIMARY KEY,person_id TEXT NOT NULL,billing_account_id TEXT NOT NULL,billing_key_id TEXT NOT NULL
) STRICT;
CREATE TRIGGER group_billing_connection_check BEFORE INSERT ON group_billing_connection_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_billing_connections c JOIN billing_account_keys k ON k.billing_account_id=c.billing_account_id
        JOIN billing_runtime_gate g ON g.singleton=1
        WHERE c.person_id=NEW.person_id AND c.billing_account_id=NEW.billing_account_id
            AND k.id=NEW.billing_key_id AND k.state='active' AND g.effective_entitlement_enabled=1)
        THEN RAISE(ABORT,'group_billing_connection_invalid') END);
END;

-- Read verified Apple facts, never a client-supplied Plus flag. The existing
-- materialized entitlement deliberately excludes FAMILY_SHARED for old APIs;
-- this GROUP-ONLY view accepts both ownership types without changing them.
-- Revocation, grace expiry and authority freshness are evaluated at DB time.
CREATE VIEW group_verified_plus_people AS
SELECT DISTINCT link.person_id,authority.environment
FROM group_billing_connections link
JOIN billing_effective_entitlement_current authority ON authority.billing_account_id=link.billing_account_id
JOIN billing_runtime_gate gate ON gate.singleton=1
WHERE gate.effective_entitlement_enabled=1
    AND authority.ownership_type IN ('PURCHASED','FAMILY_SHARED')
    AND authority.product_id='jp.nekowidget.plus.monthly'
    AND authority.apple_status IN (1,4)
    AND authority.revocation_date_ms IS NULL AND authority.revocation_reason IS NULL AND authority.is_upgraded=0
    AND (CASE WHEN authority.apple_status=4 THEN authority.grace_period_expires_date_ms ELSE authority.expires_date_ms END)>CAST(unixepoch('subsec')*1000 AS INTEGER)
    AND authority.authority_stale_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER);

-- No scheduled state updates: every read/commit derives the state from the
-- persisted creation date + current verified authority, so renewal resumes
-- immediately and pausing cannot delete a room, photo, heart or membership.
CREATE VIEW group_window_owner_policy AS
SELECT w.space_id,w.owner_person_id,w.created_at+1209600 AS trial_ends_at,
    (SELECT participant_id FROM group_members m WHERE m.space_id=w.space_id AND m.role='owner') AS owner_participant_id
FROM group_windows w;

CREATE TABLE group_creation_policy_checks (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    owner_person_id TEXT NOT NULL REFERENCES group_people(id),
    store_environment TEXT CHECK (store_environment IN ('Production','Sandbox'))
) STRICT;
CREATE TRIGGER group_creation_policy BEFORE INSERT ON group_creation_policy_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_windows WHERE space_id=NEW.space_id AND owner_person_id=NEW.owner_person_id)
        THEN RAISE(ABORT,'group_billing_connection_invalid') END);
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_members WHERE person_id=NEW.owner_person_id AND role='owner' AND state='active')>5
        THEN RAISE(ABORT,'group_owned_window_limit') END);
    SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.owner_person_id AND environment=NEW.store_environment)
        AND unixepoch()>=(SELECT MIN(created_at)+1209600 FROM group_windows WHERE owner_person_id=NEW.owner_person_id)
        THEN RAISE(ABORT,'group_owner_plus_required') END);
END;

-- Put this pair of insert/delete statements IN the same batch as the first
-- photo commit. A preflight-only check would race cancellation or expiry.
CREATE TABLE group_delivery_policy_checks (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    store_environment TEXT CHECK (store_environment IN ('Production','Sandbox'))
) STRICT;
CREATE TRIGGER group_delivery_policy BEFORE INSERT ON group_delivery_policy_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_window_owner_policy w WHERE w.space_id=NEW.space_id
            AND (w.trial_ends_at>unixepoch() OR EXISTS (
                SELECT 1 FROM group_verified_plus_people p WHERE p.person_id=w.owner_person_id AND p.environment=NEW.store_environment)))
        THEN RAISE(ABORT,'group_window_paused') END);
END;
