-- Transient export coordination, removed with the owner and omitted from
-- recovery snapshots. These columns do not advance recovery generations.
ALTER TABLE pa_owners ADD COLUMN export_lease_id TEXT
  CHECK(export_lease_id IS NULL OR (typeof(export_lease_id)='text' AND length(export_lease_id)=36));
ALTER TABLE pa_owners ADD COLUMN export_lease_expires_at INTEGER NOT NULL DEFAULT 0
  CHECK(typeof(export_lease_expires_at)='integer' AND export_lease_expires_at>=0)
  CHECK((export_lease_id IS NULL AND export_lease_expires_at=0)
    OR (export_lease_id IS NOT NULL AND export_lease_expires_at>0));
