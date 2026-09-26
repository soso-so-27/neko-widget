-- An owner-scoped, bounded physical deletion plan. A 100k-version owner
-- cannot be represented by one D1 row (2 MiB row/string limit). Each chunk
-- contains at most 128 identifiers and at most 512 KiB of canonical JSON.
-- This schema does not enable an executor, erasure or automatic cleanup.
CREATE TABLE pa_purge_manifests (
  owner_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  owner_epoch INTEGER NOT NULL CHECK(owner_epoch > 0),
  inventory_generation INTEGER NOT NULL CHECK(inventory_generation >= 0),
  record_digest TEXT NOT NULL CHECK(length(record_digest)=64),
  records INTEGER NOT NULL CHECK(records >= 0 AND records <= 100000),
  r2_count INTEGER NOT NULL CHECK(r2_count >= 0 AND r2_count <= 100000),
  s3_count INTEGER NOT NULL CHECK(s3_count >= 0 AND s3_count <= 100000),
  r2_bytes INTEGER NOT NULL CHECK(r2_bytes >= 0),
  s3_bytes INTEGER NOT NULL CHECK(s3_bytes >= 0),
  chunk_count INTEGER NOT NULL CHECK(chunk_count >= 0 AND chunk_count <= 1564),
  sha256 TEXT NOT NULL CHECK(length(sha256)=64),
  created_at INTEGER NOT NULL CHECK(created_at > 0),
  sealed_at INTEGER CHECK(sealed_at IS NULL OR sealed_at >= created_at),
  PRIMARY KEY(owner_id,intent_id)
);

CREATE TABLE pa_purge_manifest_chunks (
  owner_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK(ordinal >= 0 AND ordinal < 1564),
  kind TEXT NOT NULL CHECK(kind IN ('r2','s3')),
  item_count INTEGER NOT NULL CHECK(item_count >= 1 AND item_count <= 128),
  sha256 TEXT NOT NULL CHECK(length(sha256)=64),
  bytes INTEGER NOT NULL CHECK(bytes > 0 AND bytes <= 524288),
  payload TEXT NOT NULL CHECK(length(payload) = bytes),
  PRIMARY KEY(owner_id,intent_id,ordinal),
  FOREIGN KEY(owner_id,intent_id) REFERENCES pa_purge_manifests(owner_id,intent_id)
);

CREATE TRIGGER pa_purge_manifest_requires_fence
BEFORE INSERT ON pa_purge_manifests
WHEN NOT EXISTS(
  SELECT 1 FROM pa_purge_fences f JOIN pa_owners o ON o.owner_id=f.owner_id
  JOIN pa_inventory i ON i.owner_id=f.owner_id
  WHERE f.owner_id=NEW.owner_id AND f.fence_id=NEW.intent_id
    AND f.state='fenced' AND o.disabled=1 AND o.purge_fence_id=f.fence_id
    AND o.epoch=f.owner_epoch AND f.owner_epoch=NEW.owner_epoch
    AND i.generation=f.inventory_generation
    AND f.inventory_generation=NEW.inventory_generation
    AND NEW.created_at<f.lease_expires_at
    AND NOT EXISTS(SELECT 1 FROM pa_purge_execution_claims c
      WHERE c.owner_id=NEW.owner_id AND c.intent_id=NEW.intent_id))
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_FENCE_REQUIRED'); END;

CREATE TRIGGER pa_purge_manifest_chunk_guard
BEFORE INSERT ON pa_purge_manifest_chunks
WHEN NOT EXISTS(
  SELECT 1 FROM pa_purge_manifests m
  WHERE m.owner_id=NEW.owner_id AND m.intent_id=NEW.intent_id
    AND m.sealed_at IS NULL AND NEW.ordinal<m.chunk_count)
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_CHUNK_NOT_OPEN'); END;

