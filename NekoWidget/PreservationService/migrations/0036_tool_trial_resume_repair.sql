-- Default empty. One separately reviewed repair of the existing snapshot only.
-- The old debt is retained; this budget INCLUDES the old unspent allowance.
CREATE TABLE pa_tool_trial_resume_repairs (
  owner_id TEXT PRIMARY KEY REFERENCES pa_tool_owner_trials(owner_id),
  owner_epoch INTEGER NOT NULL,
  snapshot_id TEXT NOT NULL,
  enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
  issued_at INTEGER NOT NULL,
  original_starts_at INTEGER NOT NULL,
  ends_at INTEGER NOT NULL CHECK(ends_at>issued_at AND ends_at<=original_starts_at+86400000),
  original_review_revision INTEGER NOT NULL,
  original_cost_evidence_sha256 TEXT NOT NULL,
  evidence_sha256 TEXT NOT NULL CHECK(length(evidence_sha256)=64 AND evidence_sha256 NOT GLOB '*[^0-9a-f]*'),
  pending_record_id TEXT NOT NULL,
  pending_input_fingerprint TEXT NOT NULL,
  pending_payload_sha256 TEXT NOT NULL,
  original_admitted_bytes INTEGER NOT NULL CHECK(original_admitted_bytes=17948504),
  original_attempts INTEGER NOT NULL CHECK(original_attempts=27),
  original_slots INTEGER NOT NULL CHECK(original_slots=20),
  repair_bytes INTEGER NOT NULL CHECK(repair_bytes=6425264),
  byte_limit INTEGER NOT NULL CHECK(byte_limit=20971520-original_admitted_bytes+repair_bytes),
  attempt_limit INTEGER NOT NULL CHECK(attempt_limit=22),
  record_limit INTEGER NOT NULL CHECK(record_limit=30),
  admitted_bytes INTEGER NOT NULL DEFAULT 0 CHECK(admitted_bytes BETWEEN 0 AND byte_limit)
);
CREATE TRIGGER pa_tool_resume_repair_issue BEFORE INSERT ON pa_tool_trial_resume_repairs
WHEN NEW.enabled!=1 OR NEW.admitted_bytes!=0 OR NOT EXISTS(
  SELECT 1 FROM pa_tool_owner_trials t JOIN pa_owners o ON o.owner_id=t.owner_id
  WHERE t.owner_id=NEW.owner_id AND t.owner_epoch=NEW.owner_epoch AND o.epoch=t.owner_epoch
    AND o.disabled=0 AND o.purge_fence_id IS NULL AND t.enabled=1 AND t.completed_at IS NULL
    AND t.snapshot_id=NEW.snapshot_id AND t.starts_at=NEW.original_starts_at AND t.ends_at=NEW.ends_at
    AND t.review_revision=NEW.original_review_revision AND t.cost_evidence_sha256=NEW.original_cost_evidence_sha256
    AND t.starts_at<=NEW.issued_at AND t.reviewed_at<=NEW.issued_at
    AND t.reviewed_at>NEW.issued_at-86400000 AND t.valid_until>NEW.issued_at
    AND t.byte_limit=20971520 AND t.attempt_limit=400 AND t.record_limit=200
    AND t.admitted_bytes=NEW.original_admitted_bytes AND t.attempts=NEW.original_attempts
    AND t.slot_generation=NEW.original_slots
    AND NOT EXISTS(SELECT 1 FROM pa_membership_links WHERE owner_id=t.owner_id)
    AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests WHERE owner_id=t.owner_id)
    AND (SELECT count(*) FROM pa_tool_trial_records WHERE owner_id=t.owner_id)=20
    AND (SELECT count(*) FROM pa_tool_trial_records WHERE owner_id=t.owner_id AND committed=1)=19
    AND (SELECT sum(content_bytes) FROM pa_tool_trial_records WHERE owner_id=t.owner_id AND committed=1)=11484328
    AND EXISTS(SELECT 1 FROM pa_tool_trial_records p WHERE p.owner_id=t.owner_id
      AND p.record_id=NEW.pending_record_id AND p.committed=0 AND p.kind='photo' AND p.content_bytes=801110
      AND p.snapshot_id=NEW.snapshot_id AND p.input_fingerprint=NEW.pending_input_fingerprint
      AND p.payload_sha256=NEW.pending_payload_sha256)
)
BEGIN SELECT RAISE(ABORT,'repair requires the exact interrupted trial, not a new allowance'); END;
CREATE TRIGGER pa_tool_resume_repair_immutable BEFORE UPDATE ON pa_tool_trial_resume_repairs
WHEN NEW.owner_id!=OLD.owner_id OR NEW.owner_epoch!=OLD.owner_epoch OR NEW.snapshot_id!=OLD.snapshot_id
  OR NEW.issued_at!=OLD.issued_at OR NEW.original_starts_at!=OLD.original_starts_at OR NEW.ends_at!=OLD.ends_at
  OR NEW.original_review_revision!=OLD.original_review_revision
  OR NEW.original_cost_evidence_sha256!=OLD.original_cost_evidence_sha256 OR NEW.evidence_sha256!=OLD.evidence_sha256
  OR NEW.pending_record_id!=OLD.pending_record_id OR NEW.pending_input_fingerprint!=OLD.pending_input_fingerprint
  OR NEW.pending_payload_sha256!=OLD.pending_payload_sha256 OR NEW.original_admitted_bytes!=OLD.original_admitted_bytes
  OR NEW.original_attempts!=OLD.original_attempts OR NEW.original_slots!=OLD.original_slots
  OR NEW.repair_bytes!=OLD.repair_bytes OR NEW.byte_limit!=OLD.byte_limit
  OR NEW.attempt_limit!=OLD.attempt_limit OR NEW.record_limit!=OLD.record_limit
  OR NEW.admitted_bytes<OLD.admitted_bytes OR NEW.enabled>OLD.enabled
