-- V4 nodes have their own immutable snapshot IDs but belong to one upload
-- root. Legacy pieces retain their original snapshot attribution unchanged.
ALTER TABLE pa_tool_record_sources ADD COLUMN upload_snapshot_id TEXT;
CREATE INDEX pa_tool_sources_by_upload_snapshot ON pa_tool_record_sources(owner_id,upload_snapshot_id);
