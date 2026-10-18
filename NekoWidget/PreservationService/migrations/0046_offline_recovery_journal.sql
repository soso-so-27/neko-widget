-- Offline-only, bounded recovery spool. No table is an activation authority.
-- Jobs can precede pa_owners in an empty quarantine target; retain owner_id for
-- explicit residue inspection and owner erasure. No public route writes here.
CREATE TABLE pa_offline_recovery_jobs (
  owner_id TEXT PRIMARY KEY NOT NULL, nonce TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),
  lease_token TEXT,
  phase TEXT NOT NULL DEFAULT 'listing',
  state_json TEXT NOT NULL DEFAULT '{}' CHECK(length(state_json)<=524288),
  listed_count INTEGER NOT NULL DEFAULT 0 CHECK(listed_count BETWEEN 0 AND 10000000),
  expected_count INTEGER NOT NULL DEFAULT 0 CHECK(expected_count BETWEEN 0 AND 1000000)
);
CREATE TABLE pa_offline_recovery_objects (
  owner_id TEXT NOT NULL REFERENCES pa_offline_recovery_jobs(owner_id),
  object_key TEXT NOT NULL, version_id TEXT NOT NULL, bytes INTEGER NOT NULL CHECK(bytes>=0),
  kind TEXT NOT NULL CHECK(kind IN ('owner','manifest','other')),
  reference_json TEXT CHECK(reference_json IS NULL OR length(reference_json)<=4096),
  inspected INTEGER NOT NULL DEFAULT 0 CHECK(inspected IN (0,1)),
  seen_again INTEGER NOT NULL DEFAULT 0 CHECK(seen_again IN (0,1)),
  PRIMARY KEY(owner_id,object_key,version_id)
);
CREATE INDEX pa_offline_objects_pending ON pa_offline_recovery_objects(owner_id,inspected,kind,object_key,version_id);
CREATE TABLE pa_offline_recovery_owners (
  owner_id TEXT NOT NULL REFERENCES pa_offline_recovery_jobs(owner_id),
  generation INTEGER NOT NULL CHECK(generation>0), reference_json TEXT NOT NULL CHECK(length(reference_json)<=4096),
  header_json TEXT NOT NULL CHECK(length(header_json)<=262144), tree_json TEXT CHECK(tree_json IS NULL OR length(tree_json)<=4096),
  root_hash TEXT NOT NULL, record_count INTEGER NOT NULL CHECK(record_count BETWEEN 0 AND 1000000),
  PRIMARY KEY(owner_id,generation)
);
CREATE TABLE pa_offline_recovery_expected (
  owner_id TEXT NOT NULL REFERENCES pa_offline_recovery_jobs(owner_id), record_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision>0), deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
  marker_key TEXT NOT NULL, marker_version TEXT NOT NULL, marker_hash TEXT NOT NULL, marker_bytes INTEGER NOT NULL CHECK(marker_bytes>0),
  PRIMARY KEY(owner_id,record_id)
);
CREATE TRIGGER pa_offline_expected_count AFTER INSERT ON pa_offline_recovery_expected BEGIN
  UPDATE pa_offline_recovery_jobs SET expected_count=expected_count+1 WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_offline_expected_monotonic BEFORE UPDATE ON pa_offline_recovery_expected
WHEN NEW.revision<OLD.revision OR (OLD.deleted=1 AND NEW.deleted=0)
  OR (NEW.revision=OLD.revision AND (NEW.deleted<>OLD.deleted OR NEW.marker_key<>OLD.marker_key
    OR NEW.marker_version<>OLD.marker_version OR NEW.marker_hash<>OLD.marker_hash OR NEW.marker_bytes<>OLD.marker_bytes))
BEGIN SELECT RAISE(ABORT,'OFFLINE_RECOVERY_ROLLBACK'); END;
CREATE TABLE pa_offline_recovery_revisions (
  owner_id TEXT NOT NULL REFERENCES pa_offline_recovery_jobs(owner_id), record_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision>0), kind TEXT NOT NULL CHECK(kind IN ('commit','delete-intent')),
  payload_json TEXT NOT NULL CHECK(length(payload_json)<=8192),
  PRIMARY KEY(owner_id,record_id,revision,kind)
);
CREATE TABLE pa_offline_recovery_heads (
  owner_id TEXT NOT NULL REFERENCES pa_offline_recovery_jobs(owner_id), record_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision>0), head_json TEXT NOT NULL CHECK(length(head_json)<=8192),
  PRIMARY KEY(owner_id,record_id)
);
