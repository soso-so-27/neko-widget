-- Advisory scan position only. A row returned by the scan never grants
-- permission to delete records or storage copies.
CREATE TABLE pa_expiry_review_cursor (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  due_at INTEGER NOT NULL DEFAULT 0 CHECK (due_at >= 0),
  owner_id TEXT NOT NULL DEFAULT ''
);
INSERT INTO pa_expiry_review_cursor(id,due_at,owner_id) VALUES(1,0,'');

CREATE INDEX pa_retention_expiry_scan
  ON pa_retention(due_at,owner_id)
  WHERE verified_status='expired' AND paused_at IS NULL
    AND final_notice_delivered_at IS NOT NULL;
