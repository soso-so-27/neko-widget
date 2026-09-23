-- Dedicated preservation DB. Metadata only; no external copy is created or deleted.
-- A row records the exact versioned S3 objects that accompanied one D1 revision.
-- Old rows are kept so restore can replay revisions and tombstones. The owner
-- manifest and deletion ledger must reconcile them before activation.
CREATE TABLE pa_record_recovery_versions (
  owner_id TEXT NOT NULL,
  record_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  record_object_key TEXT NOT NULL UNIQUE,
  record_version_id TEXT NOT NULL,
  record_sha256 TEXT NOT NULL CHECK(length(record_sha256)=64),
  record_bytes INTEGER NOT NULL CHECK(record_bytes > 0),
  photo_object_key TEXT,
  photo_version_id TEXT,
  photo_sha256 TEXT,
  photo_bytes INTEGER,
  committed_at INTEGER NOT NULL CHECK(committed_at > 0),
  PRIMARY KEY(owner_id,record_id,revision),
  FOREIGN KEY(owner_id,record_id) REFERENCES pa_records(owner_id,record_id) ON DELETE RESTRICT,
  CHECK((photo_object_key IS NULL AND photo_version_id IS NULL
    AND photo_sha256 IS NULL AND photo_bytes IS NULL)
    OR (photo_object_key IS NOT NULL AND photo_version_id IS NOT NULL
    AND photo_sha256 IS NOT NULL AND length(photo_sha256)=64 AND photo_bytes > 0))
);
CREATE INDEX pa_record_recovery_owner ON pa_record_recovery_versions(owner_id,record_id,revision);
