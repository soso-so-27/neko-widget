-- Dedicated preservation DB only. This migration performs no fencing or deletion.
-- A non-null fence ID distinguishes an expiry purge fence from other revocations.
ALTER TABLE pa_owners ADD COLUMN purge_fence_id TEXT;
CREATE UNIQUE INDEX pa_owner_purge_fence_id ON pa_owners(purge_fence_id)
  WHERE purge_fence_id IS NOT NULL;

CREATE TABLE pa_purge_fences (
  fence_id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  state TEXT NOT NULL CHECK(state IN ('proposed', 'fenced', 'aborted')),
  owner_epoch INTEGER CHECK(owner_epoch IS NULL OR owner_epoch >= 0),
  inventory_generation INTEGER CHECK(inventory_generation IS NULL OR inventory_generation >= 0),
  retention_episode INTEGER NOT NULL CHECK(retention_episode > 0),
  retention_revision INTEGER NOT NULL CHECK(retention_revision > 0),
  due_at INTEGER NOT NULL CHECK(due_at > 0),
  delivered_at INTEGER NOT NULL CHECK(delivered_at > 0),
  delivery_event_id TEXT NOT NULL,
  contact_updated_at INTEGER NOT NULL CHECK(contact_updated_at >= 0),
  created_at INTEGER NOT NULL CHECK(created_at > 0),
  updated_at INTEGER NOT NULL CHECK(updated_at >= created_at),
  lease_expires_at INTEGER NOT NULL CHECK(lease_expires_at > created_at),
  CHECK((state='proposed' AND owner_epoch IS NULL AND inventory_generation IS NULL)
    OR (state IN ('fenced', 'aborted') AND owner_epoch IS NOT NULL AND inventory_generation IS NOT NULL))
);
CREATE UNIQUE INDEX pa_one_active_purge_fence ON pa_purge_fences(owner_id)
  WHERE state='fenced';
CREATE INDEX pa_purge_fences_recovery ON pa_purge_fences(state, lease_expires_at);