CREATE TRIGGER pa_purge_manifest_seal_guard
BEFORE UPDATE OF sealed_at ON pa_purge_manifests
WHEN OLD.sealed_at IS NOT NULL OR NEW.sealed_at IS NULL
  OR NEW.sealed_at<OLD.created_at OR
  (SELECT COUNT(*) FROM pa_purge_manifest_chunks c
    WHERE c.owner_id=OLD.owner_id AND c.intent_id=OLD.intent_id)<>OLD.chunk_count
  OR (SELECT COALESCE(SUM(item_count),0) FROM pa_purge_manifest_chunks c
    WHERE c.owner_id=OLD.owner_id AND c.intent_id=OLD.intent_id AND c.kind='r2')<>OLD.r2_count
  OR (SELECT COALESCE(SUM(item_count),0) FROM pa_purge_manifest_chunks c
    WHERE c.owner_id=OLD.owner_id AND c.intent_id=OLD.intent_id AND c.kind='s3')<>OLD.s3_count
  OR (OLD.chunk_count>0 AND (
    (SELECT MIN(ordinal) FROM pa_purge_manifest_chunks c
      WHERE c.owner_id=OLD.owner_id AND c.intent_id=OLD.intent_id)<>0 OR
    (SELECT MAX(ordinal) FROM pa_purge_manifest_chunks c
      WHERE c.owner_id=OLD.owner_id AND c.intent_id=OLD.intent_id)<>OLD.chunk_count-1))
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_INCOMPLETE'); END;

CREATE TRIGGER pa_purge_manifest_header_immutable
BEFORE UPDATE ON pa_purge_manifests
WHEN NEW.owner_id<>OLD.owner_id OR NEW.intent_id<>OLD.intent_id
  OR NEW.owner_epoch<>OLD.owner_epoch
  OR NEW.inventory_generation<>OLD.inventory_generation
  OR NEW.record_digest<>OLD.record_digest OR NEW.records<>OLD.records
  OR NEW.r2_count<>OLD.r2_count OR NEW.s3_count<>OLD.s3_count
  OR NEW.r2_bytes<>OLD.r2_bytes OR NEW.s3_bytes<>OLD.s3_bytes
  OR NEW.chunk_count<>OLD.chunk_count OR NEW.sha256<>OLD.sha256
  OR NEW.created_at<>OLD.created_at
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_IMMUTABLE'); END;
CREATE TRIGGER pa_purge_manifest_chunk_immutable
BEFORE UPDATE ON pa_purge_manifest_chunks
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_IMMUTABLE'); END;
CREATE TRIGGER pa_purge_manifest_chunk_no_delete
BEFORE DELETE ON pa_purge_manifest_chunks
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_CLEANUP_NOT_CONFIGURED'); END;
CREATE TRIGGER pa_purge_manifest_no_delete
BEFORE DELETE ON pa_purge_manifests
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_CLEANUP_NOT_CONFIGURED'); END;

-- Even a direct D1 erasing claim cannot be created from the old prepared
-- reference alone. The external erasing event and sealed plan must agree.
CREATE TRIGGER pa_purge_execution_requires_sealed_manifest
BEFORE INSERT ON pa_purge_execution_claims
WHEN NEW.state='erasing' AND NOT EXISTS(
  SELECT 1 FROM pa_purge_manifests m
  JOIN pa_owner_purge_events e ON e.owner_id=m.owner_id
    AND e.intent_id=m.intent_id AND e.stage='erasing'
  WHERE m.owner_id=NEW.owner_id AND m.intent_id=NEW.intent_id
    AND m.sealed_at IS NOT NULL AND m.sha256=NEW.manifest_sha256
    AND m.owner_epoch=NEW.owner_epoch
    AND m.inventory_generation=NEW.inventory_generation
    AND e.manifest_sha256=m.sha256
    AND e.owner_epoch=NEW.owner_epoch
    AND e.inventory_generation=NEW.inventory_generation
    AND e.retention_episode=NEW.retention_episode
    AND e.retention_revision=NEW.retention_revision AND e.due_at=NEW.due_at
    AND NEW.claimed_at>=e.recorded_at)
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_ERASING_PROOF_REQUIRED'); END;
