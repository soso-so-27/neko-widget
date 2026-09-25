-- Separate, fail-closed claim between a pre-deletion fence and any external
-- abort/erasure event. This migration grants no ability to fence or delete.
-- A claim may outlive pa_owners after a completed physical purge; 35-day
-- cleanup is deliberately not enabled until old D1 restore points are barred.
CREATE TABLE pa_purge_execution_claims (
  owner_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('aborting','aborted','erasing','completed')),
  owner_epoch INTEGER NOT NULL CHECK(owner_epoch > 0),
  inventory_generation INTEGER NOT NULL CHECK(inventory_generation >= 0),
  retention_episode INTEGER NOT NULL CHECK(retention_episode > 0),
  retention_revision INTEGER NOT NULL CHECK(retention_revision > 0),
  due_at INTEGER NOT NULL CHECK(due_at > 0),
  manifest_sha256 TEXT CHECK(manifest_sha256 IS NULL OR length(manifest_sha256)=64),
  claimed_at INTEGER NOT NULL CHECK(claimed_at >= due_at),
  finished_at INTEGER,
  PRIMARY KEY(owner_id,intent_id),
  CHECK((state IN ('aborting','aborted') AND manifest_sha256 IS NULL)
    OR (state IN ('erasing','completed') AND manifest_sha256 IS NOT NULL)),
  CHECK((state IN ('aborting','erasing') AND finished_at IS NULL)
    OR (state IN ('aborted','completed') AND finished_at >= claimed_at))
);
CREATE UNIQUE INDEX pa_one_active_purge_execution_claim
  ON pa_purge_execution_claims(owner_id)
  WHERE state IN ('aborting','erasing');

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
    AND NEW.claimed_at>=f.created_at)
BEGIN SELECT RAISE(ABORT,'PURGE_EXECUTION_PREPARATION_REQUIRED'); END;

CREATE TRIGGER pa_purge_execution_claim_transition_guard
BEFORE UPDATE ON pa_purge_execution_claims
WHEN NEW.owner_id<>OLD.owner_id OR NEW.intent_id<>OLD.intent_id
  OR NEW.owner_epoch<>OLD.owner_epoch
  OR NEW.inventory_generation<>OLD.inventory_generation
  OR NEW.retention_episode<>OLD.retention_episode
  OR NEW.retention_revision<>OLD.retention_revision OR NEW.due_at<>OLD.due_at
  OR NEW.manifest_sha256 IS NOT OLD.manifest_sha256
  OR NEW.claimed_at<>OLD.claimed_at
  OR NOT ((OLD.state='aborting' AND NEW.state='aborted')
    OR (OLD.state='erasing' AND NEW.state='completed'))
BEGIN SELECT RAISE(ABORT,'PURGE_EXECUTION_INVALID_TRANSITION'); END;

CREATE TRIGGER pa_purge_execution_claim_terminal_event_required
BEFORE UPDATE ON pa_purge_execution_claims
WHEN NOT EXISTS(
  SELECT 1 FROM pa_owner_purge_events e
  WHERE e.owner_id=NEW.owner_id AND e.intent_id=NEW.intent_id
    AND e.stage=NEW.state AND e.owner_epoch=NEW.owner_epoch
    AND e.inventory_generation=NEW.inventory_generation
    AND e.retention_episode=NEW.retention_episode
    AND e.retention_revision=NEW.retention_revision AND e.due_at=NEW.due_at
    AND e.manifest_sha256 IS NEW.manifest_sha256
    AND NEW.finished_at>=e.recorded_at)
BEGIN SELECT RAISE(ABORT,'PURGE_EXECUTION_EXTERNAL_EVENT_REQUIRED'); END;

CREATE TRIGGER pa_purge_execution_claim_no_delete
BEFORE DELETE ON pa_purge_execution_claims
BEGIN SELECT RAISE(ABORT,'PURGE_EXECUTION_CLEANUP_NOT_CONFIGURED'); END;
