PRAGMA foreign_keys = ON;

-- Keep this migration LF-only; Wrangler remote trigger parsing rejects CRLF.
-- A recovery is an explicit, short-lived handoff from one active peer to a
-- replacement device for the other participant. No existing credential or
-- membership row changes before the replacement device completes the flow.

CREATE TABLE device_recoveries (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    initiator_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    target_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    target_moment_participant_id TEXT NOT NULL
        REFERENCES moment_participants(id) ON DELETE CASCADE,
    target_device_id TEXT NOT NULL REFERENCES moment_devices(id),
    expected_membership_revision INTEGER NOT NULL CHECK (expected_membership_revision > 0),
    expected_key_epoch INTEGER NOT NULL CHECK (expected_key_epoch > 0),
    target_agreement_public_key TEXT NOT NULL,
    target_signing_public_key TEXT NOT NULL,
    initiator_agreement_public_key TEXT NOT NULL,
    initiator_signing_public_key TEXT NOT NULL,
    recovery_proof_public_key TEXT,
    state TEXT NOT NULL CHECK (
      state IN ('open', 'claimed', 'approved', 'consumed', 'expired')
    ),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    claimed_at INTEGER,
    approved_at INTEGER,
    consumed_at INTEGER,
    CHECK (initiator_member_id <> target_member_id),
    CHECK (expires_at > created_at)
) STRICT;

CREATE UNIQUE INDEX one_live_device_recovery_per_target
    ON device_recoveries(target_member_id)
    WHERE state IN ('open', 'claimed', 'approved');

CREATE UNIQUE INDEX unique_live_device_recovery_proof
    ON device_recoveries(recovery_proof_public_key)
    WHERE recovery_proof_public_key IS NOT NULL;

CREATE INDEX live_device_recoveries_expiry
    ON device_recoveries(expires_at, id)
    WHERE state IN ('open', 'claimed', 'approved');

CREATE TRIGGER device_recoveries_require_active_peers
BEFORE INSERT ON device_recoveries
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM spaces AS space
        JOIN members AS initiator ON initiator.space_id = space.id
        JOIN members AS target ON target.space_id = space.id
        JOIN moment_participants AS participant
          ON participant.legacy_member_id = target.id
         AND participant.space_id = space.id
        JOIN moment_devices AS target_device
          ON target_device.participant_id = participant.id
         AND target_device.legacy_member_id = target.id
        JOIN moment_spaces AS moment_space ON moment_space.space_id = space.id
        JOIN moment_participants AS initiator_participant
          ON initiator_participant.legacy_member_id = initiator.id
         AND initiator_participant.space_id = space.id
        JOIN moment_devices AS initiator_device
          ON initiator_device.participant_id = initiator_participant.id
         AND initiator_device.legacy_member_id = initiator.id
       WHERE space.id = NEW.space_id
         AND space.state = 'active'
         AND initiator.id = NEW.initiator_member_id
         AND initiator.state = 'active'
         AND initiator_participant.state = 'active'
         AND initiator_device.state = 'active'
         AND initiator_device.agreement_public_key = NEW.initiator_agreement_public_key
         AND initiator_device.signing_public_key = NEW.initiator_signing_public_key
         AND target.id = NEW.target_member_id
         AND target.state = 'active'
         AND target.id <> initiator.id
         AND participant.id = NEW.target_moment_participant_id
         AND participant.state = 'active'
         AND target_device.state = 'active'
         AND target_device.id = NEW.target_device_id
         AND target_device.agreement_public_key = NEW.target_agreement_public_key
         AND target_device.signing_public_key = NEW.target_signing_public_key
         AND moment_space.state = 'active'
         AND moment_space.membership_revision = NEW.expected_membership_revision
         AND moment_space.current_key_epoch = NEW.expected_key_epoch
         AND 1 = (
           SELECT COUNT(*) FROM moment_devices AS active_device
            WHERE active_device.participant_id = participant.id
              AND active_device.state = 'active'
         )
    ) THEN RAISE(ABORT, 'device recovery peers are not active') END);
END;

CREATE TRIGGER device_recoveries_restrict_state
BEFORE UPDATE OF state ON device_recoveries
WHEN NOT (
  OLD.state = NEW.state
  OR (OLD.state = 'open' AND NEW.state IN ('claimed', 'expired'))
  OR (OLD.state = 'claimed' AND NEW.state IN ('approved', 'expired'))
  OR (OLD.state = 'approved' AND NEW.state IN ('consumed', 'expired'))
)
BEGIN
    SELECT RAISE(ABORT, 'invalid device recovery transition');
END;

