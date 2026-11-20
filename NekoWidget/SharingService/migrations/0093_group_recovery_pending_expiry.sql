-- Only pending enrollment and its encrypted offer rows expire. Active device
-- grants and committed recovery records are outside this lifecycle.
CREATE INDEX group_recovery_pending_expiry ON group_recovery_pending(created_at);
DROP TRIGGER group_recovery_pending_check;
DROP TRIGGER group_recovery_pending_slot;
CREATE TRIGGER group_recovery_pending_check BEFORE INSERT ON group_recovery_pending
BEGIN
 DELETE FROM group_recovery_pending WHERE person_id=NEW.person_id AND created_at<=unixepoch()-604800;
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM group_people p JOIN group_members m ON m.person_id=p.id JOIN group_windows w ON w.space_id=m.space_id
  WHERE p.id=NEW.person_id AND p.state='active' AND m.space_id=NEW.window_id AND m.state='active' AND w.mode='active')
  OR EXISTS(SELECT 1 FROM group_identity_deletion_acceptance WHERE subject_id=NEW.person_id)
 THEN RAISE(ABORT,'group_recovery_identity_unavailable') END);
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM group_person_devices WHERE id=NEW.device_id AND (person_id<>NEW.person_id OR state<>'active'))
  OR EXISTS(SELECT 1 FROM group_recovery_pending WHERE device_id=NEW.device_id AND created_at>unixepoch()-604800
   AND (person_id<>NEW.person_id OR signing_public_key<>NEW.signing_public_key OR hpke_public_key<>NEW.hpke_public_key))
 THEN RAISE(ABORT,'group_recovery_device_conflict') END);
 SELECT (CASE WHEN (SELECT COUNT(*) FROM (
  SELECT id FROM group_person_devices WHERE person_id=NEW.person_id AND state='active'
  UNION SELECT device_id FROM group_recovery_pending WHERE person_id=NEW.person_id
  UNION SELECT NEW.device_id
 ))>3 THEN RAISE(ABORT,'group_device_limit') END);
END;
-- Ordinary registration cannot bypass pending slots either.
CREATE TRIGGER group_recovery_pending_slot BEFORE INSERT ON group_person_devices WHEN NEW.state='active'
BEGIN
 DELETE FROM group_recovery_pending WHERE person_id=NEW.person_id AND created_at<=unixepoch()-604800;
 SELECT (CASE WHEN (SELECT COUNT(*) FROM (
  SELECT id FROM group_person_devices WHERE person_id=NEW.person_id AND state='active'
  UNION SELECT device_id FROM group_recovery_pending WHERE person_id=NEW.person_id
  UNION SELECT NEW.id
 ))>3 THEN RAISE(ABORT,'group_device_limit') END);
END;
-- Recheck expiry inside the same batch as envelope dispatch/admission.
CREATE TRIGGER group_recovery_key_pending_expiry BEFORE INSERT ON group_recovery_key_checks
WHEN EXISTS(SELECT 1 FROM group_recovery_pending WHERE person_id=NEW.person_id
 AND operation_id=NEW.operation_id AND created_at<=unixepoch()-604800)
BEGIN
 SELECT RAISE(ABORT,'group_recovery_pending_expired');
END;
CREATE TRIGGER group_recovery_fresh_pending_expiry BEFORE INSERT ON group_recovery_fresh_checks
WHEN EXISTS(SELECT 1 FROM group_recovery_pending WHERE person_id=NEW.person_id
 AND operation_id=NEW.operation_id AND created_at<=unixepoch()-604800)
BEGIN
 SELECT RAISE(ABORT,'group_recovery_pending_expired');
END;
