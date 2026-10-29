PRAGMA foreign_keys = ON;

-- Independent family consent. Nothing is imported from photo windows or the
-- on-device prototype. Runtime gates remain OFF and this migration is local
-- source only until the owner approves application to an environment.
CREATE TABLE family_notebook_invitations (
  id TEXT PRIMARY KEY, family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
  creator_person_id TEXT NOT NULL REFERENCES group_people(id),
  creator_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  proof_public_key TEXT NOT NULL, encrypted_preview TEXT NOT NULL,
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('active','used','revoked'))
) STRICT;
CREATE TABLE family_notebook_join_requests (
  id TEXT PRIMARY KEY, family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
  invitation_id TEXT NOT NULL UNIQUE REFERENCES family_notebook_invitations(id),
  person_id TEXT NOT NULL REFERENCES group_people(id), device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  encrypted_display_name TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','approved','rejected','cancelled')),
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
) STRICT;
CREATE TABLE family_notebook_admission_events (
  actor_device_id TEXT NOT NULL REFERENCES group_person_devices(id), operation_id TEXT NOT NULL,
  actor_person_id TEXT NOT NULL REFERENCES group_people(id), request_hash TEXT NOT NULL,
  family_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK(operation IN ('create','invite','revoke','join','approve','reject')),
  expected_generation INTEGER NOT NULL CHECK(expected_generation>=0),
  resulting_generation INTEGER NOT NULL CHECK(resulting_generation=expected_generation+(operation IN ('create','approve'))),
  invitation_id TEXT, join_id TEXT, proof_public_key TEXT, ciphertext TEXT,
  store_environment TEXT CHECK(store_environment IN ('Production','Sandbox')),
  maximum_members INTEGER NOT NULL CHECK(maximum_members BETWEEN 2 AND 64),
  recorded_at INTEGER NOT NULL DEFAULT(unixepoch()),
  PRIMARY KEY(actor_device_id,operation_id)
) STRICT;

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
    SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.actor_person_id AND environment=NEW.store_environment)
    THEN RAISE(ABORT,'family_notebook_plus_required') END);
  SELECT (CASE WHEN NEW.operation IN ('invite','join','approve') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces f JOIN group_verified_plus_people p ON p.person_id=f.payer_person_id
    WHERE f.id=NEW.family_id AND p.environment=NEW.store_environment)
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

CREATE TRIGGER family_notebook_admission_apply AFTER INSERT ON family_notebook_admission_events
BEGIN
  INSERT INTO family_notebook_spaces
    SELECT NEW.family_id,1,'active',NEW.actor_person_id,NULL,NULL,NEW.recorded_at,NEW.recorded_at
    WHERE NEW.operation='create';
  INSERT INTO family_notebook_members
    SELECT NEW.family_id,NEW.actor_person_id,'active',1,NULL WHERE NEW.operation='create';
  INSERT INTO family_notebook_invitations
    SELECT NEW.invitation_id,NEW.family_id,NEW.actor_person_id,NEW.actor_device_id,NEW.proof_public_key,NEW.ciphertext,
      NEW.recorded_at,NEW.recorded_at+86400,'active' WHERE NEW.operation='invite';
  UPDATE family_notebook_invitations SET state='revoked' WHERE NEW.operation='revoke' AND id=NEW.invitation_id;
  UPDATE family_notebook_join_requests SET state='cancelled'
    WHERE NEW.operation='revoke' AND invitation_id=NEW.invitation_id AND state='pending';
  INSERT INTO family_notebook_join_requests
    SELECT NEW.join_id,NEW.family_id,NEW.invitation_id,NEW.actor_person_id,NEW.actor_device_id,NEW.ciphertext,
      'pending',NEW.recorded_at,NEW.recorded_at+86400 WHERE NEW.operation='join';
  UPDATE family_notebook_invitations SET state='used' WHERE NEW.operation='join' AND id=NEW.invitation_id;
  INSERT INTO family_notebook_members
    SELECT NEW.family_id,j.person_id,'active',NEW.resulting_generation,NULL FROM family_notebook_join_requests j
    WHERE NEW.operation='approve' AND j.id=NEW.join_id
    ON CONFLICT(family_id,person_id) DO UPDATE SET state='active',admitted_generation=excluded.admitted_generation,left_generation=NULL;
  UPDATE family_notebook_spaces SET generation=NEW.resulting_generation,updated_at=NEW.recorded_at
    WHERE NEW.operation='approve' AND id=NEW.family_id;
  UPDATE family_notebook_join_requests SET state=(CASE WHEN NEW.operation='approve' THEN 'approved' ELSE 'rejected' END)
    WHERE NEW.operation IN ('approve','reject') AND id=NEW.join_id;
END;