CREATE TABLE device_recovery_claim_events (
    recovery_id TEXT PRIMARY KEY REFERENCES device_recoveries(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    proposed_device_id TEXT NOT NULL UNIQUE,
    agreement_public_key TEXT NOT NULL,
    signing_public_key TEXT NOT NULL,
    transcript TEXT NOT NULL,
    transcript_hash TEXT NOT NULL,
    recovery_proof_signature TEXT,
    device_signature TEXT,
    created_at INTEGER NOT NULL,
    UNIQUE (recovery_id, client_request_id)
) STRICT;

CREATE TRIGGER device_recovery_claims_require_open_recovery
BEFORE INSERT ON device_recovery_claim_events
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM device_recoveries AS recovery
        JOIN spaces AS space ON space.id = recovery.space_id
        JOIN members AS initiator ON initiator.id = recovery.initiator_member_id
        JOIN members AS target ON target.id = recovery.target_member_id
        JOIN moment_spaces AS moment_space ON moment_space.space_id = recovery.space_id
       WHERE recovery.id = NEW.recovery_id
         AND recovery.state = 'open'
         AND recovery.expires_at > NEW.created_at
         AND recovery.recovery_proof_public_key IS NOT NULL
         AND space.state = 'active'
         AND initiator.state = 'active'
         AND target.state = 'active'
         AND moment_space.state = 'active'
         AND moment_space.membership_revision = recovery.expected_membership_revision
         AND moment_space.current_key_epoch = recovery.expected_key_epoch
         AND NEW.recovery_proof_signature IS NOT NULL
         AND NEW.device_signature IS NOT NULL
         AND NOT EXISTS (
           SELECT 1 FROM moment_devices WHERE id = NEW.proposed_device_id
         )
         AND NOT EXISTS (
           SELECT 1 FROM members AS existing
            WHERE existing.space_id = recovery.space_id
              AND (
                existing.agreement_public_key = NEW.agreement_public_key
                OR existing.signing_public_key = NEW.signing_public_key
              )
         )
         AND NOT EXISTS (
           SELECT 1
            FROM moment_devices AS existing_device
             JOIN moment_participants AS existing_participant
               ON existing_participant.id = existing_device.participant_id
            WHERE existing_participant.space_id = recovery.space_id
              AND (
                existing_device.agreement_public_key = NEW.agreement_public_key
                OR existing_device.signing_public_key = NEW.signing_public_key
              )
         )
    ) THEN RAISE(ABORT, 'device recovery cannot be claimed') END);
END;

CREATE TRIGGER device_recovery_claims_mark_claimed
AFTER INSERT ON device_recovery_claim_events
BEGIN
    UPDATE device_recoveries
       SET state = 'claimed', claimed_at = NEW.created_at
     WHERE id = NEW.recovery_id AND state = 'open';
END;

CREATE TABLE device_recovery_approval_events (
    recovery_id TEXT PRIMARY KEY REFERENCES device_recoveries(id) ON DELETE CASCADE,
    approver_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    transcript_hash TEXT NOT NULL,
    envelope_algorithm TEXT NOT NULL CHECK (
      envelope_algorithm = 'X25519-HKDF-SHA256-CHACHA20POLY1305'
    ),
    key_envelope TEXT,
    approval_signature TEXT,
    created_at INTEGER NOT NULL,
    UNIQUE (approver_member_id, client_request_id)
) STRICT;

CREATE TRIGGER device_recovery_approvals_require_claim
BEFORE INSERT ON device_recovery_approval_events
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM device_recoveries AS recovery
        JOIN device_recovery_claim_events AS claim
          ON claim.recovery_id = recovery.id
        JOIN spaces AS space ON space.id = recovery.space_id
        JOIN members AS initiator ON initiator.id = recovery.initiator_member_id
        JOIN members AS target ON target.id = recovery.target_member_id
        JOIN moment_spaces AS moment_space ON moment_space.space_id = recovery.space_id
       WHERE recovery.id = NEW.recovery_id
         AND recovery.state = 'claimed'
         AND recovery.expires_at > NEW.created_at
         AND recovery.initiator_member_id = NEW.approver_member_id
         AND initiator.state = 'active'
         AND target.state = 'active'
         AND space.state = 'active'
         AND moment_space.state = 'active'
         AND moment_space.membership_revision = recovery.expected_membership_revision
         AND moment_space.current_key_epoch = recovery.expected_key_epoch
         AND claim.transcript_hash = NEW.transcript_hash
         AND NEW.key_envelope IS NOT NULL
         AND NEW.approval_signature IS NOT NULL
    ) THEN RAISE(ABORT, 'device recovery cannot be approved') END);
END;

CREATE TRIGGER device_recovery_approvals_mark_approved
AFTER INSERT ON device_recovery_approval_events
BEGIN
    UPDATE device_recoveries
       SET state = 'approved', approved_at = NEW.created_at
     WHERE id = NEW.recovery_id AND state = 'claimed';
END;

