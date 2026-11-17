-- Locate the existing reporter descriptors without adding any reporter retention.
CREATE INDEX family_photo_report_replies_by_reporter
ON family_photo_reports(reporter_person_id, committed_at DESC, report_id DESC)
WHERE committed_at IS NOT NULL;