-- Extend the previous guards only for an exact, authorized admission event.
DROP TRIGGER family_notebook_payer_state_guard;
CREATE TRIGGER family_notebook_payer_state_guard BEFORE UPDATE ON family_notebook_spaces
WHEN NOT EXISTS(
  SELECT 1 FROM family_notebook_payer_events e
  WHERE e.family_id=OLD.id AND e.expected_generation=OLD.generation AND e.resulting_generation=NEW.generation
    AND NEW.id=OLD.id AND NEW.state=OLD.state AND NEW.created_at=OLD.created_at
    AND NEW.nominated_person_id IS OLD.nominated_person_id AND NEW.updated_at=e.recorded_at
    AND NEW.payer_person_id IS (CASE WHEN e.operation='claim' THEN e.actor_person_id
      WHEN OLD.payer_person_id=e.actor_person_id THEN NULL ELSE OLD.payer_person_id END)
    AND NEW.payer_absent_since_generation IS (CASE WHEN e.operation='claim' THEN NULL
      WHEN OLD.payer_person_id=e.actor_person_id THEN e.resulting_generation ELSE OLD.payer_absent_since_generation END)
) AND NOT EXISTS(
  SELECT 1 FROM family_notebook_admission_events e
  WHERE e.family_id=OLD.id AND e.operation='approve' AND e.expected_generation=OLD.generation
    AND e.resulting_generation=NEW.generation AND NEW.updated_at=e.recorded_at
    AND NEW.id=OLD.id AND NEW.state=OLD.state AND NEW.created_at=OLD.created_at
    AND NEW.nominated_person_id IS OLD.nominated_person_id AND NEW.payer_person_id IS OLD.payer_person_id
    AND NEW.payer_absent_since_generation IS OLD.payer_absent_since_generation
)
BEGIN SELECT RAISE(ABORT,'family_notebook_payer_audit_required'); END;
DROP TRIGGER family_notebook_member_exit_guard;
CREATE TRIGGER family_notebook_member_exit_guard BEFORE UPDATE ON family_notebook_members
WHEN NOT EXISTS(
  SELECT 1 FROM family_notebook_payer_events e WHERE e.family_id=OLD.family_id AND e.actor_person_id=OLD.person_id
    AND e.operation='leave' AND OLD.state='active' AND NEW.state='left'
    AND NEW.family_id=OLD.family_id AND NEW.person_id=OLD.person_id
    AND NEW.admitted_generation=OLD.admitted_generation AND NEW.left_generation=e.resulting_generation
    AND e.expected_generation=(SELECT generation FROM family_notebook_spaces WHERE id=OLD.family_id)
) AND NOT EXISTS(
  SELECT 1 FROM family_notebook_admission_events e JOIN family_notebook_join_requests j ON j.id=e.join_id
  WHERE e.family_id=OLD.family_id AND e.operation='approve' AND j.person_id=OLD.person_id AND j.state='pending'
    AND OLD.state<>'active' AND NEW.state='active' AND NEW.left_generation IS NULL
    AND NEW.family_id=OLD.family_id AND NEW.person_id=OLD.person_id AND NEW.admitted_generation=e.resulting_generation
    AND e.expected_generation=(SELECT generation FROM family_notebook_spaces WHERE id=OLD.family_id)
)
BEGIN SELECT RAISE(ABORT,'family_notebook_membership_audit_required'); END;

CREATE TRIGGER family_notebook_departed_inviter AFTER INSERT ON family_notebook_payer_events WHEN NEW.operation='leave'
BEGIN
  UPDATE family_notebook_invitations SET state='revoked'
    WHERE family_id=NEW.family_id AND creator_person_id=NEW.actor_person_id;
  UPDATE family_notebook_join_requests SET state='cancelled'
    WHERE family_id=NEW.family_id AND state='pending' AND (person_id=NEW.actor_person_id OR invitation_id IN (
      SELECT id FROM family_notebook_invitations WHERE family_id=NEW.family_id AND creator_person_id=NEW.actor_person_id));
END;
CREATE TRIGGER family_notebook_admission_events_immutable BEFORE UPDATE ON family_notebook_admission_events
BEGIN SELECT RAISE(ABORT,'family_notebook_event_immutable'); END;
CREATE TRIGGER family_notebook_admission_events_retained BEFORE DELETE ON family_notebook_admission_events
BEGIN SELECT RAISE(ABORT,'family_notebook_event_retained'); END;

CREATE TABLE family_notebook_invitation_checks (
  id TEXT PRIMARY KEY, family_id TEXT NOT NULL, invitation_id TEXT NOT NULL, expected_generation INTEGER NOT NULL
) STRICT;
CREATE TRIGGER family_notebook_invitation_check BEFORE INSERT ON family_notebook_invitation_checks
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM family_notebook_invitations i JOIN family_notebook_spaces f ON f.id=i.family_id
      JOIN family_notebook_members m ON m.family_id=f.id AND m.person_id=i.creator_person_id
      JOIN group_person_devices d ON d.id=i.creator_device_id
      JOIN group_people p ON p.id=i.creator_person_id
    WHERE i.id=NEW.invitation_id AND f.id=NEW.family_id AND f.state='active' AND f.generation=NEW.expected_generation
      AND i.state='active' AND i.expires_at>unixepoch() AND m.state='active' AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invitation_unavailable') END);
END;
