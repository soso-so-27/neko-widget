-- The original claim guard was already applied to the empty staging D1.
-- Replace it without editing migration 0017: a stale fence must never claim
-- an old expiry episode/notice after its short lease.
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
    AND NEW.claimed_at>=f.created_at AND NEW.claimed_at<f.lease_expires_at)
BEGIN SELECT RAISE(ABORT,'PURGE_EXECUTION_PREPARATION_REQUIRED'); END;
