-- Bounded receipt discovery on any active device of the same person.
-- Only the index is new. Receipt ownership and retention remain unchanged.
CREATE INDEX group_report_replies_by_person
 ON group_report_records(reporter_person_id, committed_at DESC, report_id DESC)
 WHERE committed_at IS NOT NULL;
