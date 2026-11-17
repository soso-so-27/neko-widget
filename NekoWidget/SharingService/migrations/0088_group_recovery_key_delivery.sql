-- Encrypted delivery attempts only. Pending registration owns their lifetime.
CREATE TABLE group_recovery_key_offers (
 person_id TEXT NOT NULL, operation_id TEXT NOT NULL, key_epoch INTEGER NOT NULL,
 offer_id TEXT NOT NULL, window_id TEXT NOT NULL, roster_hash TEXT NOT NULL,
 sender_device_id TEXT NOT NULL, offer_json TEXT NOT NULL, offer_hash TEXT NOT NULL,
 expires_at INTEGER NOT NULL, received_at INTEGER, receipt_signature TEXT,
 person_authorization TEXT,
 PRIMARY KEY(person_id,operation_id,key_epoch),
 FOREIGN KEY(person_id,operation_id) REFERENCES group_recovery_pending(person_id,operation_id) ON DELETE CASCADE
) STRICT;
CREATE INDEX group_recovery_key_offer_expiry ON group_recovery_key_offers(expires_at);
CREATE TABLE group_recovery_key_checks (
 id TEXT PRIMARY KEY, person_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 window_id TEXT NOT NULL, roster_hash TEXT NOT NULL, device_id TEXT NOT NULL, receipt_set_json TEXT
) STRICT;
CREATE TRIGGER group_recovery_key_check BEFORE INSERT ON group_recovery_key_checks BEGIN
 SELECT (CASE WHEN NOT EXISTS (
  SELECT 1 FROM group_recovery_pending r JOIN group_people p ON p.id=r.person_id
  JOIN group_members m ON m.person_id=p.id AND m.space_id=r.window_id
  JOIN group_windows w ON w.space_id=r.window_id
  WHERE r.person_id=NEW.person_id AND r.operation_id=NEW.operation_id AND r.window_id=NEW.window_id
   AND r.device_id=NEW.device_id AND p.state='active' AND m.state='active' AND w.mode='active'
   AND w.roster_hash=NEW.roster_hash)
  OR EXISTS(SELECT 1 FROM group_identity_deletion_acceptance WHERE subject_id=NEW.person_id)
  OR EXISTS(SELECT 1 FROM group_recovery_device_removals WHERE device_id=NEW.device_id)
  OR EXISTS(SELECT 1 FROM group_person_devices WHERE id=NEW.device_id AND (state<>'active' OR person_id<>NEW.person_id))
  THEN RAISE(ABORT,'group_recovery_key_state_changed') END);
END;
CREATE TRIGGER group_recovery_key_receipts_check BEFORE INSERT ON group_recovery_key_checks
WHEN NEW.receipt_set_json IS NOT NULL BEGIN
 SELECT (CASE WHEN NEW.receipt_set_json<>(SELECT json_group_array(offer_hash) FROM
  (SELECT offer_hash FROM group_recovery_key_offers WHERE person_id=NEW.person_id AND operation_id=NEW.operation_id
   AND roster_hash=NEW.roster_hash ORDER BY key_epoch))
  OR EXISTS(SELECT 1 FROM group_recovery_key_offers WHERE person_id=NEW.person_id AND operation_id=NEW.operation_id
   AND roster_hash=NEW.roster_hash AND (received_at IS NULL OR expires_at<=unixepoch()))
  OR NOT EXISTS(SELECT 1 FROM group_recovery_key_offers o JOIN group_windows w ON w.space_id=o.window_id
   WHERE o.person_id=NEW.person_id AND o.operation_id=NEW.operation_id AND o.roster_hash=NEW.roster_hash
   AND o.key_epoch=w.key_epoch AND o.received_at IS NOT NULL)
  THEN RAISE(ABORT,'group_recovery_key_receipts_changed') END);
END;
CREATE TABLE group_recovery_key_completions (
 person_id TEXT NOT NULL REFERENCES group_people(id), operation_id TEXT NOT NULL,
 window_id TEXT NOT NULL REFERENCES group_windows(space_id), device_id TEXT NOT NULL,
 previous_hash TEXT NOT NULL, result_revision INTEGER NOT NULL, result_hash TEXT NOT NULL,
 created_at INTEGER NOT NULL, PRIMARY KEY(person_id,operation_id)
) STRICT;
CREATE TRIGGER group_recovery_key_completion_revoke AFTER UPDATE OF state ON group_people
WHEN NEW.state<>'active'
BEGIN DELETE FROM group_recovery_key_completions WHERE person_id=NEW.id; END;

CREATE TRIGGER group_recovery_key_completion_erasure AFTER INSERT ON group_identity_deletion_acceptance
BEGIN DELETE FROM group_recovery_key_completions WHERE person_id=NEW.subject_id;
 DELETE FROM group_recovery_participation WHERE person_id=NEW.subject_id; END;
CREATE TRIGGER group_recovery_key_completion_leave AFTER UPDATE OF state ON group_members WHEN NEW.state<>'active'
BEGIN DELETE FROM group_recovery_key_completions WHERE person_id=NEW.person_id AND window_id=NEW.space_id; END;
CREATE TRIGGER group_recovery_key_completion_close AFTER UPDATE OF mode ON group_windows WHEN NEW.mode<>'active'
BEGIN DELETE FROM group_recovery_key_completions WHERE window_id=NEW.space_id; END;
