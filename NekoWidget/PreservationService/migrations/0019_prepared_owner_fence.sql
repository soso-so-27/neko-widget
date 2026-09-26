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

-- A stale lease must never authorize erasure, but a verified S3 abort may be
-- recorded after expiry to recover an owner left disabled by a crash.
DROP TRIGGER pa_purge_execution_claim_requires_prepared;
CREATE TRIGGER pa_purge_execution_claim_requires_prepared
BEFORE INSERT ON pa_purge_execution_claims
WHEN NEW.state NOT IN ('aborting','erasing') OR NOT EXISTS(
  SELECT 1 FROM pa_purge_fences f JOIN pa_owners o ON o.owner_id=f.owner_id
    JOIN pa_inventory i ON i.owner_id=f.owner_id
    JOIN pa_owner_purge_events p ON p.owner_id=f.owner_id
      AND p.intent_id=f.fence_id AND p.stage='prepared'
  WHERE f.owner_id=NEW.owner_id AND f.fence_id=NEW.intent_id
    AND f.state='fenced' AND o.disabled=1 AND o.purge_fence_id=f.fence_id
    AND o.epoch=f.owner_epoch AND f.owner_epoch=NEW.owner_epoch
    AND i.generation=f.inventory_generation
    AND f.inventory_generation=NEW.inventory_generation
    AND f.retention_episode=NEW.retention_episode
    AND f.retention_revision=NEW.retention_revision
    AND f.due_at=NEW.due_at AND p.owner_epoch=NEW.owner_epoch
    AND p.inventory_generation=NEW.inventory_generation
    AND p.retention_episode=NEW.retention_episode
    AND p.retention_revision=NEW.retention_revision AND p.due_at=NEW.due_at
    AND NEW.claimed_at>=f.created_at
    AND (NEW.state='aborting' OR NEW.claimed_at<f.lease_expires_at))
BEGIN SELECT RAISE(ABORT,'PURGE_EXECUTION_PREPARATION_REQUIRED'); END;
