-- A completed, independently mirrored S3 plan and erasing claim are the
-- minimum DB-local authority for physical owner-row removal. No DELETE is
-- executed by this migration; the public Worker still has no purge route.
CREATE VIEW pa_purge_d1_erasing_authority AS
SELECT c.owner_id,c.intent_id FROM pa_purge_execution_claims c
JOIN pa_owners o ON o.owner_id=c.owner_id AND o.disabled=1
  AND o.purge_fence_id=c.intent_id AND o.epoch=c.owner_epoch
JOIN pa_owner_purge_events e ON e.owner_id=c.owner_id
  AND e.intent_id=c.intent_id AND e.stage='erasing'
  AND e.manifest_sha256=c.manifest_sha256
  AND e.owner_epoch=c.owner_epoch
  AND e.inventory_generation=c.inventory_generation
  AND e.retention_episode=c.retention_episode
  AND e.retention_revision=c.retention_revision AND e.due_at=c.due_at
JOIN pa_purge_manifests m ON m.owner_id=c.owner_id
  AND m.intent_id=c.intent_id AND m.sha256=c.manifest_sha256
  AND m.sealed_at IS NOT NULL
JOIN pa_purge_manifest_remote_seals s ON s.owner_id=m.owner_id
  AND s.intent_id=m.intent_id AND s.root_sha256=m.sha256
WHERE c.state='erasing';

DROP TRIGGER pa_membership_links_no_delete;
CREATE TRIGGER pa_membership_links_no_delete BEFORE DELETE ON pa_membership_links
WHEN NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority a
  WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'membership link is retained'); END;

DROP TRIGGER pa_owner_recovery_commit_marker_immutable_delete;
CREATE TRIGGER pa_owner_recovery_commit_marker_immutable_delete
BEFORE DELETE ON pa_record_commit_markers
WHEN (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority a
    WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'OWNER_RECOVERY_MARKER_IMMUTABLE'); END;

DROP TRIGGER pa_owner_recovery_record_physical_delete_requires_ledger;
CREATE TRIGGER pa_owner_recovery_record_physical_delete_requires_ledger
BEFORE DELETE ON pa_records
WHEN (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority a
    WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'OWNER_RECOVERY_DELETION_LEDGER_REQUIRED'); END;

-- The last two parent rows cannot be removed under snapshot policy without
-- the same external erasing evidence. FK constraints still require all child
-- rows to be removed first; the controller must verify both cloud prefixes
-- empty before entering this D1 phase.
CREATE TRIGGER pa_purge_fence_delete_requires_erasing
BEFORE DELETE ON pa_purge_fences
WHEN (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority a
    WHERE a.owner_id=OLD.owner_id AND a.intent_id=OLD.fence_id)
BEGIN SELECT RAISE(ABORT,'PURGE_D1_ERASING_REQUIRED'); END;
CREATE TRIGGER pa_owner_delete_requires_erasing
BEFORE DELETE ON pa_owners
WHEN (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority a
    WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'PURGE_D1_ERASING_REQUIRED'); END;
