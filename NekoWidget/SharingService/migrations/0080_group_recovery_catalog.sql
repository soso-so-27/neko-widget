-- Additive recovery preflight only. No device/roster issuance or gate changes.
CREATE TABLE group_recovery_challenges (
  id TEXT PRIMARY KEY,
  person_id TEXT NOT NULL,
  identity_public_key TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  purpose TEXT NOT NULL CHECK(purpose IN ('catalog','status','register')),
  environment TEXT NOT NULL CHECK(environment IN ('production','staging')),
  nonce TEXT NOT NULL,
  issued_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL CHECK(expires_at>issued_at AND expires_at-issued_at<=300),
  consumed_at INTEGER,
  consumed_by TEXT
) STRICT;
CREATE INDEX group_recovery_challenge_expiry ON group_recovery_challenges(expires_at);
CREATE INDEX group_recovery_challenge_person ON group_recovery_challenges(person_id);

CREATE TABLE group_recovery_device_labels (
  device_id TEXT PRIMARY KEY REFERENCES group_person_devices(id) ON DELETE CASCADE,
  model TEXT NOT NULL CHECK(length(model) BETWEEN 1 AND 80)
) STRICT;

-- Ephemeral rows force atomic challenge claim + current identity validation.
CREATE TABLE group_recovery_read_checks (
  id TEXT PRIMARY KEY,
  person_id TEXT NOT NULL,
  challenge_id TEXT NOT NULL,
  consumed_at INTEGER NOT NULL
) STRICT;
CREATE TRIGGER group_recovery_read_check BEFORE INSERT ON group_recovery_read_checks
BEGIN
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM group_recovery_challenges c WHERE c.id=NEW.challenge_id
      AND c.person_id=NEW.person_id AND c.consumed_at=NEW.consumed_at AND c.consumed_by=NEW.id
      AND c.expires_at>unixepoch()
  ) THEN RAISE(ABORT,'group_recovery_challenge_invalid') END);
  SELECT (CASE WHEN EXISTS (
    SELECT 1 FROM group_people WHERE id=NEW.person_id AND state<>'active'
  ) OR EXISTS (
    SELECT 1 FROM group_identity_deletion_acceptance WHERE subject_id=NEW.person_id
  ) THEN RAISE(ABORT,'group_recovery_identity_unavailable') END);
END;

CREATE TRIGGER group_recovery_identity_cleanup AFTER UPDATE OF state ON group_people
WHEN NEW.state='revoked'
BEGIN
  DELETE FROM group_recovery_challenges WHERE person_id=NEW.id;
  DELETE FROM group_recovery_read_checks WHERE person_id=NEW.id;
  DELETE FROM group_recovery_device_labels WHERE device_id IN
    (SELECT id FROM group_person_devices WHERE person_id=NEW.id);
END;
