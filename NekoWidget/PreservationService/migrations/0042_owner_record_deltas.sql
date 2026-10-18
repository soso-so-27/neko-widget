-- Derived acceleration state, never an independent recovery authority. Older
-- writers also maintain it through the record triggers. The first copy after
-- migration/restore still verifies a complete bounded inventory before seeding
-- a cursor. Tombstones remain in pa_records and in the immutable recovery tree.
CREATE TABLE pa_owner_record_counters (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES pa_owners(owner_id),
  sequence INTEGER NOT NULL CHECK(sequence>=0),
  record_count INTEGER NOT NULL CHECK(record_count>=0)
);
INSERT INTO pa_owner_record_counters(owner_id,sequence,record_count)
  SELECT o.owner_id,0,count(r.record_id) FROM pa_owners o
  LEFT JOIN pa_records r ON r.owner_id=o.owner_id GROUP BY o.owner_id;
CREATE TABLE pa_owner_record_changes (
  owner_id TEXT NOT NULL REFERENCES pa_owner_record_counters(owner_id),
  record_id TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK(sequence>=0),
  PRIMARY KEY(owner_id,record_id)
);
CREATE INDEX pa_owner_record_changes_since ON pa_owner_record_changes(owner_id,sequence);
INSERT INTO pa_owner_record_changes(owner_id,record_id,sequence)
  SELECT owner_id,record_id,0 FROM pa_records;
CREATE TABLE pa_owner_recovery_tree_cursors (
  owner_id TEXT PRIMARY KEY NOT NULL,
  generation INTEGER NOT NULL,
  inventory_generation INTEGER NOT NULL CHECK(inventory_generation>=0),
  record_sequence INTEGER NOT NULL CHECK(record_sequence>=0),
  record_count INTEGER NOT NULL CHECK(record_count>=0),
  FOREIGN KEY(owner_id,generation) REFERENCES pa_owner_recovery_versions(owner_id,generation)
);
CREATE TRIGGER pa_owner_record_counter_insert AFTER INSERT ON pa_owners BEGIN
  INSERT INTO pa_owner_record_counters(owner_id,sequence,record_count) VALUES(NEW.owner_id,0,0);
END;
CREATE TRIGGER pa_owner_record_identity_immutable BEFORE UPDATE OF owner_id,record_id ON pa_records
WHEN NEW.owner_id<>OLD.owner_id OR NEW.record_id<>OLD.record_id
BEGIN SELECT RAISE(ABORT,'OWNER_RECORD_IDENTITY_IMMUTABLE'); END;
CREATE TRIGGER pa_owner_record_change_insert AFTER INSERT ON pa_records BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_owner_record_counters WHERE owner_id=NEW.owner_id)
    THEN RAISE(ABORT,'OWNER_RECORD_COUNTER_MISSING') END;
  UPDATE pa_owner_record_counters SET sequence=sequence+1,record_count=record_count+1 WHERE owner_id=NEW.owner_id;
  INSERT INTO pa_owner_record_changes(owner_id,record_id,sequence)
    SELECT NEW.owner_id,NEW.record_id,sequence FROM pa_owner_record_counters WHERE owner_id=NEW.owner_id
    ON CONFLICT(owner_id,record_id) DO UPDATE SET sequence=excluded.sequence;
END;
CREATE TRIGGER pa_owner_record_change_update AFTER UPDATE ON pa_records BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_owner_record_counters WHERE owner_id=NEW.owner_id)
    THEN RAISE(ABORT,'OWNER_RECORD_COUNTER_MISSING') END;
  UPDATE pa_owner_record_counters SET sequence=sequence+1 WHERE owner_id=NEW.owner_id;
  INSERT INTO pa_owner_record_changes(owner_id,record_id,sequence)
    SELECT NEW.owner_id,NEW.record_id,sequence FROM pa_owner_record_counters WHERE owner_id=NEW.owner_id
    ON CONFLICT(owner_id,record_id) DO UPDATE SET sequence=excluded.sequence;
