PRAGMA foreign_keys = ON;

-- Additive v3 storage only. No legacy row is rewritten or deleted. No runtime
-- flag is enabled by this migration. Remote application requires owner approval.
CREATE TABLE group_people (
    id TEXT PRIMARY KEY,
    identity_public_key TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL CHECK (state IN ('active', 'revoked')),
    created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE group_person_devices (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL REFERENCES group_people(id),
    signing_public_key TEXT NOT NULL UNIQUE,
    hpke_public_key TEXT NOT NULL UNIQUE,
    authorization TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('active', 'revoked')),
    created_at INTEGER NOT NULL,
    revoked_at INTEGER,
    CHECK ((state = 'active' AND revoked_at IS NULL) OR (state = 'revoked' AND revoked_at IS NOT NULL))
) STRICT;
CREATE INDEX group_devices_person_state ON group_person_devices(person_id, state, id);
CREATE TRIGGER group_devices_limit_insert BEFORE INSERT ON group_person_devices
WHEN NEW.state = 'active'
BEGIN
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_person_devices WHERE person_id = NEW.person_id AND state = 'active') >= 3
        THEN RAISE(ABORT, 'group_device_limit') END);
END;
CREATE TRIGGER group_devices_immutable_identity BEFORE UPDATE ON group_person_devices
BEGIN
    SELECT (CASE WHEN NEW.id <> OLD.id OR NEW.person_id <> OLD.person_id
        OR NEW.signing_public_key <> OLD.signing_public_key OR NEW.hpke_public_key <> OLD.hpke_public_key
        OR (OLD.state = 'revoked' AND NEW.state <> 'revoked')
        THEN RAISE(ABORT, 'group_device_identity_immutable') END);
END;

CREATE TABLE group_windows (
    space_id TEXT PRIMARY KEY,
    owner_person_id TEXT NOT NULL REFERENCES group_people(id),
    mode TEXT NOT NULL CHECK (mode IN ('preparing', 'active', 'closed')),
    revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
    key_epoch INTEGER NOT NULL DEFAULT 0 CHECK (key_epoch >= 0),
    roster_hash TEXT,
    rotation_required INTEGER NOT NULL DEFAULT 0 CHECK (rotation_required IN (0, 1)),
    migration_id TEXT UNIQUE,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;
CREATE INDEX group_windows_owner ON group_windows(owner_person_id, mode, space_id);

CREATE TABLE group_members (
    participant_id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    person_id TEXT NOT NULL REFERENCES group_people(id),
    role TEXT NOT NULL CHECK (role IN ('owner', 'member')),
    state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'left', 'removed')),
    joined_revision INTEGER NOT NULL CHECK (joined_revision > 0),
    left_revision INTEGER,
    display_name_ciphertext TEXT NOT NULL,
    UNIQUE(space_id, person_id)
) STRICT;
CREATE INDEX group_members_space_state ON group_members(space_id, state, participant_id);
CREATE INDEX group_members_person_state ON group_members(person_id, state, space_id);
CREATE UNIQUE INDEX group_one_active_owner ON group_members(space_id) WHERE role = 'owner' AND state = 'active';
CREATE TRIGGER group_members_limit_insert BEFORE INSERT ON group_members WHEN NEW.state = 'active'
BEGIN
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_members WHERE space_id = NEW.space_id AND state = 'active') >= 6
        THEN RAISE(ABORT, 'group_member_limit') END);
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_members WHERE person_id = NEW.person_id AND state = 'active') >= 10
        THEN RAISE(ABORT, 'group_total_window_limit') END);
    SELECT (CASE WHEN NEW.role = 'owner' AND NOT EXISTS (
        SELECT 1 FROM group_windows WHERE space_id = NEW.space_id AND owner_person_id = NEW.person_id)
        THEN RAISE(ABORT, 'group_owner_mismatch') END);
END;
CREATE TRIGGER group_members_limit_update BEFORE UPDATE ON group_members
BEGIN
    SELECT (CASE WHEN NEW.participant_id <> OLD.participant_id OR NEW.space_id <> OLD.space_id
        OR NEW.person_id <> OLD.person_id OR NEW.role <> OLD.role
        THEN RAISE(ABORT, 'group_member_identity_immutable') END);
    SELECT (CASE WHEN NEW.state = 'active' AND OLD.state <> 'active' AND (
        (SELECT COUNT(*) FROM group_members WHERE space_id = NEW.space_id AND state = 'active') >= 6)
        THEN RAISE(ABORT, 'group_member_limit') END);
    SELECT (CASE WHEN NEW.state = 'active' AND OLD.state <> 'active' AND (
        (SELECT COUNT(*) FROM group_members WHERE person_id = NEW.person_id AND state = 'active') >= 10)
        THEN RAISE(ABORT, 'group_total_window_limit') END);
    SELECT (CASE WHEN OLD.role = 'owner' AND OLD.state = 'active' AND NEW.state <> 'active'
        AND EXISTS (SELECT 1 FROM group_windows WHERE space_id = OLD.space_id AND mode <> 'closed')
        THEN RAISE(ABORT, 'group_owner_cannot_leave') END);
