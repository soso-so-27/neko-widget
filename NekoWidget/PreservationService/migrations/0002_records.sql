CREATE TABLE pa_inventory (
  owner_id TEXT PRIMARY KEY REFERENCES pa_owners(owner_id),
  generation INTEGER NOT NULL DEFAULT 0,
  used_bytes INTEGER NOT NULL DEFAULT 0 CHECK(used_bytes >= 0),
  reserved_bytes INTEGER NOT NULL DEFAULT 0 CHECK(reserved_bytes >= 0)
);
CREATE TABLE pa_records (
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id),
  record_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  initial_fingerprint TEXT NOT NULL,
  initial_operation TEXT NOT NULL,
  metadata BLOB,
  photo_key TEXT,
  photo_bytes INTEGER NOT NULL DEFAULT 0,
  quota_bytes INTEGER NOT NULL DEFAULT 0,
  deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN(0,1)),
  PRIMARY KEY(owner_id,record_id),
  CHECK((deleted=0 AND metadata IS NOT NULL) OR (deleted=1 AND metadata IS NULL))
);
-- Reservations retain object names until a failed/interrupted upload is cleaned.
CREATE TABLE pa_uploads (
  operation_id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id),
  record_id TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  reserved_bytes INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'active' CHECK(state IN('active','cleaning'))
);
CREATE TABLE pa_pending_deletes (
  object_key TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  next_attempt_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX pa_deletion_due ON pa_pending_deletes(next_attempt_at,created_at);
CREATE TRIGGER pa_record_insert AFTER INSERT ON pa_records BEGIN
  UPDATE pa_inventory SET generation=generation+1, used_bytes=used_bytes+NEW.quota_bytes WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_record_update AFTER UPDATE ON pa_records BEGIN
  UPDATE pa_inventory SET generation=generation+1, used_bytes=used_bytes+NEW.quota_bytes-OLD.quota_bytes WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_upload_insert AFTER INSERT ON pa_uploads BEGIN
  UPDATE pa_inventory SET reserved_bytes=reserved_bytes+NEW.reserved_bytes WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_upload_delete AFTER DELETE ON pa_uploads BEGIN
  UPDATE pa_inventory SET reserved_bytes=reserved_bytes-OLD.reserved_bytes WHERE owner_id=OLD.owner_id;
END;