END;
-- Physical erasure already requires independent purge proof. Retain an entry
-- until the owner eraser removes the derived tables after pa_records.
CREATE TRIGGER pa_owner_record_change_delete AFTER DELETE ON pa_records BEGIN
  UPDATE pa_owner_record_counters SET sequence=sequence+1,record_count=record_count-1 WHERE owner_id=OLD.owner_id;
  INSERT INTO pa_owner_record_changes(owner_id,record_id,sequence)
    SELECT OLD.owner_id,OLD.record_id,sequence FROM pa_owner_record_counters WHERE owner_id=OLD.owner_id
    ON CONFLICT(owner_id,record_id) DO UPDATE SET sequence=excluded.sequence;
END;
-- A lost optimization cursor is safe (full verification will rebuild it).
-- Dropping a change entry/counter on an active owner could hide a pending write.
CREATE TRIGGER pa_owner_record_changes_delete_guard BEFORE DELETE ON pa_owner_record_changes
WHEN (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND EXISTS(SELECT 1 FROM pa_owners WHERE owner_id=OLD.owner_id AND purge_fence_id IS NULL)
BEGIN SELECT RAISE(ABORT,'OWNER_RECORD_CHANGE_PROTECTED'); END;
CREATE TRIGGER pa_owner_record_counters_delete_guard BEFORE DELETE ON pa_owner_record_counters
WHEN (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND EXISTS(SELECT 1 FROM pa_owners WHERE owner_id=OLD.owner_id AND purge_fence_id IS NULL)
BEGIN SELECT RAISE(ABORT,'OWNER_RECORD_COUNTER_PROTECTED'); END;
CREATE TRIGGER pa_owner_record_changes_invalidate_cursor AFTER DELETE ON pa_owner_record_changes BEGIN
  DELETE FROM pa_owner_recovery_tree_cursors WHERE owner_id=OLD.owner_id;
END;
CREATE TRIGGER pa_owner_record_counters_invalidate_cursor AFTER DELETE ON pa_owner_record_counters BEGIN
  DELETE FROM pa_owner_recovery_tree_cursors WHERE owner_id=OLD.owner_id;
END;
-- Legacy/offline repair may replace a marker with the policy disabled. Such a
-- change cannot reuse a previously authenticated complete-inventory cursor.
CREATE TRIGGER pa_owner_record_marker_update_cursor AFTER UPDATE ON pa_record_commit_markers BEGIN
  DELETE FROM pa_owner_recovery_tree_cursors WHERE owner_id=OLD.owner_id OR owner_id=NEW.owner_id;
  UPDATE pa_owner_record_counters SET sequence=sequence+1 WHERE owner_id=OLD.owner_id OR owner_id=NEW.owner_id;
  INSERT INTO pa_owner_record_changes(owner_id,record_id,sequence)
    SELECT OLD.owner_id,OLD.record_id,sequence FROM pa_owner_record_counters WHERE owner_id=OLD.owner_id
    ON CONFLICT(owner_id,record_id) DO UPDATE SET sequence=excluded.sequence;
  INSERT INTO pa_owner_record_changes(owner_id,record_id,sequence)
    SELECT NEW.owner_id,NEW.record_id,sequence FROM pa_owner_record_counters WHERE owner_id=NEW.owner_id
    ON CONFLICT(owner_id,record_id) DO UPDATE SET sequence=excluded.sequence;
END;
CREATE TRIGGER pa_owner_record_marker_delete_cursor AFTER DELETE ON pa_record_commit_markers BEGIN
  DELETE FROM pa_owner_recovery_tree_cursors WHERE owner_id=OLD.owner_id;
  UPDATE pa_owner_record_counters SET sequence=sequence+1 WHERE owner_id=OLD.owner_id;
  INSERT INTO pa_owner_record_changes(owner_id,record_id,sequence)
    SELECT OLD.owner_id,OLD.record_id,sequence FROM pa_owner_record_counters WHERE owner_id=OLD.owner_id
    ON CONFLICT(owner_id,record_id) DO UPDATE SET sequence=excluded.sequence;
END;
