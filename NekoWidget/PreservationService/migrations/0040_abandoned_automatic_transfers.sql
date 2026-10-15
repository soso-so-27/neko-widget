-- An explicit owner cancellation fences late parts without deleting history.
CREATE TABLE pa_tool_record_sources (
  owner_id TEXT NOT NULL,
  record_id TEXT NOT NULL,
  snapshot_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('json','photo','index')),
  PRIMARY KEY(owner_id,record_id),
  FOREIGN KEY(owner_id,record_id) REFERENCES pa_records(owner_id,record_id) ON DELETE RESTRICT
);
CREATE INDEX pa_tool_sources_by_snapshot ON pa_tool_record_sources(owner_id,snapshot_id);
CREATE TABLE pa_tool_snapshot_abandonments (
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  snapshot_id TEXT NOT NULL,
  abandoned_at INTEGER NOT NULL CHECK(abandoned_at>0),
  PRIMARY KEY(owner_id,snapshot_id)
);
CREATE TRIGGER pa_tool_abandon_generation AFTER INSERT ON pa_tool_snapshot_abandonments
BEGIN
  UPDATE pa_inventory SET generation=generation+1 WHERE owner_id=NEW.owner_id;
  UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=NEW.owner_id;
END;
-- Deleting an index preserves the last-reference GC intent on the server.
-- A normal head replacement does not run this trigger's body.
CREATE TRIGGER pa_tool_last_reference_retirement AFTER DELETE ON pa_tool_snapshot_references
WHEN EXISTS(SELECT 1 FROM pa_records WHERE owner_id=OLD.owner_id AND record_id=OLD.snapshot_id AND deleted=1)
 AND NOT EXISTS(SELECT 1 FROM pa_tool_snapshot_references WHERE owner_id=OLD.owner_id AND part_id=OLD.part_id)
BEGIN
  INSERT OR IGNORE INTO pa_tool_part_delete_claims(owner_id,part_id)
    SELECT owner_id,record_id FROM pa_records WHERE owner_id=OLD.owner_id AND record_id=OLD.part_id AND deleted=0 AND revision=1;
END;
