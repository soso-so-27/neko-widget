PRAGMA foreign_keys = ON;

-- Keep this migration LF-only; Wrangler remote trigger parsing rejects CRLF.
-- Recovery protocol v2 remains phrase-verified and peer-approved, but now
-- enrolls an additional device instead of revoking the participant's existing
-- iPhone. A participant is still one of exactly two people in the space.

DROP TRIGGER device_recoveries_require_active_peers;

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
         AND 1 <= (
           SELECT COUNT(*) FROM moment_devices AS active_device
            WHERE active_device.participant_id = participant.id
              AND active_device.state = 'active'
         )
         AND 4 > (
           SELECT COUNT(*) FROM moment_devices AS active_device
            WHERE active_device.participant_id = participant.id
              AND active_device.state = 'active'
         )
    ) THEN RAISE(ABORT, 'device enrollment peers are not active') END);
END;

DROP TRIGGER device_recovery_completions_require_approval;

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
         AND 1 <= (
           SELECT COUNT(*) FROM moment_devices AS active_device
            WHERE active_device.participant_id = participant.id
              AND active_device.state = 'active'
         )
         AND 4 > (
           SELECT COUNT(*) FROM moment_devices AS active_device
            WHERE active_device.participant_id = participant.id
              AND active_device.state = 'active'
         )
    ) THEN RAISE(ABORT, 'device enrollment cannot be completed') END);
END;

DROP TRIGGER device_recovery_completions_replace_device;

CREATE TRIGGER device_recovery_completions_add_device
AFTER INSERT ON device_recovery_completion_events
BEGIN
    INSERT INTO moment_devices(
      id, participant_id, legacy_member_id, agreement_public_key,
      signing_public_key, state, created_at, activated_at
    )
    SELECT claim.proposed_device_id,
           recovery.target_moment_participant_id,
           NULL,
           claim.agreement_public_key,
           claim.signing_public_key,
           'active', NEW.created_at, NEW.created_at
      FROM device_recoveries AS recovery
      JOIN device_recovery_claim_events AS claim
        ON claim.recovery_id = recovery.id
     WHERE recovery.id = NEW.recovery_id;

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
