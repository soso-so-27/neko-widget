PRAGMA foreign_keys = ON;

CREATE TABLE spaces (
    id TEXT PRIMARY KEY,
    creation_request_id TEXT NOT NULL UNIQUE,
    protocol_version INTEGER NOT NULL CHECK (protocol_version = 1),
    daily_boundary_minute_utc INTEGER NOT NULL CHECK (daily_boundary_minute_utc BETWEEN 0 AND 1439),
    state TEXT NOT NULL CHECK (state IN ('active', 'revoked')),
    created_at INTEGER NOT NULL,
    last_activity_at INTEGER NOT NULL,
    metadata_expires_at INTEGER NOT NULL,
    revoked_at INTEGER,
    CHECK (last_activity_at >= created_at),
    CHECK (metadata_expires_at > last_activity_at)
) STRICT;

CREATE INDEX spaces_metadata_expiry
    ON spaces(state, metadata_expires_at);

CREATE TABLE members (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'invitee')),
    participant_id TEXT NOT NULL,
    agreement_public_key TEXT NOT NULL,
    signing_public_key TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'revoked', 'expired')),
    created_at INTEGER NOT NULL,
    activated_at INTEGER,
    revoked_at INTEGER,
    UNIQUE (space_id, participant_id),
    UNIQUE (space_id, agreement_public_key),
    UNIQUE (space_id, signing_public_key)
) STRICT;

CREATE UNIQUE INDEX one_live_owner_per_space
    ON members(space_id)
    WHERE role = 'owner' AND state = 'active';

CREATE UNIQUE INDEX one_live_invitee_per_space
    ON members(space_id)
    WHERE role = 'invitee' AND state IN ('pending', 'active');

CREATE TABLE invitations (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    inviter_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    invite_proof_public_key TEXT,
    status TEXT NOT NULL CHECK (status IN ('open', 'consumed', 'revoked', 'expired')),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER,
    enrollment_id TEXT,
    CHECK (expires_at > created_at)
) STRICT;

CREATE UNIQUE INDEX one_open_invitation_per_space
    ON invitations(space_id)
    WHERE status = 'open';

CREATE UNIQUE INDEX unique_live_invite_proof_key
    ON invitations(invite_proof_public_key)
    WHERE invite_proof_public_key IS NOT NULL;

CREATE INDEX invitations_state_expiry
    ON invitations(status, expires_at);

CREATE INDEX open_invitations_expiry
    ON invitations(expires_at, space_id)
    WHERE status = 'open';

CREATE TABLE invitation_challenges (
    id TEXT PRIMARY KEY,
    invitation_id TEXT NOT NULL REFERENCES invitations(id) ON DELETE CASCADE,
    value TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER,
    CHECK (expires_at > created_at),
    UNIQUE (invitation_id, value)
) STRICT;

CREATE INDEX live_invitation_challenges_expiry
    ON invitation_challenges(expires_at, invitation_id)
    WHERE consumed_at IS NULL;

CREATE TRIGGER challenges_require_live_invitation_and_capacity
BEFORE INSERT ON invitation_challenges
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
        FROM invitations AS i
        JOIN spaces AS s ON s.id = i.space_id
        WHERE i.id = NEW.invitation_id
          AND i.status = 'open'
          AND i.invite_proof_public_key IS NOT NULL
          AND i.expires_at > NEW.created_at
          AND NEW.expires_at <= i.expires_at
          AND s.state = 'active'
    ) THEN RAISE(ABORT, 'invalid challenge transition') END;
    SELECT CASE WHEN (
        SELECT COUNT(*)
        FROM invitation_challenges AS c
        WHERE c.invitation_id = NEW.invitation_id
          AND c.consumed_at IS NULL
          AND c.expires_at > NEW.created_at
    ) >= 8 THEN RAISE(ABORT, 'challenge capacity exceeded') END;
END;

