-- A marker is written to independent S3 only after the D1 record CAS commits.
-- Its D1 reference is a local read gate; recovery must discover/verify marker
-- versions from S3 when D1 itself is unavailable.
CREATE TABLE pa_record_commit_markers (
  owner_id TEXT NOT NULL,
  record_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  marker_object_key TEXT NOT NULL UNIQUE,
  marker_version_id TEXT NOT NULL,
  marker_sha256 TEXT NOT NULL CHECK(length(marker_sha256)=64),
  marker_bytes INTEGER NOT NULL CHECK(marker_bytes > 0),
  confirmed_at INTEGER NOT NULL CHECK(confirmed_at > 0),
  PRIMARY KEY(owner_id,record_id,revision),
  FOREIGN KEY(owner_id,record_id,revision)
    REFERENCES pa_record_recovery_versions(owner_id,record_id,revision) ON DELETE RESTRICT
);
CREATE INDEX pa_record_commit_markers_owner ON pa_record_commit_markers(owner_id,record_id,revision);

-- The intent's versioned S3 marker is uploaded before the D1 delete CAS.
-- The trigger prevents an overlapping old Worker from committing a deletion
-- that a D1-independent restore could mistake for an older live revision.
CREATE TABLE pa_record_delete_intents (
  owner_id TEXT NOT NULL,
  record_id TEXT NOT NULL,
  target_revision INTEGER NOT NULL CHECK(target_revision > 1),
  record_object_key TEXT NOT NULL,
  intent_object_key TEXT NOT NULL UNIQUE,
  intent_version_id TEXT NOT NULL,
  intent_sha256 TEXT NOT NULL CHECK(length(intent_sha256)=64),
  intent_bytes INTEGER NOT NULL CHECK(intent_bytes > 0),
  created_at INTEGER NOT NULL CHECK(created_at > 0),
  PRIMARY KEY(owner_id,record_id,target_revision),
  FOREIGN KEY(owner_id,record_id) REFERENCES pa_records(owner_id,record_id) ON DELETE RESTRICT
);
-- OFF during migration/backfill. Switch to ON only after all old writers are
-- stopped and the new Worker is deployed; the public service remains OFF.
CREATE TABLE pa_recovery_write_policy (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  delete_intent_required INTEGER NOT NULL CHECK(delete_intent_required IN (0,1))
);
INSERT INTO pa_recovery_write_policy(singleton,delete_intent_required) VALUES(1,0);
CREATE TRIGGER pa_recovery_write_policy_not_deleted BEFORE DELETE ON pa_recovery_write_policy
BEGIN SELECT RAISE(ABORT,'RECOVERY_POLICY_REQUIRED'); END;
CREATE TRIGGER pa_recovery_write_policy_requires_coverage
BEFORE UPDATE OF delete_intent_required ON pa_recovery_write_policy
WHEN NEW.delete_intent_required=1
  AND EXISTS(SELECT 1 FROM pa_records r WHERE NOT EXISTS(
    SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id
      AND m.record_id=r.record_id AND m.revision=r.revision))
BEGIN SELECT RAISE(ABORT,'RECOVERY_COVERAGE_INCOMPLETE'); END;
CREATE TRIGGER pa_record_delete_requires_intent BEFORE UPDATE OF deleted ON pa_records
WHEN OLD.deleted=0 AND NEW.deleted=1
  AND coalesce((SELECT delete_intent_required FROM pa_recovery_write_policy WHERE singleton=1),1)=1
  AND NOT EXISTS(SELECT 1 FROM pa_record_delete_intents i
    WHERE i.owner_id=OLD.owner_id AND i.record_id=OLD.record_id
      AND i.target_revision=NEW.revision)
BEGIN SELECT RAISE(ABORT,'DELETE_INTENT_REQUIRED'); END;

-- Capture only the exact revisions that existed before commit markers were
-- introduced. A later writer cannot turn a new, unbacked revision into a
-- readable "legacy" record merely by omitting its recovery reference.
CREATE TABLE pa_record_legacy_baseline (
  owner_id TEXT NOT NULL,
  record_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  initial_operation TEXT NOT NULL,
  initial_fingerprint TEXT NOT NULL,
  photo_key TEXT,
  photo_bytes INTEGER NOT NULL,
  quota_bytes INTEGER NOT NULL,
  deleted INTEGER NOT NULL,
  PRIMARY KEY(owner_id,record_id),
  FOREIGN KEY(owner_id,record_id) REFERENCES pa_records(owner_id,record_id) ON DELETE RESTRICT
);
INSERT INTO pa_record_legacy_baseline(owner_id,record_id,revision,initial_operation,
  initial_fingerprint,photo_key,
  photo_bytes,quota_bytes,deleted)
  SELECT r.owner_id,r.record_id,r.revision,r.initial_operation,r.initial_fingerprint,
    r.photo_key,r.photo_bytes,r.quota_bytes,r.deleted
  FROM pa_records r WHERE NOT EXISTS(SELECT 1 FROM pa_record_recovery_versions v
    WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision);

CREATE TABLE pa_recovery_repair_cursor (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  last_owner_id TEXT NOT NULL,
  last_record_id TEXT NOT NULL
);
INSERT INTO pa_recovery_repair_cursor(singleton,last_owner_id,last_record_id) VALUES(1,'','');
CREATE TABLE pa_recovery_repair_failures (
  owner_id TEXT NOT NULL,
  record_id TEXT NOT NULL,
  error_code TEXT NOT NULL,
  attempts INTEGER NOT NULL CHECK(attempts > 0),
  last_attempt_at INTEGER NOT NULL,
  PRIMARY KEY(owner_id,record_id),
  FOREIGN KEY(owner_id,record_id) REFERENCES pa_records(owner_id,record_id) ON DELETE RESTRICT
);
