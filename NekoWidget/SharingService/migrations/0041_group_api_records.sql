PRAGMA foreign_keys = ON;

-- Additive records for the gated v3 API. Names remain encrypted. No legacy
-- data, runtime gate, schedule, or deployed configuration is changed.
CREATE TABLE group_roster_packets (
    space_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    packet_json TEXT NOT NULL CHECK (length(CAST(packet_json AS BLOB)) BETWEEN 1 AND 65536),
    PRIMARY KEY(space_id, revision),
    FOREIGN KEY(space_id, revision) REFERENCES group_rosters(space_id, revision)
) STRICT;
CREATE TABLE group_window_metadata (
    space_id TEXT PRIMARY KEY REFERENCES group_windows(space_id),
    encrypted_name TEXT NOT NULL,
    key_epoch INTEGER NOT NULL CHECK (key_epoch > 0),
    roster_revision INTEGER NOT NULL CHECK (roster_revision > 0)
) STRICT;
CREATE TABLE group_identity_registrations (
    device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    operation_id TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(device_id, operation_id)
) STRICT;
CREATE TABLE group_authorization_checks (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    space_id TEXT REFERENCES group_windows(space_id),
    owner_required INTEGER NOT NULL CHECK (owner_required IN (0, 1)),
    expected_revision INTEGER
) STRICT;
CREATE TRIGGER group_authorization_check BEFORE INSERT ON group_authorization_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
        WHERE d.id=NEW.device_id AND d.state='active' AND p.state='active')
        THEN RAISE(ABORT, 'group_invalid_authentication') END);
    SELECT (CASE WHEN NEW.space_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM group_windows w JOIN group_members m ON m.space_id=w.space_id
        JOIN group_window_devices d ON d.space_id=w.space_id AND d.participant_id=m.participant_id
        WHERE w.space_id=NEW.space_id AND w.mode='active' AND m.state='active' AND d.state='active'
            AND d.device_id=NEW.device_id AND (NEW.owner_required=0 OR m.role='owner'))
        THEN RAISE(ABORT, 'group_not_member_or_owner') END);
    SELECT (CASE WHEN NEW.space_id IS NOT NULL AND NEW.expected_revision IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM group_windows WHERE space_id=NEW.space_id AND revision=NEW.expected_revision)
        THEN RAISE(ABORT, 'group_stale_revision_or_epoch') END);
END;
CREATE TABLE group_window_creation_checks (
    operation_id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL UNIQUE REFERENCES group_windows(space_id),
    owner_person_id TEXT NOT NULL REFERENCES group_people(id),
    owned_limit INTEGER NOT NULL CHECK (owned_limit IN (1, 5)),
    created_at INTEGER NOT NULL
) STRICT;
CREATE TRIGGER group_creation_limit BEFORE INSERT ON group_window_creation_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_windows WHERE space_id = NEW.space_id AND owner_person_id = NEW.owner_person_id)
        OR (SELECT COUNT(*) FROM group_members WHERE person_id = NEW.owner_person_id AND role = 'owner' AND state = 'active') > NEW.owned_limit
        THEN RAISE(ABORT, 'group_owned_window_limit') END);
END;
CREATE TRIGGER group_challenge_consume_once BEFORE UPDATE OF consumed_at ON group_challenges
BEGIN
    SELECT (CASE WHEN OLD.consumed_at IS NOT NULL OR NEW.consumed_at IS NULL
        OR NEW.consumed_at >= OLD.expires_at OR NEW.consumed_at < OLD.expires_at - 300
        THEN RAISE(ABORT, 'group_challenge_expired_or_used') END);
END;
CREATE TRIGGER group_pending_request_limit BEFORE INSERT ON group_join_requests
WHEN NEW.state = 'pending'
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_invitations AS i JOIN group_windows AS w ON w.space_id = i.space_id
        JOIN group_person_devices AS d ON d.id = NEW.candidate_device_id
        WHERE i.id = NEW.invitation_id AND i.space_id = NEW.space_id AND w.mode = 'active'
            AND i.revoked_at IS NULL AND i.expires_at > unixepoch() AND NEW.expires_at > unixepoch()
            AND NEW.expires_at <= i.expires_at AND d.person_id = NEW.person_id AND d.state = 'active')
        THEN RAISE(ABORT, 'group_invalid_join_request') END);
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_join_requests WHERE space_id = NEW.space_id AND state = 'pending') >= 100
        THEN RAISE(ABORT, 'group_pending_request_limit') END);
END;

-- A zero-row state change is not a successful resolution. Both this trigger
-- and the epoch write run inside the same D1 batch as membership changes.
CREATE TRIGGER group_request_resolve BEFORE UPDATE OF state ON group_join_requests
BEGIN
    SELECT (CASE WHEN OLD.state <> 'pending' OR NEW.state NOT IN ('approved','rejected','cancelled','expired')
        THEN RAISE(ABORT, 'group_request_not_pending') END);
    SELECT (CASE WHEN NEW.state = 'approved' AND NOT EXISTS (
        SELECT 1 FROM group_invitations i JOIN group_person_devices d ON d.id=NEW.candidate_device_id
        JOIN group_people p ON p.id=d.person_id
        WHERE i.id=NEW.invitation_id AND i.revoked_at IS NULL AND i.expires_at > unixepoch()
            AND NEW.expires_at > unixepoch() AND d.state='active' AND p.state='active')
        THEN RAISE(ABORT, 'group_invitation_expired_or_revoked') END);
END;

-- Rejoining is explicit owner approval with a NEW epoch, never implicit
-- resurrection of an old membership. Historical sender/participant IDs stay.
DROP TRIGGER group_window_devices_identity;
CREATE TRIGGER group_window_devices_identity BEFORE UPDATE ON group_window_devices
BEGIN
    SELECT (CASE WHEN NEW.space_id <> OLD.space_id OR NEW.device_id <> OLD.device_id
        OR NEW.participant_id <> OLD.participant_id OR (OLD.state='revoked' AND NEW.state='active' AND NOT (
            NEW.added_revision > OLD.added_revision AND NEW.removed_revision IS NULL
            AND EXISTS (SELECT 1 FROM group_windows w JOIN group_members m ON m.space_id=w.space_id
                WHERE w.space_id=NEW.space_id AND m.participant_id=NEW.participant_id AND m.state='active'
                    AND NEW.added_revision=w.revision+1)))
        THEN RAISE(ABORT, 'group_window_device_identity_immutable') END);
END;
