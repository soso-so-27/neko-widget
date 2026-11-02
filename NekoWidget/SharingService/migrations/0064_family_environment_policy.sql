PRAGMA foreign_keys = ON;

-- Existing event writers use named columns: absent permission stays single-store.
-- Existing rows, immutable audit receipts, membership and keys are retained.

ALTER TABLE family_notebook_payer_events ADD COLUMN accept_sandbox_in_production INTEGER NOT NULL DEFAULT 0 CHECK (accept_sandbox_in_production IN (0,1) AND (accept_sandbox_in_production=0 OR store_environment IS 'Production'));

ALTER TABLE family_notebook_admission_events ADD COLUMN accept_sandbox_in_production INTEGER NOT NULL DEFAULT 0 CHECK (accept_sandbox_in_production IN (0,1) AND (accept_sandbox_in_production=0 OR store_environment IS 'Production'));

ALTER TABLE family_notebook_governance_events ADD COLUMN accept_sandbox_in_production INTEGER NOT NULL DEFAULT 0 CHECK (accept_sandbox_in_production IN (0,1) AND (accept_sandbox_in_production=0 OR store_environment IS 'Production'));

DROP TRIGGER family_notebook_payer_event_validate;

CREATE TRIGGER family_notebook_payer_event_validate BEFORE INSERT ON family_notebook_payer_events
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NEW.recorded_at<>unixepoch()
    THEN RAISE(ABORT,'family_notebook_invalid_time') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.actor_device_id AND d.person_id=NEW.actor_person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE f.id=NEW.family_id AND f.state='active' AND m.person_id=NEW.actor_person_id AND m.state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN (SELECT generation FROM family_notebook_spaces WHERE id=NEW.family_id)<>NEW.expected_generation
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.operation='claim' AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces f JOIN family_notebook_members m ON m.family_id=f.id
    WHERE f.id=NEW.family_id AND f.payer_person_id IS NULL AND f.nominated_person_id IS NULL
      AND m.person_id=NEW.actor_person_id AND m.state='active'
      AND m.admitted_generation<=f.payer_absent_since_generation)
    THEN RAISE(ABORT,'family_notebook_claim_unavailable') END);
  -- The verified authority view rechecks revocation, expiry, grace, current
  -- environment and lower billing gate at COMMIT time. Neither a local Plus
  -- boolean nor a billing connection alone is evidence of paid membership.
  SELECT (CASE WHEN NEW.operation='claim' AND NOT EXISTS(
    SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.actor_person_id AND (environment=NEW.store_environment OR (NEW.store_environment='Production' AND NEW.accept_sandbox_in_production=1 AND environment='Sandbox')))
    THEN RAISE(ABORT,'family_notebook_plus_required') END);
END;

DROP TRIGGER family_notebook_admission_validate;