END;

CREATE TABLE group_window_devices (
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    participant_id TEXT NOT NULL REFERENCES group_members(participant_id),
    state TEXT NOT NULL CHECK (state IN ('active', 'revoked')),
    added_revision INTEGER NOT NULL,
    removed_revision INTEGER,
    PRIMARY KEY(space_id, device_id)
) STRICT;
CREATE INDEX group_window_devices_member ON group_window_devices(participant_id, state, device_id);
CREATE TRIGGER group_window_devices_person BEFORE INSERT ON group_window_devices
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_members AS m JOIN group_person_devices AS d ON d.person_id = m.person_id
        WHERE m.participant_id = NEW.participant_id AND m.space_id = NEW.space_id AND d.id = NEW.device_id
            AND m.state = 'active' AND d.state = 'active')
        THEN RAISE(ABORT, 'group_device_wrong_person') END);
END;
CREATE TRIGGER group_window_devices_identity BEFORE UPDATE ON group_window_devices
BEGIN
    SELECT (CASE WHEN NEW.space_id <> OLD.space_id OR NEW.device_id <> OLD.device_id OR NEW.participant_id <> OLD.participant_id
        OR (OLD.state = 'revoked' AND NEW.state <> 'revoked')
        THEN RAISE(ABORT, 'group_window_device_identity_immutable') END);
END;

CREATE TABLE group_invitations (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    proof_public_key TEXT NOT NULL UNIQUE,
    created_by_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    revoked_at INTEGER,
    CHECK (expires_at = created_at + 86400)
) STRICT;
CREATE INDEX group_invitations_expiry ON group_invitations(expires_at, id);
CREATE TABLE group_challenges (
    id TEXT PRIMARY KEY,
    purpose TEXT NOT NULL,
    invitation_id TEXT REFERENCES group_invitations(id),
    device_key_hash TEXT NOT NULL,
    random_challenge TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
) STRICT;
CREATE INDEX group_challenges_expiry ON group_challenges(expires_at, id);
CREATE TABLE group_join_requests (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    invitation_id TEXT NOT NULL REFERENCES group_invitations(id),
    person_id TEXT NOT NULL REFERENCES group_people(id),
    candidate_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    signed_request TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending', 'approved', 'rejected', 'cancelled', 'expired')),
    expires_at INTEGER NOT NULL,
    result_revision INTEGER
) STRICT;
CREATE UNIQUE INDEX group_one_pending_request ON group_join_requests(invitation_id, candidate_device_id) WHERE state = 'pending';
CREATE INDEX group_join_requests_window ON group_join_requests(space_id, state, id);

CREATE TABLE group_rosters (
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    revision INTEGER NOT NULL CHECK (revision > 0),
    previous_hash TEXT NOT NULL,
    key_epoch INTEGER NOT NULL CHECK (key_epoch > 0),
    canonical_bytes BLOB NOT NULL CHECK (length(canonical_bytes) BETWEEN 1 AND 65536),
    roster_hash TEXT NOT NULL,
    signer_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    signature TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(space_id, revision),
    UNIQUE(space_id, roster_hash)
) STRICT;
CREATE TABLE group_key_envelopes (
    space_id TEXT NOT NULL,
    epoch INTEGER NOT NULL CHECK (epoch > 0),
    device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    roster_revision INTEGER NOT NULL,
    roster_hash TEXT NOT NULL,
    encapsulated_key TEXT NOT NULL,
    sealed_key TEXT NOT NULL,
    signer_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    signature TEXT NOT NULL,
    PRIMARY KEY(space_id, epoch, device_id),
    FOREIGN KEY(space_id, roster_revision) REFERENCES group_rosters(space_id, revision)
) STRICT;

