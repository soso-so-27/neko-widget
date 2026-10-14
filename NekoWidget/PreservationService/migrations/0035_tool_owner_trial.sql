-- Empty, operator-issued grants only. No owner, deadline or existing counter is changed.
CREATE TABLE pa_tool_owner_trials (
  owner_id TEXT PRIMARY KEY REFERENCES pa_owners(owner_id),
  owner_epoch INTEGER NOT NULL CHECK(owner_epoch>=0),
  enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
  starts_at INTEGER NOT NULL CHECK(starts_at>=0),
  ends_at INTEGER NOT NULL CHECK(ends_at>starts_at AND ends_at<=starts_at+86400000),
  reviewed_at INTEGER NOT NULL CHECK(reviewed_at>=0),
  valid_until INTEGER NOT NULL CHECK(valid_until>reviewed_at AND valid_until<=reviewed_at+86400000 AND valid_until<=ends_at),
  cost_evidence_sha256 TEXT NOT NULL CHECK(length(cost_evidence_sha256)=64 AND cost_evidence_sha256 NOT GLOB '*[^0-9a-f]*'),
  review_revision INTEGER NOT NULL DEFAULT 1 CHECK(review_revision>0),
  snapshot_id TEXT,
  byte_limit INTEGER NOT NULL CHECK(byte_limit BETWEEN 1 AND 20971520),
  attempt_limit INTEGER NOT NULL CHECK(attempt_limit BETWEEN 1 AND 400),
  record_limit INTEGER NOT NULL CHECK(record_limit BETWEEN 2 AND 200),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND attempt_limit),
  admitted_bytes INTEGER NOT NULL DEFAULT 0 CHECK(admitted_bytes BETWEEN 0 AND byte_limit),
  slot_generation INTEGER NOT NULL DEFAULT 0 CHECK(slot_generation BETWEEN 0 AND record_limit),
  completed_at INTEGER CHECK(completed_at>=starts_at AND completed_at<ends_at)
);
CREATE TRIGGER pa_tool_trial_existing_owner BEFORE INSERT ON pa_tool_owner_trials
WHEN NOT EXISTS(SELECT 1 FROM pa_owners WHERE owner_id=NEW.owner_id AND epoch=NEW.owner_epoch
  AND disabled=0 AND purge_fence_id IS NULL)
BEGIN SELECT RAISE(ABORT,'trial requires an existing enabled owner'); END;
CREATE TRIGGER pa_tool_trial_no_refill BEFORE UPDATE ON pa_tool_owner_trials
WHEN NEW.owner_id!=OLD.owner_id OR NEW.owner_epoch!=OLD.owner_epoch
  OR NEW.starts_at!=OLD.starts_at OR NEW.ends_at!=OLD.ends_at
  OR NEW.byte_limit!=OLD.byte_limit OR NEW.attempt_limit!=OLD.attempt_limit OR NEW.record_limit!=OLD.record_limit
  OR NEW.attempts<OLD.attempts OR NEW.admitted_bytes<OLD.admitted_bytes
  OR NEW.slot_generation<OLD.slot_generation
  OR (OLD.snapshot_id IS NOT NULL AND NEW.snapshot_id IS NOT OLD.snapshot_id)
  OR (OLD.completed_at IS NOT NULL AND NEW.completed_at IS NOT OLD.completed_at)
  OR NEW.reviewed_at<OLD.reviewed_at OR NEW.review_revision<OLD.review_revision
  OR ((NEW.reviewed_at!=OLD.reviewed_at OR NEW.valid_until!=OLD.valid_until
    OR NEW.cost_evidence_sha256!=OLD.cost_evidence_sha256 OR NEW.enabled!=OLD.enabled)
    AND NEW.review_revision<=OLD.review_revision)
BEGIN SELECT RAISE(ABORT,'trial scope and spent allowance cannot be reset'); END;
CREATE TRIGGER pa_tool_trial_no_delete BEFORE DELETE ON pa_tool_owner_trials
WHEN NOT EXISTS(SELECT 1 FROM pa_owner_requested_erasing_authority WHERE owner_id=OLD.owner_id)
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority WHERE owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'trial history cannot be reissued'); END;
CREATE TABLE pa_tool_trial_records (
  owner_id TEXT NOT NULL REFERENCES pa_tool_owner_trials(owner_id),
  record_id TEXT NOT NULL,
  snapshot_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('json','photo','index')),
  path TEXT NOT NULL,
  part INTEGER NOT NULL CHECK(part>=0),
  part_count INTEGER NOT NULL CHECK(part_count>part AND part_count<=256),
  payload_sha256 TEXT NOT NULL,
  input_fingerprint TEXT NOT NULL,
  content_bytes INTEGER NOT NULL CHECK(content_bytes>0),
  committed INTEGER NOT NULL DEFAULT 0 CHECK(committed IN (0,1)),
  PRIMARY KEY(owner_id,record_id), UNIQUE(owner_id,path,part)
);
CREATE TRIGGER pa_tool_trial_record_scope BEFORE INSERT ON pa_tool_trial_records
WHEN NOT EXISTS(SELECT 1 FROM pa_tool_owner_trials t WHERE t.owner_id=NEW.owner_id
  AND t.snapshot_id=NEW.snapshot_id AND t.completed_at IS NULL
  AND (SELECT count(*) FROM pa_tool_trial_records WHERE owner_id=NEW.owner_id)<t.record_limit)
BEGIN SELECT RAISE(ABORT,'trial record scope exhausted'); END;
CREATE TRIGGER pa_tool_trial_record_generation AFTER INSERT ON pa_tool_trial_records
BEGIN UPDATE pa_tool_owner_trials SET slot_generation=slot_generation+1 WHERE owner_id=NEW.owner_id; END;
CREATE TRIGGER pa_tool_trial_record_immutable BEFORE UPDATE ON pa_tool_trial_records
WHEN NEW.owner_id!=OLD.owner_id OR NEW.record_id!=OLD.record_id OR NEW.snapshot_id!=OLD.snapshot_id
  OR NEW.kind!=OLD.kind OR NEW.path!=OLD.path OR NEW.part!=OLD.part OR NEW.part_count!=OLD.part_count
  OR NEW.payload_sha256!=OLD.payload_sha256 OR NEW.input_fingerprint!=OLD.input_fingerprint
  OR NEW.content_bytes!=OLD.content_bytes OR NEW.committed<OLD.committed
BEGIN SELECT RAISE(ABORT,'trial pieces are immutable'); END;
CREATE TRIGGER pa_tool_trial_record_no_delete BEFORE DELETE ON pa_tool_trial_records
WHEN NOT EXISTS(SELECT 1 FROM pa_owner_requested_erasing_authority WHERE owner_id=OLD.owner_id)
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority WHERE owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'trial slots cannot be refunded'); END;