CREATE TRIGGER family_notebook_admission_validate BEFORE INSERT ON family_notebook_admission_events
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NEW.recorded_at<>unixepoch() OR NOT EXISTS(
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.actor_device_id AND d.person_id=NEW.actor_person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NEW.operation='create' AND (NEW.expected_generation<>0 OR EXISTS(
    SELECT 1 FROM family_notebook_spaces WHERE id=NEW.family_id))
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.operation<>'create' AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces WHERE id=NEW.family_id AND state='active' AND generation=NEW.expected_generation)
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  -- The unique-family rule is checked inside the same serialized transaction
  -- as admission, including races between invitations to different families.
  SELECT (CASE WHEN NEW.operation IN ('create','join') AND EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE m.person_id=NEW.actor_person_id AND m.state='active' AND f.state='active')
    THEN RAISE(ABORT,'family_notebook_already_in_family') END);
  SELECT (CASE WHEN NEW.operation NOT IN ('create','join') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_members WHERE family_id=NEW.family_id AND person_id=NEW.actor_person_id AND state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN NEW.operation='create' AND NOT EXISTS(
    SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.actor_person_id AND (environment=NEW.store_environment OR (NEW.store_environment='Production' AND NEW.accept_sandbox_in_production=1 AND environment='Sandbox')))
    THEN RAISE(ABORT,'family_notebook_plus_required') END);
  SELECT (CASE WHEN NEW.operation IN ('invite','join','approve') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces f JOIN group_verified_plus_people p ON p.person_id=f.payer_person_id
    WHERE f.id=NEW.family_id AND (p.environment=NEW.store_environment OR (NEW.store_environment='Production' AND NEW.accept_sandbox_in_production=1 AND p.environment='Sandbox')))
    THEN RAISE(ABORT,'family_notebook_paused') END);
  SELECT (CASE WHEN NEW.operation='join' AND NOT EXISTS(
    SELECT 1 FROM family_notebook_invitations i JOIN family_notebook_members m
      ON m.family_id=i.family_id AND m.person_id=i.creator_person_id
      JOIN group_person_devices d ON d.id=i.creator_device_id
      JOIN group_people p ON p.id=i.creator_person_id
    WHERE i.id=NEW.invitation_id AND i.family_id=NEW.family_id AND i.state='active'
      AND i.expires_at>unixepoch() AND m.state='active' AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invitation_unavailable') END);
  SELECT (CASE WHEN NEW.operation='revoke' AND NOT EXISTS(
    SELECT 1 FROM family_notebook_invitations i JOIN family_notebook_spaces f ON f.id=i.family_id
    WHERE i.id=NEW.invitation_id AND i.family_id=NEW.family_id
      AND (i.creator_person_id=NEW.actor_person_id OR f.payer_person_id=NEW.actor_person_id))
    THEN RAISE(ABORT,'family_notebook_not_allowed') END);
  SELECT (CASE WHEN NEW.operation IN ('approve','reject') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_join_requests j JOIN family_notebook_invitations i ON i.id=j.invitation_id
      JOIN family_notebook_spaces f ON f.id=j.family_id
      JOIN family_notebook_members m ON m.family_id=f.id AND m.person_id=i.creator_person_id
      JOIN group_people inviter ON inviter.id=i.creator_person_id
      JOIN group_person_devices inviter_device ON inviter_device.id=i.creator_device_id
      JOIN group_people p ON p.id=j.person_id JOIN group_person_devices d ON d.id=j.device_id AND d.person_id=j.person_id
    WHERE j.id=NEW.join_id AND j.family_id=NEW.family_id AND j.state='pending' AND j.expires_at>unixepoch()
      AND i.state='used' AND m.state='active' AND p.state='active' AND d.state='active'
      AND inviter.state='active' AND inviter_device.state='active'
      AND (i.creator_person_id=NEW.actor_person_id OR f.payer_person_id=NEW.actor_person_id))
    THEN RAISE(ABORT,'family_notebook_request_not_pending') END);
  SELECT (CASE WHEN NEW.operation='approve' AND EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE m.person_id=(SELECT person_id FROM family_notebook_join_requests WHERE id=NEW.join_id)
      AND m.state='active' AND f.state='active')
    THEN RAISE(ABORT,'family_notebook_already_in_family') END);
  SELECT (CASE WHEN NEW.operation='approve' AND (
    SELECT COUNT(*) FROM family_notebook_members WHERE family_id=NEW.family_id AND state='active')>=NEW.maximum_members
    THEN RAISE(ABORT,'family_notebook_member_limit') END);
  SELECT (CASE WHEN NEW.operation='invite' AND (
    SELECT COUNT(*) FROM family_notebook_invitations WHERE family_id=NEW.family_id AND state='active' AND expires_at>unixepoch())>=32
    THEN RAISE(ABORT,'family_notebook_rate_limited') END);
END;

DROP TRIGGER family_notebook_governance_validate;

