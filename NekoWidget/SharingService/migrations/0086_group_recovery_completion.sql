-- Additive recovery commands. No existing row is changed by applying this file.
CREATE TABLE group_recovery_device_removals (
 person_id TEXT NOT NULL REFERENCES group_people(id), operation_id TEXT NOT NULL,
 device_id TEXT NOT NULL, created_at INTEGER NOT NULL,
 PRIMARY KEY(person_id,operation_id), UNIQUE(person_id,device_id)
) STRICT;
CREATE TRIGGER group_recovery_removed_device_insert BEFORE INSERT ON group_person_devices
WHEN EXISTS(SELECT 1 FROM group_recovery_device_removals WHERE device_id=NEW.id)
BEGIN SELECT RAISE(ABORT,'group_recovery_device_removed'); END;
CREATE TRIGGER group_recovery_removed_pending_insert BEFORE INSERT ON group_recovery_pending
WHEN EXISTS(SELECT 1 FROM group_recovery_device_removals WHERE device_id=NEW.device_id)
BEGIN SELECT RAISE(ABORT,'group_recovery_device_removed'); END;
CREATE TABLE group_recovery_fresh_generations (
 person_id TEXT NOT NULL REFERENCES group_people(id), operation_id TEXT NOT NULL,
 window_id TEXT NOT NULL REFERENCES group_windows(space_id), device_id TEXT NOT NULL,
 previous_revision INTEGER NOT NULL, result_revision INTEGER NOT NULL,
 result_hash TEXT NOT NULL, request_hash TEXT NOT NULL, proof_json TEXT NOT NULL,
 created_at INTEGER NOT NULL, PRIMARY KEY(person_id,operation_id),
 UNIQUE(window_id,result_revision)
) STRICT;
-- Root authenticated commands use the existing one-use challenge claim/check.
-- This additional atomic guard prevents a stale no-provider observation from
-- changing an active window after another device/member has appeared.
CREATE TABLE group_recovery_fresh_checks (
 id TEXT PRIMARY KEY, person_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 window_id TEXT NOT NULL, device_id TEXT NOT NULL,
 revision INTEGER NOT NULL, roster_hash TEXT NOT NULL
) STRICT;
CREATE TRIGGER group_recovery_fresh_check BEFORE INSERT ON group_recovery_fresh_checks BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM group_windows w JOIN group_members m ON m.space_id=w.space_id
  JOIN group_people p ON p.id=m.person_id JOIN group_recovery_pending r ON r.window_id=w.space_id AND r.person_id=p.id
  WHERE w.space_id=NEW.window_id AND w.mode='active' AND w.owner_person_id=NEW.person_id
  AND w.revision=NEW.revision AND w.roster_hash=NEW.roster_hash AND p.state='active'
  AND m.state='active' AND m.role='owner' AND r.operation_id=NEW.operation_id AND r.device_id=NEW.device_id)
  OR EXISTS(SELECT 1 FROM group_identity_deletion_acceptance WHERE subject_id=NEW.person_id)
  OR EXISTS(SELECT 1 FROM group_members WHERE space_id=NEW.window_id AND state='active' AND person_id<>NEW.person_id)
  OR EXISTS(SELECT 1 FROM group_window_devices w JOIN group_person_devices d ON d.id=w.device_id
    WHERE w.space_id=NEW.window_id AND w.state='active' AND d.state='active')
  OR EXISTS(SELECT 1 FROM group_person_devices WHERE id=NEW.device_id AND state<>'active')
  OR EXISTS(SELECT 1 FROM group_recovery_device_removals WHERE device_id=NEW.device_id)
 THEN RAISE(ABORT,'group_recovery_fresh_state_changed') END);
END;
