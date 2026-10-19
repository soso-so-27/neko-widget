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
