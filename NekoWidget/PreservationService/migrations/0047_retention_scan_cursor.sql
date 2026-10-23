-- Reconstructible scheduling position only. Never evidence of billing,
-- delivery, recovery acknowledgement, or permission to delete an owner.
-- No existing retention row, recovery generation or history is changed.
CREATE TABLE pa_retention_scan_cursor (
  singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton=1),
  revision INTEGER NOT NULL DEFAULT 0 CHECK(typeof(revision)='integer' AND revision>=0),
  last_owner_id TEXT NOT NULL DEFAULT '',
  retry_pending INTEGER NOT NULL DEFAULT 0
    CHECK(typeof(retry_pending)='integer' AND retry_pending IN (0,1))
);
INSERT INTO pa_retention_scan_cursor(singleton,revision,last_owner_id) VALUES(1,0,'');

-- An older eraser does not know this cursor. It must not remove the owner
-- and report completion while the new scheduling position still identifies
-- that owner. Current erasers clear the cursor before deleting the owner.
CREATE TRIGGER pa_retention_scan_cursor_owner_delete_guard
BEFORE DELETE ON pa_owners
WHEN EXISTS(SELECT 1 FROM pa_retention_scan_cursor WHERE last_owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'RETENTION_SCAN_CURSOR_NOT_CLEARED'); END;
