-- Pending recovery grants no membership, key access, or roster/epoch change.
CREATE TABLE group_recovery_pending (
 person_id TEXT NOT NULL REFERENCES group_people(id) ON DELETE CASCADE,
 operation_id TEXT NOT NULL,
 window_id TEXT NOT NULL REFERENCES group_windows(space_id) ON DELETE CASCADE,
 environment TEXT NOT NULL CHECK(environment IN ('staging','production')),
 device_id TEXT NOT NULL,
 signing_public_key TEXT NOT NULL,
 hpke_public_key TEXT NOT NULL,
 model TEXT NOT NULL CHECK(length(model) BETWEEN 1 AND 80),
 request_hash TEXT NOT NULL,
 proof_json TEXT NOT NULL,
 created_at INTEGER NOT NULL,
 PRIMARY KEY(person_id,operation_id),
 UNIQUE(person_id,window_id,device_id)
) STRICT;
CREATE INDEX group_recovery_pending_window ON group_recovery_pending(window_id,person_id);
CREATE TRIGGER group_recovery_pending_check BEFORE INSERT ON group_recovery_pending
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM group_people p JOIN group_members m ON m.person_id=p.id JOIN group_windows w ON w.space_id=m.space_id
  WHERE p.id=NEW.person_id AND p.state='active' AND m.space_id=NEW.window_id AND m.state='active' AND w.mode='active')
  OR EXISTS(SELECT 1 FROM group_identity_deletion_acceptance WHERE subject_id=NEW.person_id)
 THEN RAISE(ABORT,'group_recovery_identity_unavailable') END);
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM group_person_devices WHERE id=NEW.device_id AND (person_id<>NEW.person_id OR state<>'active'))
  OR EXISTS(SELECT 1 FROM group_recovery_pending WHERE device_id=NEW.device_id AND (person_id<>NEW.person_id OR signing_public_key<>NEW.signing_public_key OR hpke_public_key<>NEW.hpke_public_key))
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
 SELECT (CASE WHEN (SELECT COUNT(*) FROM (
  SELECT id FROM group_person_devices WHERE person_id=NEW.person_id AND state='active'
  UNION SELECT device_id FROM group_recovery_pending WHERE person_id=NEW.person_id
  UNION SELECT NEW.id
 ))>3 THEN RAISE(ABORT,'group_device_limit') END);
END;
CREATE TRIGGER group_recovery_pending_root_cleanup AFTER UPDATE OF state ON group_people WHEN NEW.state='revoked'
BEGIN DELETE FROM group_recovery_pending WHERE person_id=NEW.id;
END;
CREATE TRIGGER group_recovery_pending_erasure_cleanup AFTER INSERT ON group_identity_deletion_acceptance
BEGIN DELETE FROM group_recovery_pending WHERE person_id=NEW.subject_id;
END;
CREATE TRIGGER group_recovery_pending_member_cleanup AFTER UPDATE OF state ON group_members WHEN NEW.state<>'active'
BEGIN DELETE FROM group_recovery_pending WHERE person_id=NEW.person_id AND window_id=NEW.space_id;
END;
CREATE TRIGGER group_recovery_pending_window_cleanup AFTER UPDATE OF mode ON group_windows WHEN NEW.mode<>'active'
BEGIN DELETE FROM group_recovery_pending WHERE window_id=NEW.space_id;
END;
