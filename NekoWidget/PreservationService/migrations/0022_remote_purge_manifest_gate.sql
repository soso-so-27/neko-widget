-- Separate, versioned S3 proof for every D1 deletion-plan chunk. These rows
-- contain identifiers and hashes only; they do not enable physical deletion.
CREATE TABLE pa_purge_manifest_remote_refs (
  owner_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK(ordinal >= -1 AND ordinal < 1564),
  s3_object_key TEXT NOT NULL,
  s3_version_id TEXT NOT NULL CHECK(length(s3_version_id) BETWEEN 1 AND 1024
    AND s3_version_id <> 'null'),
  s3_sha256 TEXT NOT NULL CHECK(length(s3_sha256)=64),
  s3_bytes INTEGER NOT NULL CHECK(s3_bytes BETWEEN 1 AND 524288),
  confirmed_at INTEGER NOT NULL CHECK(confirmed_at > 0),
  PRIMARY KEY(owner_id,intent_id,ordinal),
  FOREIGN KEY(owner_id,intent_id) REFERENCES pa_purge_manifests(owner_id,intent_id)
);
CREATE TABLE pa_purge_manifest_remote_seals (
  owner_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  root_sha256 TEXT NOT NULL CHECK(length(root_sha256)=64),
  sealed_at INTEGER NOT NULL CHECK(sealed_at > 0),
  PRIMARY KEY(owner_id,intent_id),
  FOREIGN KEY(owner_id,intent_id) REFERENCES pa_purge_manifests(owner_id,intent_id)
);

CREATE TRIGGER pa_purge_remote_ref_guard
BEFORE INSERT ON pa_purge_manifest_remote_refs
WHEN NOT EXISTS(
  SELECT 1 FROM pa_purge_manifests m
  LEFT JOIN pa_purge_manifest_chunks c ON c.owner_id=m.owner_id
    AND c.intent_id=m.intent_id AND c.ordinal=NEW.ordinal
  WHERE m.owner_id=NEW.owner_id AND m.intent_id=NEW.intent_id
    AND m.sealed_at IS NOT NULL
    AND NOT EXISTS(SELECT 1 FROM pa_purge_manifest_remote_seals s
      WHERE s.owner_id=m.owner_id AND s.intent_id=m.intent_id)
    AND NEW.confirmed_at>=m.sealed_at
    AND ((NEW.ordinal=-1
      AND NEW.s3_object_key='purge-plan/v1/'||m.owner_id||'/'||m.intent_id||'/header')
      OR (NEW.ordinal>=0 AND NEW.ordinal<m.chunk_count
        AND NEW.s3_object_key='purge-plan/v1/'||m.owner_id||'/'||m.intent_id||
          '/chunk/'||printf('%06d',NEW.ordinal)
        AND NEW.s3_sha256=c.sha256 AND NEW.s3_bytes=c.bytes))
)
BEGIN SELECT RAISE(ABORT,'PURGE_REMOTE_REF_MISMATCH'); END;

CREATE TRIGGER pa_purge_remote_seal_guard
BEFORE INSERT ON pa_purge_manifest_remote_seals
WHEN NOT EXISTS(
  SELECT 1 FROM pa_purge_manifests m
  WHERE m.owner_id=NEW.owner_id AND m.intent_id=NEW.intent_id
    AND m.sealed_at IS NOT NULL AND NEW.root_sha256=m.sha256
    AND NEW.sealed_at>=m.sealed_at
    AND (SELECT COUNT(*) FROM pa_purge_manifest_remote_refs r
      WHERE r.owner_id=m.owner_id AND r.intent_id=m.intent_id)=m.chunk_count+1
    AND (SELECT COUNT(*) FROM pa_purge_manifest_remote_refs r
      WHERE r.owner_id=m.owner_id AND r.intent_id=m.intent_id
        AND r.ordinal=-1)=1
    AND (m.chunk_count=0 OR (
      (SELECT MIN(ordinal) FROM pa_purge_manifest_remote_refs r
        WHERE r.owner_id=m.owner_id AND r.intent_id=m.intent_id
          AND r.ordinal>=0)=0 AND
      (SELECT MAX(ordinal) FROM pa_purge_manifest_remote_refs r
        WHERE r.owner_id=m.owner_id AND r.intent_id=m.intent_id
          AND r.ordinal>=0)=m.chunk_count-1))
)
BEGIN SELECT RAISE(ABORT,'PURGE_REMOTE_PLAN_INCOMPLETE'); END;

CREATE TRIGGER pa_purge_remote_ref_immutable
BEFORE UPDATE ON pa_purge_manifest_remote_refs
BEGIN SELECT RAISE(ABORT,'PURGE_REMOTE_PLAN_IMMUTABLE'); END;
CREATE TRIGGER pa_purge_remote_seal_immutable
BEFORE UPDATE ON pa_purge_manifest_remote_seals
BEGIN SELECT RAISE(ABORT,'PURGE_REMOTE_PLAN_IMMUTABLE'); END;
CREATE TRIGGER pa_purge_remote_ref_no_delete
BEFORE DELETE ON pa_purge_manifest_remote_refs
BEGIN SELECT RAISE(ABORT,'PURGE_REMOTE_CLEANUP_NOT_CONFIGURED'); END;
CREATE TRIGGER pa_purge_remote_seal_no_delete
BEFORE DELETE ON pa_purge_manifest_remote_seals
BEGIN SELECT RAISE(ABORT,'PURGE_REMOTE_CLEANUP_NOT_CONFIGURED'); END;

DROP TRIGGER pa_purge_execution_requires_sealed_manifest;
CREATE TRIGGER pa_purge_execution_requires_sealed_manifest
BEFORE INSERT ON pa_purge_execution_claims
WHEN NEW.state='erasing' AND NOT EXISTS(
  SELECT 1 FROM pa_purge_manifests m
  JOIN pa_purge_manifest_remote_seals s ON s.owner_id=m.owner_id
    AND s.intent_id=m.intent_id AND s.root_sha256=m.sha256
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
    AND NEW.claimed_at>=e.recorded_at AND NEW.claimed_at>=s.sealed_at)
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_ERASING_PROOF_REQUIRED'); END;