CREATE TRIGGER family_notebook_governance_validate BEFORE INSERT ON family_notebook_governance_events
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NEW.recorded_at<>unixepoch() THEN RAISE(ABORT,'family_notebook_invalid_time') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.actor_device_id AND d.person_id=NEW.actor_person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE m.family_id=NEW.family_id AND m.person_id=NEW.actor_person_id AND m.state='active' AND f.state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN (SELECT generation FROM family_notebook_spaces WHERE id=NEW.family_id)<>NEW.expected_generation
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.action IN ('remove','dissolve','nominate') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces WHERE id=NEW.family_id AND payer_person_id=NEW.actor_person_id)
    THEN RAISE(ABORT,'family_notebook_not_allowed') END);
  SELECT (CASE WHEN NEW.action IN ('remove','nominate') AND (NEW.target_person_id=NEW.actor_person_id OR NOT EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN group_people p ON p.id=m.person_id
    WHERE m.family_id=NEW.family_id AND m.person_id=NEW.target_person_id AND m.state='active'
      AND (NEW.action='remove' OR p.state='active')))
    THEN RAISE(ABORT,'family_notebook_not_allowed') END);
  SELECT (CASE WHEN NEW.action='nominate' AND (
    NEW.nomination_id<>NEW.operation_id OR EXISTS(SELECT 1 FROM family_notebook_handover_current WHERE family_id=NEW.family_id)
    OR (SELECT nominated_person_id FROM family_notebook_spaces WHERE id=NEW.family_id) IS NOT NULL)
    THEN RAISE(ABORT,'family_notebook_nomination_changed') END);
  SELECT (CASE WHEN NEW.action IN ('accept','cancel') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_handover_current h JOIN family_notebook_spaces f ON f.id=h.family_id
      JOIN family_notebook_members m ON m.family_id=h.family_id AND m.person_id=h.nominee_person_id
    WHERE h.family_id=NEW.family_id AND h.nomination_id=NEW.nomination_id AND h.nominee_person_id=NEW.target_person_id
      AND f.nominated_person_id=h.nominee_person_id AND m.state='active'
      AND ((NEW.action='accept' AND h.nominee_person_id=NEW.actor_person_id)
        OR (NEW.action='cancel' AND (f.payer_person_id=NEW.actor_person_id OR h.nominee_person_id=NEW.actor_person_id))))
    THEN RAISE(ABORT,'family_notebook_nomination_changed') END);
  SELECT (CASE WHEN NEW.action='accept' AND NOT EXISTS(
    SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.actor_person_id AND (environment=NEW.store_environment OR (NEW.store_environment='Production' AND NEW.accept_sandbox_in_production=1 AND environment='Sandbox')))
    THEN RAISE(ABORT,'family_notebook_plus_required') END);
END;

-- Old Worker uses an eight-value INSERT here. Keep that table/guard intact.

CREATE TABLE family_notebook_crypto_environment_checks (
  id TEXT PRIMARY KEY, family_id TEXT NOT NULL, person_id TEXT NOT NULL, device_id TEXT NOT NULL,
  generation INTEGER NOT NULL, epoch INTEGER,
  mode TEXT NOT NULL CHECK(mode IN ('read','device','roster','key','operation','ready')),
  store_environment TEXT CHECK(store_environment IN ('Production','Sandbox')),
  accept_sandbox_in_production INTEGER NOT NULL DEFAULT 0 CHECK (accept_sandbox_in_production IN (0,1) AND (accept_sandbox_in_production=0 OR store_environment IS 'Production'))
) STRICT;

CREATE TRIGGER family_notebook_crypto_environment_check_validate BEFORE INSERT ON family_notebook_crypto_environment_checks
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.device_id AND d.person_id=NEW.person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE m.family_id=NEW.family_id AND m.person_id=NEW.person_id AND m.state='active' AND f.state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN (SELECT generation FROM family_notebook_spaces WHERE id=NEW.family_id)<>NEW.generation
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.epoch IS NOT NULL AND COALESCE((SELECT epoch FROM family_notebook_crypto_heads WHERE family_id=NEW.family_id),0)<>NEW.epoch
    THEN RAISE(ABORT,'family_notebook_crypto_stale') END);
  SELECT (CASE WHEN NEW.mode IN ('key','operation','ready') AND NOT EXISTS (
    SELECT 1 FROM family_notebook_crypto_ready WHERE family_id=NEW.family_id)
    THEN RAISE(ABORT,'family_notebook_crypto_stale') END);
  SELECT (CASE WHEN NEW.mode='operation' AND NOT EXISTS (
    SELECT 1 FROM family_notebook_spaces f JOIN group_verified_plus_people p ON p.person_id=f.payer_person_id
    WHERE f.id=NEW.family_id AND (p.environment=NEW.store_environment OR (NEW.store_environment='Production' AND NEW.accept_sandbox_in_production=1 AND p.environment='Sandbox')))
    THEN RAISE(ABORT,'family_notebook_paused') END);
END;
