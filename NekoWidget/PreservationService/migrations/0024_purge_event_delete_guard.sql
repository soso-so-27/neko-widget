-- A completed S3 event is the temporary anti-resurrection tombstone after
-- D1 Time Travel. No ordinary D1 writer may remove its local reference until
-- a separately reviewed, age-gated cleanup verifies the external history.
-- This migration performs no deletion and enables no public purge route.
CREATE TRIGGER pa_owner_purge_events_no_delete
BEFORE DELETE ON pa_owner_purge_events
BEGIN SELECT RAISE(ABORT,'PURGE_EVENT_CLEANUP_NOT_CONFIGURED'); END;
