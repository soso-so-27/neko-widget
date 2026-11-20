-- An entry records the confirmed tombstone and its original request time.
-- A queue entry alone is never authority for permanent object deletion.
CREATE TABLE pa_record_physical_delete_queue (
 owner_id TEXT NOT NULL,
 record_id TEXT NOT NULL,
 tombstone_revision INTEGER NOT NULL CHECK(tombstone_revision>1),
 requested_at INTEGER NOT NULL CHECK(requested_at>0),
 next_attempt_at INTEGER NOT NULL DEFAULT 0 CHECK(next_attempt_at>=0),
 PRIMARY KEY(owner_id,record_id),
 FOREIGN KEY(owner_id,record_id,tombstone_revision)
  REFERENCES pa_record_commit_markers(owner_id,record_id,revision) ON DELETE RESTRICT
) STRICT;
CREATE INDEX pa_record_physical_delete_queue_age
 ON pa_record_physical_delete_queue(next_attempt_at,requested_at,owner_id,record_id);

CREATE VIEW pa_record_physical_delete_candidates AS
 SELECT r.owner_id,r.record_id,r.revision AS tombstone_revision,d.created_at AS requested_at
 FROM pa_records r
 JOIN pa_record_commit_markers m ON m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision
 JOIN pa_record_delete_intents d ON d.owner_id=r.owner_id AND d.record_id=r.record_id AND d.target_revision=r.revision
 JOIN pa_record_recovery_versions v ON v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision
 WHERE r.deleted=1 AND r.metadata IS NULL AND r.photo_key IS NULL
  AND v.record_object_key=d.record_object_key AND v.photo_object_key IS NULL;

-- The normal delete writes the intent before the commit marker. Quarantined
-- recovery can restore those references in the reverse order.
CREATE TRIGGER pa_record_physical_delete_after_commit
AFTER INSERT ON pa_record_commit_markers
BEGIN
 INSERT OR IGNORE INTO pa_record_physical_delete_queue(owner_id,record_id,tombstone_revision,requested_at)
 SELECT owner_id,record_id,tombstone_revision,requested_at FROM pa_record_physical_delete_candidates
 WHERE owner_id=NEW.owner_id AND record_id=NEW.record_id AND tombstone_revision=NEW.revision;
END;
CREATE TRIGGER pa_record_physical_delete_after_intent
AFTER INSERT ON pa_record_delete_intents
BEGIN
 INSERT OR IGNORE INTO pa_record_physical_delete_queue(owner_id,record_id,tombstone_revision,requested_at)
 SELECT owner_id,record_id,tombstone_revision,requested_at FROM pa_record_physical_delete_candidates
 WHERE owner_id=NEW.owner_id AND record_id=NEW.record_id AND tombstone_revision=NEW.target_revision;
END;

-- Backfill only records already in the existing R2 deletion backlog. Other
-- historical tombstones need a separate scope audit before physical erasure.
INSERT OR IGNORE INTO pa_record_physical_delete_queue(owner_id,record_id,tombstone_revision,requested_at)
 SELECT c.owner_id,c.record_id,c.tombstone_revision,c.requested_at
 FROM pa_record_physical_delete_candidates c
 WHERE EXISTS(SELECT 1 FROM pa_pending_deletes p
   WHERE p.object_key >= 'personal/'||c.owner_id||'/'||c.record_id||'/'
     AND p.object_key < 'personal/'||c.owner_id||'/'||c.record_id||'0');
