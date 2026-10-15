-- A mutable, encrypted automatic-save head protects its immutable completed
-- snapshot using the same owner-local reference graph as tool pieces.
ALTER TABLE pa_tool_snapshot_references ADD COLUMN source_revision INTEGER NOT NULL DEFAULT 1 CHECK(source_revision>=1);
DROP TRIGGER pa_tool_reference_requires_live_parts;
CREATE TRIGGER pa_tool_reference_requires_live_parts BEFORE INSERT ON pa_tool_snapshot_references
WHEN NOT EXISTS(SELECT 1 FROM pa_records WHERE owner_id=NEW.owner_id AND record_id=NEW.snapshot_id AND deleted=0 AND revision=NEW.source_revision)
  OR NOT EXISTS(SELECT 1 FROM pa_records WHERE owner_id=NEW.owner_id AND record_id=NEW.part_id AND deleted=0 AND revision=1)
  OR EXISTS(SELECT 1 FROM pa_tool_part_delete_claims WHERE owner_id=NEW.owner_id AND part_id=NEW.part_id)
BEGIN SELECT RAISE(ABORT,'TOOL_PART_UNAVAILABLE'); END;