CREATE TABLE enrollments (
    id TEXT PRIMARY KEY,
    invitation_id TEXT NOT NULL UNIQUE REFERENCES invitations(id) ON DELETE CASCADE,
    challenge_id TEXT UNIQUE REFERENCES invitation_challenges(id) ON DELETE SET NULL,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    member_id TEXT NOT NULL UNIQUE REFERENCES members(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending', 'approved', 'consumed', 'revoked', 'expired')),
    transcript TEXT NOT NULL,
    transcript_hash TEXT NOT NULL,
    invite_proof_signature TEXT NOT NULL,
    participant_signature TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    approved_at INTEGER,
    consumed_at INTEGER,
    UNIQUE (invitation_id, client_request_id),
    CHECK (expires_at > created_at)
) STRICT;

CREATE INDEX enrollments_state_expiry
    ON enrollments(state, expires_at);

CREATE INDEX live_enrollments_expiry
    ON enrollments(expires_at, space_id)
    WHERE state IN ('pending', 'approved');

CREATE TRIGGER enrollments_require_live_invitation
BEFORE INSERT ON enrollments
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
        FROM invitations AS i
        JOIN invitation_challenges AS c ON c.invitation_id = i.id
        JOIN members AS m ON m.id = NEW.member_id
        JOIN spaces AS s ON s.id = NEW.space_id
        WHERE i.id = NEW.invitation_id
          AND i.space_id = NEW.space_id
          AND i.status = 'open'
          AND i.invite_proof_public_key IS NOT NULL
          AND i.expires_at > NEW.created_at
          AND c.id = NEW.challenge_id
          AND c.consumed_at IS NULL
          AND c.expires_at > NEW.created_at
          AND NEW.challenge_id IS NOT NULL
          AND m.space_id = NEW.space_id
          AND m.role = 'invitee'
          AND m.state = 'pending'
          AND s.state = 'active'
    ) THEN RAISE(ABORT, 'invalid enrollment transition') END;
END;

CREATE TRIGGER enrollments_consume_invitation
AFTER INSERT ON enrollments
BEGIN
    UPDATE invitations
       SET status = 'consumed',
           consumed_at = NEW.created_at,
           enrollment_id = NEW.id,
           invite_proof_public_key = NULL
     WHERE id = NEW.invitation_id;
    UPDATE invitation_challenges
       SET consumed_at = NEW.created_at
     WHERE id = NEW.challenge_id;
    DELETE FROM invitation_challenges
     WHERE invitation_id = NEW.invitation_id
       AND id <> NEW.challenge_id;
END;

CREATE TABLE approval_events (
    enrollment_id TEXT PRIMARY KEY REFERENCES enrollments(id) ON DELETE CASCADE,
    approver_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    transcript_hash TEXT NOT NULL,
    envelope_algorithm TEXT NOT NULL CHECK (envelope_algorithm = 'X25519-HKDF-SHA256-CHACHA20POLY1305'),
    key_envelope TEXT,
    approval_signature TEXT,
    created_at INTEGER NOT NULL,
    UNIQUE (approver_member_id, client_request_id)
) STRICT;

CREATE TRIGGER approvals_require_owner_and_pending
BEFORE INSERT ON approval_events
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
        FROM enrollments AS e
        JOIN members AS owner ON owner.id = NEW.approver_member_id
        JOIN spaces AS s ON s.id = e.space_id
        WHERE e.id = NEW.enrollment_id
          AND e.state = 'pending'
          AND e.expires_at > NEW.created_at
          AND e.transcript_hash = NEW.transcript_hash
          AND owner.space_id = e.space_id
          AND owner.role = 'owner'
          AND owner.state = 'active'
          AND s.state = 'active'
          AND NEW.key_envelope IS NOT NULL
          AND NEW.approval_signature IS NOT NULL
    ) THEN RAISE(ABORT, 'invalid approval transition') END;
END;

CREATE TRIGGER approvals_mark_enrollment
AFTER INSERT ON approval_events
BEGIN
    UPDATE enrollments
       SET state = 'approved', approved_at = NEW.created_at
     WHERE id = NEW.enrollment_id;
END;

CREATE TABLE completion_events (
    enrollment_id TEXT PRIMARY KEY REFERENCES enrollments(id) ON DELETE CASCADE,
    member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    transcript_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (member_id, client_request_id)
) STRICT;

CREATE TRIGGER completions_require_approved_invitee
BEFORE INSERT ON completion_events
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
        FROM enrollments AS e
        JOIN members AS invitee ON invitee.id = NEW.member_id
        JOIN spaces AS s ON s.id = e.space_id
        JOIN approval_events AS a ON a.enrollment_id = e.id
        WHERE e.id = NEW.enrollment_id
          AND e.member_id = NEW.member_id
          AND e.state = 'approved'
          AND e.transcript_hash = NEW.transcript_hash
          AND e.expires_at > NEW.created_at
          AND invitee.role = 'invitee'
          AND invitee.state = 'pending'
          AND a.key_envelope IS NOT NULL
          AND s.state = 'active'
    ) THEN RAISE(ABORT, 'invalid completion transition') END;
END;

