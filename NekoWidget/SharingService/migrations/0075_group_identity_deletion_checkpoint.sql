-- An independent R2 journal publishes each acceptance before erasure. Update
-- the checkpoint only after all D1/R2 phases. No keys or receipts are stored here.
CREATE TABLE group_identity_deletion_checkpoint(
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  sequence INTEGER NOT NULL CHECK(sequence>=0),
  request_id TEXT NOT NULL
) STRICT;
INSERT INTO group_identity_deletion_checkpoint VALUES (1,0,'');
CREATE TABLE group_identity_deletion_acceptance(
  request_id TEXT PRIMARY KEY, subject_id TEXT NOT NULL, nonce TEXT NOT NULL, request_hash TEXT NOT NULL, accepted_at INTEGER NOT NULL,
  data_erased INTEGER NOT NULL DEFAULT 0 CHECK(data_erased IN (0,1)),
  head_cursor INTEGER NOT NULL DEFAULT 0 CHECK(head_cursor>=0)
) STRICT;

CREATE UNIQUE INDEX group_identity_one_preparation ON group_identity_deletion_acceptance((1));
CREATE INDEX group_identity_deletion_subject ON group_identity_deletion_acceptance(subject_id);
CREATE TRIGGER group_identity_freeze_authorization BEFORE INSERT ON group_authorization_checks
WHEN EXISTS(SELECT 1 FROM group_person_devices d JOIN group_identity_deletion_acceptance a ON a.subject_id=d.person_id WHERE d.id=NEW.device_id AND a.accepted_at>=unixepoch()-600)
BEGIN
 SELECT RAISE(ABORT,'group_invalid_authentication');
END;
