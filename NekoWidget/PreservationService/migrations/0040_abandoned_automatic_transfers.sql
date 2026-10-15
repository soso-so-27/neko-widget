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
    SELECT p.owner_id,p.record_id FROM pa_records p
    JOIN pa_tool_record_sources s ON s.owner_id=p.owner_id AND s.record_id=p.record_id
    WHERE p.owner_id=OLD.owner_id AND p.record_id=OLD.part_id AND p.deleted=0 AND p.revision=1
      AND s.kind IN ('json','photo')
      AND NOT EXISTS(SELECT 1 FROM pa_records origin
        WHERE origin.owner_id=s.owner_id AND origin.record_id=s.snapshot_id AND origin.deleted=0);
END;
-- Legacy v1 indexes have no incoming-reference edges. Their original pieces
-- become eligible only when that source index itself has been retired.
CREATE TRIGGER pa_tool_source_index_retirement AFTER UPDATE OF deleted ON pa_records
WHEN OLD.deleted=0 AND NEW.deleted=1
 AND EXISTS(SELECT 1 FROM pa_tool_record_sources WHERE owner_id=NEW.owner_id AND record_id=NEW.record_id AND kind='index')
BEGIN
  INSERT OR IGNORE INTO pa_tool_part_delete_claims(owner_id,part_id)
    SELECT p.owner_id,p.record_id FROM pa_tool_record_sources s
    JOIN pa_records p ON p.owner_id=s.owner_id AND p.record_id=s.record_id
    WHERE s.owner_id=NEW.owner_id AND s.snapshot_id=NEW.record_id AND s.kind IN ('json','photo')
      AND p.deleted=0 AND p.revision=1
      AND NOT EXISTS(SELECT 1 FROM pa_tool_snapshot_references r WHERE r.owner_id=p.owner_id AND r.part_id=p.record_id);
END;
