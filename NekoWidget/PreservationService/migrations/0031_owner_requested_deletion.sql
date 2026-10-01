-- Explicit owner-request deletion is independent of subscription expiry.
-- Request rows are a local working index. External R2 receipts are authoritative.
-- No data is removed or feature enabled by this migration.
CREATE TABLE pa_owner_deletion_requests (
  owner_id TEXT PRIMARY KEY,
  request_id TEXT NOT NULL UNIQUE,
  receipt_hash TEXT NOT NULL CHECK(length(receipt_hash)=64),
  owner_epoch INTEGER NOT NULL CHECK(owner_epoch>0),
  requested_at INTEGER NOT NULL CHECK(requested_at>0),
  request_sha256 TEXT NOT NULL CHECK(length(request_sha256)=64),
  state TEXT NOT NULL CHECK(state IN ('requested','fenced','erasing')),
  apple_revoked INTEGER NOT NULL DEFAULT 0 CHECK(apple_revoked IN (0,1)),
  manifest_sha256 TEXT,
  cloud_empty INTEGER NOT NULL DEFAULT 0 CHECK(cloud_empty IN (0,1)),
  CHECK(state<>'erasing' OR (apple_revoked=1 AND length(manifest_sha256)=64)),
  CHECK(cloud_empty=0 OR state='erasing')
);
CREATE VIEW pa_owner_requested_erasing_authority AS
SELECT d.owner_id,d.request_id FROM pa_owner_deletion_requests d
JOIN pa_owners o ON o.owner_id=d.owner_id AND o.epoch=d.owner_epoch
  AND o.disabled=1 AND o.purge_fence_id=d.request_id
WHERE d.state='erasing' AND d.apple_revoked=1 AND d.cloud_empty=1
  AND length(d.manifest_sha256)=64;
CREATE TRIGGER pa_owner_deletion_request_immutable
BEFORE UPDATE OF owner_id,request_id,receipt_hash,owner_epoch,requested_at,request_sha256
ON pa_owner_deletion_requests
BEGIN SELECT RAISE(ABORT,'OWNER_DELETION_REQUEST_IMMUTABLE'); END;
CREATE TRIGGER pa_owner_deletion_fence_not_released BEFORE UPDATE ON pa_owners
WHEN EXISTS(SELECT 1 FROM pa_owner_deletion_requests d
  WHERE d.owner_id=OLD.owner_id AND d.state IN ('fenced','erasing'))
  AND (NEW.disabled<>1 OR NEW.epoch<>OLD.epoch OR NEW.purge_fence_id IS NOT OLD.purge_fence_id)
BEGIN SELECT RAISE(ABORT,'OWNER_DELETION_FENCED'); END;

