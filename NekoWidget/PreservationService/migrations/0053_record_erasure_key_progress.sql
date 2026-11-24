-- Advance only after re-listing an authorized exact key and finding it empty.
ALTER TABLE pa_record_physical_delete_queue ADD COLUMN erased_through_key TEXT NOT NULL DEFAULT '';

-- A photo may be reused by metadata edits. The eraser rejects any reference
-- to a candidate key from another record before deleting any of its versions.
CREATE INDEX pa_record_recovery_photo_object ON pa_record_recovery_versions(photo_object_key)
  WHERE photo_object_key IS NOT NULL;