BEGIN SELECT RAISE(ABORT,'repair scope and spent debt cannot be refilled'); END;
CREATE TRIGGER pa_tool_resume_repair_no_delete BEFORE DELETE ON pa_tool_trial_resume_repairs
WHEN NOT EXISTS(SELECT 1 FROM pa_owner_requested_erasing_authority WHERE owner_id=OLD.owner_id)
  AND NOT EXISTS(SELECT 1 FROM pa_purge_d1_erasing_authority WHERE owner_id=OLD.owner_id)
BEGIN SELECT RAISE(ABORT,'repair history cannot be reissued'); END;
-- An old Worker cannot keep charging the old bytes or exceed the repair scope.
CREATE TRIGGER pa_tool_resume_original_fence BEFORE UPDATE ON pa_tool_owner_trials
WHEN EXISTS(SELECT 1 FROM pa_tool_trial_resume_repairs r WHERE r.owner_id=OLD.owner_id
  AND (NEW.admitted_bytes!=r.original_admitted_bytes OR NEW.attempts>r.original_attempts+r.attempt_limit
    OR NEW.slot_generation>r.record_limit))
BEGIN SELECT RAISE(ABORT,'repair uses its own lifetime byte debt'); END;
CREATE TRIGGER pa_tool_resume_slot_fence BEFORE INSERT ON pa_tool_trial_records
WHEN EXISTS(SELECT 1 FROM pa_tool_trial_resume_repairs r JOIN pa_tool_owner_trials t ON t.owner_id=r.owner_id
  WHERE r.owner_id=NEW.owner_id AND (r.enabled!=1 OR NEW.snapshot_id!=r.snapshot_id
    OR t.slot_generation>=r.record_limit OR t.review_revision!=r.original_review_revision))
BEGIN SELECT RAISE(ABORT,'repair snapshot slots exhausted or revoked'); END;