-- A current owner snapshot and an externally read-back prepared intent are
-- required before the snapshot policy permits an expiry fence. D1 references
-- alone are not proof of S3 durability: the caller must replay S3 as well.
-- Re-enabling a fenced owner remains blocked until a separate release path
-- verifies the external aborted event and all primary data.
DROP TRIGGER pa_owner_recovery_blocks_unbacked_fence;
CREATE TRIGGER pa_owner_recovery_blocks_unbacked_fence
BEFORE UPDATE OF disabled,purge_fence_id ON pa_owners
WHEN (NEW.disabled<>OLD.disabled OR NEW.purge_fence_id IS NOT OLD.purge_fence_id)
  AND (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests d
    WHERE d.owner_id=OLD.owner_id AND d.state='requested'
      AND d.owner_epoch=NEW.epoch AND NEW.epoch=OLD.epoch+1
      AND OLD.disabled=0 AND NEW.disabled=1 AND OLD.purge_fence_id IS NULL
      AND NEW.purge_fence_id=d.request_id)
  AND NOT ((
    OLD.disabled=0 AND NEW.disabled=1 AND OLD.purge_fence_id IS NULL
    AND NEW.purge_fence_id IS NOT NULL AND NEW.epoch=OLD.epoch+1
    AND EXISTS(
      SELECT 1 FROM pa_purge_fences f
      JOIN pa_owner_purge_events e ON e.owner_id=f.owner_id
        AND e.intent_id=f.fence_id AND e.stage='prepared'
      JOIN pa_inventory i ON i.owner_id=f.owner_id
      JOIN pa_owner_recovery_generations g ON g.owner_id=f.owner_id
      JOIN pa_owner_recovery_versions v ON v.owner_id=g.owner_id
        AND v.generation=g.generation
      WHERE f.owner_id=OLD.owner_id AND f.fence_id=NEW.purge_fence_id
        AND f.state='proposed' AND f.owner_epoch IS NULL
        AND i.generation=e.inventory_generation
        AND e.owner_epoch=NEW.epoch
        AND e.retention_episode=f.retention_episode
        AND e.retention_revision=f.retention_revision AND e.due_at=f.due_at
        AND e.recorded_at<=f.lease_expires_at
        AND NOT EXISTS(SELECT 1 FROM pa_owner_purge_events later
          WHERE later.owner_id=f.owner_id AND later.intent_id=f.fence_id
            AND later.stage<>'prepared')
    )
  ) OR (
    OLD.disabled=1 AND NEW.disabled=0 AND OLD.purge_fence_id IS NOT NULL
    AND NEW.purge_fence_id IS NULL AND NEW.epoch=OLD.epoch+1
    AND EXISTS(
      SELECT 1 FROM pa_purge_fences f
      JOIN pa_purge_execution_claims c ON c.owner_id=f.owner_id
        AND c.intent_id=f.fence_id AND c.state='aborted'
      JOIN pa_owner_purge_events e ON e.owner_id=f.owner_id
        AND e.intent_id=f.fence_id AND e.stage='aborted'
      JOIN pa_retention r ON r.owner_id=f.owner_id
      JOIN pa_identity_credentials ic ON ic.owner_id=f.owner_id
      WHERE f.owner_id=OLD.owner_id AND f.fence_id=OLD.purge_fence_id
        AND f.state='fenced' AND f.owner_epoch=OLD.epoch
        AND r.episode=f.retention_episode AND r.revision=f.retention_revision+1
        AND r.final_notice_delivered_at IS NULL
        AND r.final_notice_receipt IS NULL
        AND ic.owner_epoch=NEW.epoch
        AND c.owner_epoch=f.owner_epoch
        AND c.inventory_generation=f.inventory_generation
        AND c.retention_episode=f.retention_episode
        AND c.retention_revision=f.retention_revision AND c.due_at=f.due_at
        AND e.owner_epoch=c.owner_epoch
        AND e.inventory_generation=c.inventory_generation
        AND e.retention_episode=c.retention_episode
        AND e.retention_revision=c.retention_revision AND e.due_at=c.due_at
        AND NOT EXISTS(SELECT 1 FROM pa_owner_purge_events later
          WHERE later.owner_id=f.owner_id AND later.intent_id=f.fence_id
            AND later.stage IN ('erasing','completed'))
    )
  ))
BEGIN SELECT RAISE(ABORT,'OWNER_RECOVERY_FENCE_INTENT_REQUIRED'); END;


DROP TRIGGER pa_membership_links_no_delete;
CREATE TRIGGER pa_membership_links_no_delete BEFORE DELETE ON pa_membership_links
WHEN NOT EXISTS(SELECT 1 FROM pa_owner_requested_erasing_authority a WHERE a.owner_id=OLD.owner_id)
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority a
  WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'membership link is retained'); END;

DROP TRIGGER pa_owner_recovery_commit_marker_immutable_delete;
CREATE TRIGGER pa_owner_recovery_commit_marker_immutable_delete
BEFORE DELETE ON pa_record_commit_markers
WHEN (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND NOT EXISTS(SELECT 1 FROM pa_owner_requested_erasing_authority a WHERE a.owner_id=OLD.owner_id)
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority a
    WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'OWNER_RECOVERY_MARKER_IMMUTABLE'); END;

DROP TRIGGER pa_owner_recovery_record_physical_delete_requires_ledger;
CREATE TRIGGER pa_owner_recovery_record_physical_delete_requires_ledger
BEFORE DELETE ON pa_records
WHEN (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND NOT EXISTS(SELECT 1 FROM pa_owner_requested_erasing_authority a WHERE a.owner_id=OLD.owner_id)
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority a
    WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'OWNER_RECOVERY_DELETION_LEDGER_REQUIRED'); END;

-- The last two parent rows cannot be removed under snapshot policy without
-- the same external erasing evidence. FK constraints still require all child
-- rows to be removed first; the controller must verify both cloud prefixes
-- empty before entering this D1 phase.
DROP TRIGGER pa_purge_fence_delete_requires_erasing;
CREATE TRIGGER pa_purge_fence_delete_requires_erasing
BEFORE DELETE ON pa_purge_fences
WHEN (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND NOT EXISTS(SELECT 1 FROM pa_owner_requested_erasing_authority a WHERE a.owner_id=OLD.owner_id)
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority a
    WHERE a.owner_id=OLD.owner_id AND a.intent_id=OLD.fence_id)
BEGIN SELECT RAISE(ABORT,'PURGE_D1_ERASING_REQUIRED'); END;
DROP TRIGGER pa_owner_delete_requires_erasing;
CREATE TRIGGER pa_owner_delete_requires_erasing
BEFORE DELETE ON pa_owners
WHEN (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND NOT EXISTS(SELECT 1 FROM pa_owner_requested_erasing_authority a WHERE a.owner_id=OLD.owner_id)
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority a
    WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'PURGE_D1_ERASING_REQUIRED'); END;