CREATE TRIGGER completions_activate_member
AFTER INSERT ON completion_events
BEGIN
    UPDATE enrollments
       SET state = 'consumed', consumed_at = NEW.created_at
     WHERE id = NEW.enrollment_id;
    UPDATE members
       SET state = 'active', activated_at = NEW.created_at
     WHERE id = NEW.member_id;
    UPDATE approval_events
       SET key_envelope = NULL, approval_signature = NULL
     WHERE enrollment_id = NEW.enrollment_id;
    DELETE FROM invitation_challenges
     WHERE id IN (
       SELECT challenge_id FROM enrollments WHERE id = NEW.enrollment_id
     );
END;

CREATE TABLE cancellation_events (
    enrollment_id TEXT PRIMARY KEY REFERENCES enrollments(id) ON DELETE CASCADE,
    member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (member_id, client_request_id)
) STRICT;

CREATE TRIGGER cancellations_require_pending_invitee
BEFORE INSERT ON cancellation_events
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
        FROM enrollments AS e
        JOIN members AS invitee ON invitee.id = NEW.member_id
        JOIN spaces AS s ON s.id = e.space_id
        WHERE e.id = NEW.enrollment_id
          AND e.member_id = NEW.member_id
          AND e.state IN ('pending', 'approved')
          AND invitee.role = 'invitee'
          AND invitee.state = 'pending'
          AND s.state = 'active'
    ) THEN RAISE(ABORT, 'invalid cancellation transition') END;
END;

CREATE TRIGGER cancellations_revoke_enrollment
AFTER INSERT ON cancellation_events
BEGIN
    UPDATE approval_events
       SET key_envelope = NULL, approval_signature = NULL
     WHERE enrollment_id = NEW.enrollment_id;
    DELETE FROM invitation_challenges
     WHERE id IN (
       SELECT challenge_id FROM enrollments WHERE id = NEW.enrollment_id
     );
    UPDATE enrollments
       SET state = 'revoked'
     WHERE id = NEW.enrollment_id;
    UPDATE members
       SET state = 'revoked', revoked_at = NEW.created_at
     WHERE id = NEW.member_id;
END;

CREATE TABLE revocation_events (
    space_id TEXT PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
    actor_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (actor_member_id, client_request_id)
) STRICT;

CREATE TABLE space_deletion_jobs (
    space_id TEXT PRIMARY KEY,
    state TEXT NOT NULL CHECK (state IN ('pending', 'complete')),
    requires_object_deletion INTEGER NOT NULL DEFAULT 0 CHECK (requires_object_deletion IN (0, 1)),
    created_at INTEGER NOT NULL,
    completed_at INTEGER
) STRICT;

CREATE INDEX space_deletion_jobs_pending
    ON space_deletion_jobs(state, requires_object_deletion, created_at);

CREATE TRIGGER revocations_require_live_member
BEFORE INSERT ON revocation_events
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
        FROM spaces AS s
        JOIN members AS m ON m.space_id = s.id
        WHERE s.id = NEW.space_id
          AND s.state = 'active'
          AND m.id = NEW.actor_member_id
          AND m.state = 'active'
    ) THEN RAISE(ABORT, 'invalid revocation transition') END;
END;

CREATE TRIGGER revocations_disable_space
AFTER INSERT ON revocation_events
BEGIN
    UPDATE spaces
       SET state = 'revoked', revoked_at = NEW.created_at
     WHERE id = NEW.space_id;
    UPDATE members
       SET state = 'revoked', revoked_at = NEW.created_at
     WHERE space_id = NEW.space_id;
    UPDATE invitations
       SET status = 'revoked', invite_proof_public_key = NULL
     WHERE space_id = NEW.space_id AND status = 'open';
    UPDATE enrollments
       SET state = 'revoked'
     WHERE space_id = NEW.space_id AND state IN ('pending', 'approved');
    UPDATE approval_events
       SET key_envelope = NULL, approval_signature = NULL
     WHERE enrollment_id IN (SELECT id FROM enrollments WHERE space_id = NEW.space_id);
    DELETE FROM invitation_challenges
     WHERE invitation_id IN (SELECT id FROM invitations WHERE space_id = NEW.space_id);
    INSERT INTO space_deletion_jobs(space_id, state, created_at)
    VALUES (NEW.space_id, 'pending', NEW.created_at);
END;

CREATE TABLE idempotency_records (
    operation TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    client_request_id TEXT NOT NULL,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    request_hash TEXT NOT NULL,
    response_status INTEGER NOT NULL,
    response_json TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (operation, actor_id, client_request_id),
    CHECK (expires_at > created_at)
) STRICT;

CREATE INDEX idempotency_expires_at
    ON idempotency_records(expires_at);

CREATE TABLE request_nonces (
    member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    nonce TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (member_id, nonce)
) STRICT;

CREATE INDEX request_nonces_expiry
    ON request_nonces(expires_at);
