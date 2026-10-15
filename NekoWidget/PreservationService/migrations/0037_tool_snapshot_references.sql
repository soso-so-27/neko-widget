-- References protect shared, immutable tool pieces. No photo or history is
-- rewritten. Old clients can still delete unshared v1 pieces.
CREATE TABLE pa_tool_snapshot_references (
  owner_id TEXT NOT NULL,
  snapshot_id TEXT NOT NULL,
  part_id TEXT NOT NULL,
  PRIMARY KEY(owner_id,snapshot_id,part_id),
  FOREIGN KEY(owner_id,snapshot_id) REFERENCES pa_records(owner_id,record_id) ON DELETE RESTRICT,
  FOREIGN KEY(owner_id,part_id) REFERENCES pa_records(owner_id,record_id) ON DELETE RESTRICT,
  CHECK(snapshot_id<>part_id)
);
CREATE INDEX pa_tool_snapshot_part_references ON pa_tool_snapshot_references(owner_id,part_id);
CREATE TABLE pa_tool_part_delete_claims (
  owner_id TEXT NOT NULL,
  part_id TEXT NOT NULL,
  PRIMARY KEY(owner_id,part_id),
  FOREIGN KEY(owner_id,part_id) REFERENCES pa_records(owner_id,record_id) ON DELETE RESTRICT
);
CREATE TRIGGER pa_tool_delete_claim_generation AFTER INSERT ON pa_tool_part_delete_claims
BEGIN
  UPDATE pa_inventory SET generation=generation+1 WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_tool_reference_requires_live_parts BEFORE INSERT ON pa_tool_snapshot_references
WHEN NOT EXISTS(SELECT 1 FROM pa_records WHERE owner_id=NEW.owner_id AND record_id=NEW.snapshot_id AND deleted=0 AND revision=1)
  OR NOT EXISTS(SELECT 1 FROM pa_records WHERE owner_id=NEW.owner_id AND record_id=NEW.part_id AND deleted=0 AND revision=1)
  OR EXISTS(SELECT 1 FROM pa_tool_part_delete_claims WHERE owner_id=NEW.owner_id AND part_id=NEW.part_id)
BEGIN SELECT RAISE(ABORT,'TOOL_PART_UNAVAILABLE'); END;
CREATE TRIGGER pa_tool_shared_part_not_deleted BEFORE UPDATE OF deleted ON pa_records
WHEN NEW.deleted=1 AND EXISTS(SELECT 1 FROM pa_tool_snapshot_references WHERE owner_id=OLD.owner_id AND part_id=OLD.record_id)
BEGIN SELECT RAISE(ABORT,'TOOL_PART_REFERENCED'); END;
CREATE TRIGGER pa_tool_deleted_index_releases_references AFTER UPDATE OF deleted ON pa_records
WHEN NEW.deleted=1
BEGIN
  DELETE FROM pa_tool_snapshot_references WHERE owner_id=OLD.owner_id AND snapshot_id=OLD.record_id;
END;