CREATE TABLE device_recovery_completion_events (
    recovery_id TEXT PRIMARY KEY REFERENCES device_recoveries(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    transcript_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (recovery_id, client_request_id)
) STRICT;

CREATE TRIGGER device_recovery_completions_require_approval
BEFORE INSERT ON device_recovery_completion_events
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM device_recoveries AS recovery
        JOIN device_recovery_claim_events AS claim
          ON claim.recovery_id = recovery.id
        JOIN device_recovery_approval_events AS approval
          ON approval.recovery_id = recovery.id
        JOIN spaces AS space ON space.id = recovery.space_id
        JOIN members AS initiator ON initiator.id = recovery.initiator_member_id
        JOIN members AS target ON target.id = recovery.target_member_id
        JOIN moment_participants AS participant
          ON participant.id = recovery.target_moment_participant_id
        JOIN moment_devices AS target_device
          ON target_device.id = recovery.target_device_id
         AND target_device.participant_id = participant.id
        JOIN moment_spaces AS moment_space ON moment_space.space_id = recovery.space_id
       WHERE recovery.id = NEW.recovery_id
         AND recovery.state = 'approved'
         AND recovery.expires_at > NEW.created_at
         AND claim.transcript_hash = NEW.transcript_hash
         AND approval.transcript_hash = NEW.transcript_hash
         AND approval.key_envelope IS NOT NULL
         AND approval.approval_signature IS NOT NULL
         AND space.state = 'active'
         AND initiator.state = 'active'
         AND target.state = 'active'
         AND participant.state = 'active'
         AND participant.legacy_member_id = target.id
         AND target_device.state = 'active'
         AND target_device.legacy_member_id = target.id
         AND moment_space.state = 'active'
         AND moment_space.membership_revision = recovery.expected_membership_revision
         AND moment_space.current_key_epoch = recovery.expected_key_epoch
         AND 1 = (
           SELECT COUNT(*) FROM moment_devices AS active_device
            WHERE active_device.participant_id = participant.id
              AND active_device.state = 'active'
         )
    ) THEN RAISE(ABORT, 'device recovery cannot be completed') END);
END;

-- This trigger is the credential cutover boundary. All statements execute in
-- the completion INSERT transaction: an observer can authenticate either the
-- old device before it or the replacement after it, never a partial mixture.
CREATE TRIGGER device_recovery_completions_replace_device
AFTER INSERT ON device_recovery_completion_events
BEGIN
    UPDATE moment_devices
       SET state = 'revoked',
           revoked_at = NEW.created_at,
           report_only_until = NULL,
           legacy_member_id = NULL
     WHERE participant_id = (
       SELECT target_moment_participant_id
         FROM device_recoveries WHERE id = NEW.recovery_id
     )
       AND id = (
         SELECT target_device_id
           FROM device_recoveries WHERE id = NEW.recovery_id
       )
       AND state = 'active';

    INSERT INTO moment_devices(
      id, participant_id, legacy_member_id, agreement_public_key,
      signing_public_key, state, created_at, activated_at
    )
    SELECT claim.proposed_device_id,
           recovery.target_moment_participant_id,
           recovery.target_member_id,
           claim.agreement_public_key,
           claim.signing_public_key,
           'active', NEW.created_at, NEW.created_at
      FROM device_recoveries AS recovery
      JOIN device_recovery_claim_events AS claim
        ON claim.recovery_id = recovery.id
     WHERE recovery.id = NEW.recovery_id;

    DELETE FROM request_nonces
     WHERE member_id = (
       SELECT target_member_id FROM device_recoveries WHERE id = NEW.recovery_id
     );

    UPDATE device_recovery_approval_events
       SET key_envelope = NULL, approval_signature = NULL
     WHERE recovery_id = NEW.recovery_id;

    UPDATE device_recovery_claim_events
       SET recovery_proof_signature = NULL, device_signature = NULL
     WHERE recovery_id = NEW.recovery_id;

    UPDATE device_recoveries
       SET state = 'consumed',
           consumed_at = NEW.created_at,
           recovery_proof_public_key = NULL
     WHERE id = NEW.recovery_id AND state = 'approved';
END;

CREATE TABLE device_recovery_request_nonces (
    recovery_id TEXT NOT NULL REFERENCES device_recoveries(id) ON DELETE CASCADE,
    nonce TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (recovery_id, nonce)
) STRICT;

CREATE INDEX device_recovery_request_nonces_expiry
    ON device_recovery_request_nonces(expires_at);

-- A generic device revoke is a trust-boundary loss and still deletes the
-- encrypted window-name record. A completed, phrase-verified recovery is the
-- sole exception: the replacement owner receives the previous owner signing
-- key in the recovery status, verifies the old opaque record once, and
-- republishes the same plaintext under its new signing key. Invitee recovery
-- also must not erase an unrelated owner's valid signature.
DROP TRIGGER moment_window_names_delete_on_device_revoke;

CREATE TRIGGER moment_window_names_delete_on_device_revoke
AFTER UPDATE OF state ON moment_devices
WHEN OLD.state <> NEW.state AND NEW.state IN ('revoked', 'expired')
  AND NOT EXISTS (
    SELECT 1
      FROM device_recovery_completion_events AS completion
      JOIN device_recoveries AS recovery ON recovery.id = completion.recovery_id
     WHERE recovery.target_device_id = NEW.id
  )
BEGIN
    DELETE FROM moment_window_names
     WHERE space_id = (
       SELECT space_id FROM moment_participants WHERE id = NEW.participant_id
     );
    DELETE FROM idempotency_records
     WHERE operation = 'put-window-name'
       AND space_id = (
         SELECT space_id FROM moment_participants WHERE id = NEW.participant_id
       );
END;
