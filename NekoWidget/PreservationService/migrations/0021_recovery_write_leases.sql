-- A recovery version can be written before its D1 record CAS. The fence must
-- not pass while any such S3 write is in flight. A crashed lease is retained
-- for manual reconciliation; expiry alone never authorizes deletion.
CREATE TABLE pa_recovery_write_leases (
  write_id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  started_at INTEGER NOT NULL CHECK(started_at > 0)
);
CREATE INDEX pa_recovery_write_leases_owner ON pa_recovery_write_leases(owner_id);
CREATE TRIGGER pa_recovery_write_lease_requires_active_owner
BEFORE INSERT ON pa_recovery_write_leases
WHEN NOT EXISTS(SELECT 1 FROM pa_owners o WHERE o.owner_id=NEW.owner_id
  AND o.disabled=0 AND o.purge_fence_id IS NULL)
BEGIN SELECT RAISE(ABORT,'RECOVERY_WRITE_OWNER_FENCED'); END;
CREATE TRIGGER pa_recovery_write_lease_immutable
BEFORE UPDATE ON pa_recovery_write_leases
BEGIN SELECT RAISE(ABORT,'RECOVERY_WRITE_LEASE_IMMUTABLE'); END;
CREATE TRIGGER pa_recovery_write_lease_blocks_fence
BEFORE UPDATE OF disabled,purge_fence_id ON pa_owners
WHEN OLD.purge_fence_id IS NULL AND NEW.purge_fence_id IS NOT NULL
  AND EXISTS(SELECT 1 FROM pa_recovery_write_leases w
    WHERE w.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'RECOVERY_WRITE_IN_FLIGHT'); END;
