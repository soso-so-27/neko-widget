-- Only a completed, externally mirrored erasure may remove its D1 proof.
-- The application inserts and consumes this permit in the SAME D1 batch as
-- one bounded delete. No permit is retained between calls or after success.
-- External S3 completed history remains until the D1 restore window passes.
CREATE TABLE pa_purge_evidence_cleanup_permits (
  owner_id TEXT PRIMARY KEY,
  intent_id TEXT NOT NULL,
  manifest_sha256 TEXT NOT NULL CHECK(length(manifest_sha256)=64),
  completed_at INTEGER NOT NULL CHECK(completed_at>0),
  s3_object_key TEXT NOT NULL,
  s3_version_id TEXT NOT NULL CHECK(length(s3_version_id)>0),
  s3_sha256 TEXT NOT NULL CHECK(length(s3_sha256)=64),
  s3_bytes INTEGER NOT NULL CHECK(s3_bytes BETWEEN 1 AND 4096),
  issued_at INTEGER NOT NULL CHECK(issued_at>0),
  expires_at INTEGER NOT NULL CHECK(expires_at>issued_at
    AND expires_at<=issued_at+60000),
  CHECK(s3_object_key='purge/v1/'||owner_id||'/'||intent_id||'/completed')
);

CREATE TRIGGER pa_purge_evidence_cleanup_permit_guard
BEFORE INSERT ON pa_purge_evidence_cleanup_permits
WHEN NEW.issued_at < (unixepoch()-10)*1000
  OR NEW.issued_at > (unixepoch()+10)*1000
  OR EXISTS(SELECT 1 FROM pa_owners WHERE owner_id=NEW.owner_id)
  OR NOT EXISTS(SELECT 1 FROM pa_purge_execution_claims c
    JOIN pa_owner_purge_events e ON e.owner_id=c.owner_id
      AND e.intent_id=c.intent_id AND e.stage='completed'
    WHERE c.owner_id=NEW.owner_id AND c.intent_id=NEW.intent_id
      AND c.state='completed' AND c.finished_at=NEW.completed_at
      AND c.manifest_sha256=NEW.manifest_sha256
      AND e.manifest_sha256=c.manifest_sha256
      AND e.recorded_at<=c.finished_at
      AND e.s3_object_key=NEW.s3_object_key
      AND e.s3_version_id=NEW.s3_version_id
      AND e.s3_sha256=NEW.s3_sha256 AND e.s3_bytes=NEW.s3_bytes)
  OR EXISTS(SELECT 1 FROM pa_purge_execution_claims c
    WHERE c.owner_id=NEW.owner_id AND c.state NOT IN ('aborted','completed'))
BEGIN SELECT RAISE(ABORT,'PURGE_EVIDENCE_CLEANUP_NOT_AUTHORIZED'); END;

CREATE TRIGGER pa_purge_evidence_cleanup_permit_immutable
BEFORE UPDATE ON pa_purge_evidence_cleanup_permits
BEGIN SELECT RAISE(ABORT,'PURGE_EVIDENCE_CLEANUP_PERMIT_IMMUTABLE'); END;

CREATE VIEW pa_purge_evidence_cleanup_authority AS
SELECT p.owner_id,p.intent_id FROM pa_purge_evidence_cleanup_permits p
WHERE p.expires_at>unixepoch()*1000
  AND NOT EXISTS(SELECT 1 FROM pa_owners o WHERE o.owner_id=p.owner_id);

DROP TRIGGER pa_purge_remote_ref_no_delete;
CREATE TRIGGER pa_purge_remote_ref_no_delete
BEFORE DELETE ON pa_purge_manifest_remote_refs
WHEN NOT EXISTS(SELECT 1 FROM pa_purge_evidence_cleanup_authority a
  WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'PURGE_REMOTE_CLEANUP_NOT_CONFIGURED'); END;

DROP TRIGGER pa_purge_remote_seal_no_delete;
CREATE TRIGGER pa_purge_remote_seal_no_delete
BEFORE DELETE ON pa_purge_manifest_remote_seals
WHEN NOT EXISTS(SELECT 1 FROM pa_purge_evidence_cleanup_authority a
  WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'PURGE_REMOTE_CLEANUP_NOT_CONFIGURED'); END;

DROP TRIGGER pa_purge_manifest_chunk_no_delete;
CREATE TRIGGER pa_purge_manifest_chunk_no_delete
BEFORE DELETE ON pa_purge_manifest_chunks
WHEN NOT EXISTS(SELECT 1 FROM pa_purge_evidence_cleanup_authority a
  WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_CLEANUP_NOT_CONFIGURED'); END;

DROP TRIGGER pa_purge_manifest_no_delete;
CREATE TRIGGER pa_purge_manifest_no_delete
BEFORE DELETE ON pa_purge_manifests
WHEN NOT EXISTS(SELECT 1 FROM pa_purge_evidence_cleanup_authority a
  WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'PURGE_MANIFEST_CLEANUP_NOT_CONFIGURED'); END;

DROP TRIGGER pa_owner_purge_events_no_delete;
CREATE TRIGGER pa_owner_purge_events_no_delete
BEFORE DELETE ON pa_owner_purge_events
WHEN NOT EXISTS(SELECT 1 FROM pa_purge_evidence_cleanup_authority a
  WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'PURGE_EVENT_CLEANUP_NOT_CONFIGURED'); END;

DROP TRIGGER pa_purge_execution_claim_no_delete;
CREATE TRIGGER pa_purge_execution_claim_no_delete
BEFORE DELETE ON pa_purge_execution_claims
WHEN NOT EXISTS(SELECT 1 FROM pa_purge_evidence_cleanup_authority a
  WHERE a.owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'PURGE_EXECUTION_CLEANUP_NOT_CONFIGURED'); END;
