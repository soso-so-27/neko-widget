-- Keep owner-local accounting and admission checks independent of other owners'
-- pending uploads. Additive only: no retention, quota or record data changes.
CREATE INDEX pa_upload_owner_bytes ON pa_uploads(owner_id, reserved_bytes);