-- Write this LAST in a D1 batch, after the new roster/devices/envelopes. A
-- failed CAS is an SQL error, not a successful zero-row UPDATE.
CREATE TABLE group_epoch_transitions (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    actor_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    expected_revision INTEGER NOT NULL,
    result_revision INTEGER NOT NULL,
    result_epoch INTEGER NOT NULL,
    request_hash TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('create', 'admit', 'addDevice', 'remove', 'removeDevice', 'rotate', 'migrate')),
    created_at INTEGER NOT NULL,
    CHECK (result_revision = expected_revision + 1)
) STRICT;
CREATE TRIGGER group_transition_validate BEFORE INSERT ON group_epoch_transitions
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_windows AS w JOIN group_rosters AS r ON r.space_id = w.space_id
        WHERE w.space_id = NEW.space_id AND w.mode <> 'closed' AND w.revision = NEW.expected_revision
            AND r.revision = NEW.result_revision AND r.key_epoch = NEW.result_epoch
            AND r.signer_device_id = NEW.actor_device_id
            AND NEW.result_epoch = w.key_epoch + 1
            AND (w.roster_hash IS NULL OR r.previous_hash = w.roster_hash))
        THEN RAISE(ABORT, 'group_stale_revision_or_epoch') END);
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_window_devices AS d JOIN group_members AS m ON m.participant_id = d.participant_id
        JOIN group_person_devices AS p ON p.id = d.device_id
        WHERE d.space_id = NEW.space_id AND d.device_id = NEW.actor_device_id
            AND d.state = 'active' AND m.state = 'active' AND p.state = 'active' AND m.role = 'owner')
        THEN RAISE(ABORT, 'group_owner_required') END);
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_members WHERE space_id = NEW.space_id AND state = 'active' AND role = 'owner')
        OR NOT EXISTS (SELECT 1 FROM group_window_devices WHERE space_id = NEW.space_id AND state = 'active')
        THEN RAISE(ABORT, 'group_empty_roster') END);
    SELECT (CASE WHEN EXISTS (
        SELECT 1 FROM group_window_devices AS d
        JOIN group_members AS m ON m.participant_id = d.participant_id
        JOIN group_person_devices AS p ON p.id = d.device_id
        WHERE d.space_id = NEW.space_id AND d.state = 'active'
            AND (m.state <> 'active' OR p.state <> 'active'))
        THEN RAISE(ABORT, 'group_revoked_device_in_roster') END);
    SELECT (CASE WHEN EXISTS (
        SELECT 1 FROM group_window_devices AS d
        LEFT JOIN group_key_envelopes AS e ON e.space_id = d.space_id AND e.device_id = d.device_id
            AND e.epoch = NEW.result_epoch AND e.roster_revision = NEW.result_revision
        WHERE d.space_id = NEW.space_id AND d.state = 'active' AND e.device_id IS NULL)
        OR EXISTS (
        SELECT 1 FROM group_key_envelopes AS e
        LEFT JOIN group_window_devices AS d ON d.space_id = e.space_id AND d.device_id = e.device_id AND d.state = 'active'
        JOIN group_rosters AS r ON r.space_id = e.space_id AND r.revision = NEW.result_revision
        WHERE e.space_id = NEW.space_id AND e.epoch = NEW.result_epoch
            AND (d.device_id IS NULL OR e.roster_hash <> r.roster_hash OR e.signer_device_id <> NEW.actor_device_id))
        THEN RAISE(ABORT, 'group_envelope_set_mismatch') END);
END;
CREATE TRIGGER group_transition_apply AFTER INSERT ON group_epoch_transitions
BEGIN
    UPDATE group_windows SET revision = NEW.result_revision, key_epoch = NEW.result_epoch,
        roster_hash = (SELECT roster_hash FROM group_rosters WHERE space_id = NEW.space_id AND revision = NEW.result_revision),
        rotation_required = 0, mode = 'active', updated_at = NEW.created_at
    WHERE space_id = NEW.space_id;
END;

CREATE TABLE group_mutations (
    actor_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    operation_id TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    response_json TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY(actor_device_id, operation_id)
) STRICT;
CREATE INDEX group_mutations_expiry ON group_mutations(expires_at);
CREATE TABLE group_request_nonces (
    device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    nonce TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY(device_id, nonce)
) STRICT;
CREATE INDEX group_request_nonces_expiry ON group_request_nonces(expires_at);
CREATE TABLE group_legacy_bindings (
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    legacy_member_id TEXT NOT NULL UNIQUE,
    participant_id TEXT NOT NULL REFERENCES group_members(participant_id),
    person_id TEXT NOT NULL REFERENCES group_people(id),
    device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    migration_id TEXT NOT NULL,
    PRIMARY KEY(space_id, legacy_member_id)
) STRICT;
CREATE TABLE group_migrations (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL UNIQUE REFERENCES group_windows(space_id),
    state TEXT NOT NULL CHECK (state IN ('prepared', 'acknowledged', 'activated')),
    old_revision INTEGER NOT NULL,
    new_revision INTEGER NOT NULL,
    owner_ack TEXT,
    peer_ack TEXT,
    snapshot_counts TEXT NOT NULL
) STRICT;
