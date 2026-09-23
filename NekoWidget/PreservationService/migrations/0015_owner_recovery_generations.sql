-- Dedicated preservation DB. This migration assigns a monotonically
-- increasing generation to owner state. It neither copies nor restores data.
-- Apply only while every old Writer is stopped; then backfill every current
-- generation to independent S3 before activating the owner snapshot policy.
CREATE TABLE pa_owner_recovery_generations (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  generation INTEGER NOT NULL CHECK(generation > 0)
);
INSERT INTO pa_owner_recovery_generations(owner_id,generation)
  SELECT owner_id,1 FROM pa_owners;

CREATE TRIGGER pa_owner_recovery_owner_insert AFTER INSERT ON pa_owners
BEGIN
  INSERT INTO pa_owner_recovery_generations(owner_id,generation) VALUES(NEW.owner_id,1);
END;
CREATE TRIGGER pa_owner_recovery_owner_update
AFTER UPDATE OF identity_key,epoch,disabled,purge_fence_id ON pa_owners
BEGIN
  UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_owner_recovery_credential_insert AFTER INSERT ON pa_identity_credentials
BEGIN
  UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_owner_recovery_credential_update AFTER UPDATE ON pa_identity_credentials
BEGIN
  UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_owner_recovery_contact_insert AFTER INSERT ON pa_notice_contacts
BEGIN
  UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_owner_recovery_contact_update AFTER UPDATE ON pa_notice_contacts
BEGIN
  UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_owner_recovery_billing_insert AFTER INSERT ON pa_membership_links
BEGIN
  UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_owner_recovery_retention_insert AFTER INSERT ON pa_retention
BEGIN
  UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_owner_recovery_retention_update AFTER UPDATE ON pa_retention
BEGIN
  UPDATE pa_owner_recovery_generations SET generation=generation+1 WHERE owner_id=NEW.owner_id;
END;

-- References are local acknowledgement gates. The version itself is
-- independently verified in S3 before insert, and D1-loss recovery must
-- discover/verify every version from S3 again.
CREATE TABLE pa_owner_recovery_versions (
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  generation INTEGER NOT NULL CHECK(generation > 0),
  object_key TEXT NOT NULL UNIQUE,
  version_id TEXT NOT NULL,
  sha256 TEXT NOT NULL CHECK(length(sha256)=64),
  bytes INTEGER NOT NULL CHECK(bytes > 0),
  confirmed_at INTEGER NOT NULL CHECK(confirmed_at > 0),
  PRIMARY KEY(owner_id,generation)
);
CREATE TRIGGER pa_owner_recovery_current_generation BEFORE INSERT ON pa_owner_recovery_versions
WHEN NEW.generation <> coalesce((SELECT generation FROM pa_owner_recovery_generations
  WHERE owner_id=NEW.owner_id),-1)
BEGIN SELECT RAISE(ABORT,'OWNER_RECOVERY_STALE_GENERATION'); END;

ALTER TABLE pa_recovery_write_policy ADD COLUMN owner_snapshot_required INTEGER NOT NULL DEFAULT 0
  CHECK(owner_snapshot_required IN (0,1));
CREATE TRIGGER pa_owner_recovery_policy_requires_coverage
BEFORE UPDATE OF owner_snapshot_required ON pa_recovery_write_policy
WHEN NEW.owner_snapshot_required=1
BEGIN
  SELECT CASE WHEN EXISTS(SELECT 1 FROM pa_purge_fences
    WHERE state IN ('proposed','fenced'))
    THEN RAISE(ABORT,'OWNER_RECOVERY_ACTIVE_PURGE_FENCE') END;
  SELECT CASE WHEN EXISTS(SELECT 1 FROM pa_owner_recovery_generations g
    WHERE NOT EXISTS(SELECT 1 FROM pa_owner_recovery_versions v
      WHERE v.owner_id=g.owner_id AND v.generation=g.generation))
    THEN RAISE(ABORT,'OWNER_RECOVERY_COVERAGE_INCOMPLETE') END;
END;

-- Until a pre-revocation S3 intent and fenced-owner replay are implemented,
-- D1 alone must never disable or thaw an owner while snapshots are required.
-- This also protects against an unreviewed caller bypassing OwnerPurgeFence.
CREATE TRIGGER pa_owner_recovery_blocks_unbacked_fence
BEFORE UPDATE OF disabled,purge_fence_id ON pa_owners
WHEN (NEW.disabled<>OLD.disabled OR NEW.purge_fence_id IS NOT OLD.purge_fence_id)
  AND (SELECT owner_snapshot_required FROM pa_recovery_write_policy WHERE singleton=1)=1
BEGIN SELECT RAISE(ABORT,'OWNER_RECOVERY_FENCE_INTENT_REQUIRED'); END;

CREATE TABLE pa_owner_recovery_repair_cursor (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  last_owner_id TEXT NOT NULL
);
INSERT INTO pa_owner_recovery_repair_cursor(singleton,last_owner_id) VALUES(1,'');
CREATE TABLE pa_owner_recovery_repair_failures (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  error_code TEXT NOT NULL,
  attempts INTEGER NOT NULL CHECK(attempts > 0),
  last_attempt_at INTEGER NOT NULL CHECK(last_attempt_at > 0)
);
