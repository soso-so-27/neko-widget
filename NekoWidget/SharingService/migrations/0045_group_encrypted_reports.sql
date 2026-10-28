PRAGMA foreign_keys = ON;

-- Additive receiver only. No runtime flag, existing row, key or owner policy
-- is changed. Apply remotely only after owner review. The independent group
-- report gate must remain OFF until group-aware owner review is connected.
CREATE TABLE group_report_access (
  space_id TEXT NOT NULL REFERENCES group_windows(space_id),
  device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  expires_at INTEGER NOT NULL,
  PRIMARY KEY(space_id,device_id)
) STRICT;
CREATE INDEX group_report_access_expiry ON group_report_access(expires_at);

-- Revocation preserves only a 24-hour right to report previously delivered
-- material. Repeated revocation cannot extend that deadline. Re-admission
-- starts a new membership period and removes its old report-only grant.
CREATE TRIGGER group_report_window_device_revoked AFTER UPDATE OF state ON group_window_devices
WHEN OLD.state='active' AND NEW.state='revoked'
BEGIN
  INSERT INTO group_report_access VALUES (NEW.space_id,NEW.device_id,unixepoch()+86400)
    ON CONFLICT(space_id,device_id) DO UPDATE SET expires_at=MIN(expires_at,excluded.expires_at);
END;
CREATE TRIGGER group_report_window_device_readmitted AFTER UPDATE OF state ON group_window_devices
WHEN OLD.state<>'active' AND NEW.state='active'
BEGIN
  DELETE FROM group_report_access WHERE space_id=NEW.space_id AND device_id=NEW.device_id;
END;
CREATE TRIGGER group_report_member_revoked AFTER UPDATE OF state ON group_members
WHEN OLD.state='active' AND NEW.state<>'active'
BEGIN
  INSERT INTO group_report_access SELECT NEW.space_id,device_id,unixepoch()+86400
    FROM group_window_devices WHERE space_id=NEW.space_id AND participant_id=NEW.participant_id AND state='active'
    ON CONFLICT(space_id,device_id) DO UPDATE SET expires_at=MIN(expires_at,excluded.expires_at);
END;
CREATE TRIGGER group_report_device_revoked AFTER UPDATE OF state ON group_person_devices
WHEN OLD.state='active' AND NEW.state='revoked'
BEGIN
  INSERT INTO group_report_access SELECT space_id,NEW.id,unixepoch()+86400
    FROM group_window_devices WHERE device_id=NEW.id AND state='active'
    ON CONFLICT(space_id,device_id) DO UPDATE SET expires_at=MIN(expires_at,excluded.expires_at);
END;
CREATE TRIGGER group_report_person_revoked AFTER UPDATE OF state ON group_people
WHEN OLD.state='active' AND NEW.state='revoked'
BEGIN
  INSERT INTO group_report_access SELECT wd.space_id,wd.device_id,unixepoch()+86400
    FROM group_window_devices wd JOIN group_person_devices d ON d.id=wd.device_id
    WHERE d.person_id=NEW.id AND wd.state='active' AND d.state='active'
    ON CONFLICT(space_id,device_id) DO UPDATE SET expires_at=MIN(expires_at,excluded.expires_at);
END;
CREATE TRIGGER group_report_window_closed AFTER UPDATE OF mode ON group_windows
WHEN OLD.mode='active' AND NEW.mode='closed'
BEGIN
  INSERT INTO group_report_access SELECT NEW.space_id,device_id,unixepoch()+86400
    FROM group_window_devices WHERE space_id=NEW.space_id AND state='active'
    ON CONFLICT(space_id,device_id) DO UPDATE SET expires_at=MIN(expires_at,excluded.expires_at);
END;

CREATE VIEW group_report_credentials AS
  SELECT w.space_id,wd.device_id,m.participant_id,m.person_id
  FROM group_windows w JOIN group_window_devices wd ON wd.space_id=w.space_id
  JOIN group_members m ON m.participant_id=wd.participant_id AND m.space_id=w.space_id
  JOIN group_person_devices d ON d.id=wd.device_id AND d.person_id=m.person_id
  JOIN group_people p ON p.id=m.person_id
  WHERE (w.mode='active' AND wd.state='active' AND m.state='active' AND d.state='active' AND p.state='active')
    OR EXISTS (SELECT 1 FROM group_report_access a WHERE a.space_id=w.space_id AND a.device_id=wd.device_id AND a.expires_at>unixepoch());

CREATE TABLE group_report_checks (
  id TEXT PRIMARY KEY,
  space_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  gate_generation INTEGER NOT NULL
) STRICT;
CREATE TRIGGER group_report_check BEFORE INSERT ON group_report_checks
BEGIN
  SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM personal_staging_runtime_gate
    WHERE singleton=1 AND report_ingestion_enabled=1 AND generation=NEW.gate_generation)
    THEN RAISE(ABORT,'group_report_gate_closed') END);
  SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_report_credentials
    WHERE space_id=NEW.space_id AND device_id=NEW.device_id)
    THEN RAISE(ABORT,'group_report_not_authorized') END);
  SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_owner_scope_installation) AND NOT EXISTS (
    SELECT 1 FROM moderation_owner_current_scope_adoptions s
    JOIN moderation_owner_current_policies p ON p.owner_operator_id=s.target_operator_id AND p.credential_id_sha256=s.target_credential_id_sha256
    JOIN moderation_operator_enrollment_admissions a ON a.enrollment_admission_id=p.enrollment_admission_id AND a.enrollment_request_id=s.enrollment_request_id
    WHERE json_extract(s.transcript_json,'$.target.moderationKeyId')='moderation-v2')
    THEN RAISE(ABORT,'group_report_key_required') END);
END;

CREATE TABLE group_report_daily_usage (
  person_id TEXT NOT NULL REFERENCES group_people(id),
  day_key INTEGER NOT NULL,
  attempts INTEGER NOT NULL CHECK(attempts BETWEEN 1 AND 10),
  PRIMARY KEY(person_id,day_key)
) STRICT;
CREATE TABLE group_reports (
  id TEXT PRIMARY KEY,
  space_id TEXT NOT NULL REFERENCES group_windows(space_id),
  moment_id TEXT NOT NULL,
  reporter_person_id TEXT NOT NULL REFERENCES group_people(id),
  reporter_participant_id TEXT NOT NULL REFERENCES group_members(participant_id),
  reporter_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  accused_participant_id TEXT NOT NULL REFERENCES group_members(participant_id),
  reason_code TEXT NOT NULL CHECK(reason_code IN ('objectionable','harassment','privacy','other')),
  moderation_key_id TEXT NOT NULL CHECK(moderation_key_id='moderation-v2'),
  ciphertext_size INTEGER NOT NULL CHECK(ciphertext_size BETWEEN 29 AND 1048576),
  ciphertext_sha256 TEXT NOT NULL,
  reporter_consent_version INTEGER NOT NULL CHECK(reporter_consent_version=1),
  reporter_consented_at INTEGER NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  dedupe_key TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('reserved','uploaded','committed','expired')),
  created_at INTEGER NOT NULL,
  upload_expires_at INTEGER NOT NULL,
  uploaded_at INTEGER,
  committed_at INTEGER,
  content_expires_at INTEGER,
  expired_at INTEGER,
  CHECK(upload_expires_at=created_at+3600),
  CHECK((committed_at IS NULL AND content_expires_at IS NULL) OR
    (committed_at IS NOT NULL AND content_expires_at IS NOT NULL AND content_expires_at=committed_at+604800)),
  CHECK(state<>'committed' OR committed_at IS NOT NULL),
  CHECK(state<>'uploaded' OR uploaded_at IS NOT NULL),
  CHECK(state<>'expired' OR expired_at IS NOT NULL)
) STRICT;
CREATE UNIQUE INDEX group_reports_one_durable ON group_reports(moment_id,reporter_person_id)
  WHERE state IN ('reserved','uploaded','committed') OR committed_at IS NOT NULL;
CREATE INDEX group_reports_expiry ON group_reports(state,upload_expires_at,content_expires_at);
CREATE INDEX group_reports_person_day ON group_reports(reporter_person_id,created_at);
-- No photo keys, device keys, names, ciphertext descriptors or participant IDs.
CREATE TABLE group_report_tombstones (
  dedupe_key TEXT PRIMARY KEY,
  report_id TEXT NOT NULL UNIQUE,
  committed_at INTEGER NOT NULL
) STRICT;
CREATE TABLE group_report_object_deletions (
  report_id TEXT PRIMARY KEY,
  object_key TEXT NOT NULL UNIQUE,
  attempts INTEGER NOT NULL DEFAULT 0,
  available_at INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','completed'))
) STRICT;
CREATE INDEX group_report_deletions_due ON group_report_object_deletions(state,available_at);

CREATE TRIGGER group_report_reserve BEFORE INSERT ON group_reports
BEGIN
  SELECT (CASE WHEN NEW.state<>'reserved' OR NEW.created_at NOT BETWEEN unixepoch()-300 AND unixepoch()
    OR NEW.reporter_consented_at<unixepoch()-300 OR NEW.reporter_consented_at>unixepoch()+300
    OR NEW.uploaded_at IS NOT NULL OR NEW.committed_at IS NOT NULL OR NEW.expired_at IS NOT NULL
    THEN RAISE(ABORT,'group_report_invalid_reservation') END);
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM group_report_credentials c JOIN group_moment_deliveries d ON d.device_id=c.device_id
    JOIN group_moments m ON m.id=d.moment_id AND m.space_id=c.space_id
    WHERE c.space_id=NEW.space_id AND c.device_id=NEW.reporter_device_id
      AND c.person_id=NEW.reporter_person_id AND c.participant_id=NEW.reporter_participant_id
      AND d.participant_id=c.participant_id AND d.state IN ('pending','acknowledged','expired')
      AND m.id=NEW.moment_id AND m.committed_at IS NOT NULL
      AND m.sender_participant_id=NEW.accused_participant_id AND m.sender_participant_id<>c.participant_id)
    THEN RAISE(ABORT,'group_report_not_delivered') END);
  SELECT (CASE WHEN EXISTS (SELECT 1 FROM group_report_tombstones WHERE dedupe_key=NEW.dedupe_key)
    THEN RAISE(ABORT,'group_report_already_reported') END);
  SELECT (CASE WHEN COALESCE((SELECT attempts FROM group_report_daily_usage
    WHERE person_id=NEW.reporter_person_id AND day_key=unixepoch()/86400),0)>=10
    THEN RAISE(ABORT,'group_report_daily_limit') END);
END;
CREATE TRIGGER group_report_charge AFTER INSERT ON group_reports
BEGIN
  INSERT INTO group_report_daily_usage VALUES (NEW.reporter_person_id,NEW.created_at/86400,1)
    ON CONFLICT(person_id,day_key) DO UPDATE SET attempts=attempts+1;
END;
CREATE TRIGGER group_report_state BEFORE UPDATE ON group_reports
BEGIN
  SELECT (CASE WHEN NEW.id<>OLD.id OR NEW.space_id<>OLD.space_id OR NEW.moment_id<>OLD.moment_id
    OR NEW.reporter_person_id<>OLD.reporter_person_id OR NEW.reporter_participant_id<>OLD.reporter_participant_id
    OR NEW.reporter_device_id<>OLD.reporter_device_id OR NEW.accused_participant_id<>OLD.accused_participant_id
    OR NEW.reason_code<>OLD.reason_code OR NEW.moderation_key_id<>OLD.moderation_key_id
    OR NEW.ciphertext_size<>OLD.ciphertext_size OR NEW.ciphertext_sha256<>OLD.ciphertext_sha256
    OR NEW.reporter_consent_version<>OLD.reporter_consent_version OR NEW.reporter_consented_at<>OLD.reporter_consented_at
    OR NEW.object_key<>OLD.object_key OR NEW.dedupe_key<>OLD.dedupe_key
    OR NEW.created_at<>OLD.created_at OR NEW.upload_expires_at<>OLD.upload_expires_at
    OR (OLD.uploaded_at IS NOT NULL AND NEW.uploaded_at IS NOT OLD.uploaded_at)
    OR (OLD.committed_at IS NOT NULL AND (NEW.committed_at IS NOT OLD.committed_at OR NEW.content_expires_at IS NOT OLD.content_expires_at))
    OR NOT ((OLD.state='reserved' AND NEW.state IN ('uploaded','expired'))
      OR (OLD.state='uploaded' AND NEW.state IN ('committed','expired'))
      OR (OLD.state='committed' AND NEW.state='expired'))
    THEN RAISE(ABORT,'group_report_invalid_transition') END);
  SELECT (CASE WHEN NEW.state IN ('uploaded','committed') AND (NEW.upload_expires_at<=unixepoch()
    OR NOT EXISTS (SELECT 1 FROM group_report_credentials WHERE space_id=NEW.space_id AND device_id=NEW.reporter_device_id))
    THEN RAISE(ABORT,'group_report_not_authorized') END);
  SELECT (CASE WHEN NEW.state='uploaded' AND (NEW.uploaded_at IS NULL OR NEW.uploaded_at NOT BETWEEN unixepoch()-300 AND unixepoch())
    OR NEW.state='committed' AND (NEW.committed_at IS NULL OR NEW.committed_at NOT BETWEEN unixepoch()-300 AND unixepoch())
    OR NEW.state='expired' AND NEW.expired_at IS NULL
    THEN RAISE(ABORT,'group_report_invalid_transition') END);
END;
CREATE TRIGGER group_report_key_insert BEFORE INSERT ON group_reports
WHEN EXISTS(SELECT 1 FROM moderation_owner_scope_installation)
BEGIN
  SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM moderation_owner_current_scope_adoptions s
    JOIN moderation_owner_current_policies p ON p.owner_operator_id=s.target_operator_id AND p.credential_id_sha256=s.target_credential_id_sha256
    JOIN moderation_operator_enrollment_admissions a ON a.enrollment_admission_id=p.enrollment_admission_id AND a.enrollment_request_id=s.enrollment_request_id
    WHERE json_extract(s.transcript_json,'$.target.moderationKeyId')=NEW.moderation_key_id)
    THEN RAISE(ABORT,'group_report_key_required') END);
END;
CREATE TRIGGER group_report_key_update BEFORE UPDATE OF state ON group_reports
WHEN NEW.state IN ('uploaded','committed') AND EXISTS(SELECT 1 FROM moderation_owner_scope_installation)
BEGIN
  SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM moderation_owner_current_scope_adoptions s
    JOIN moderation_owner_current_policies p ON p.owner_operator_id=s.target_operator_id AND p.credential_id_sha256=s.target_credential_id_sha256
    JOIN moderation_operator_enrollment_admissions a ON a.enrollment_admission_id=p.enrollment_admission_id AND a.enrollment_request_id=s.enrollment_request_id
    WHERE json_extract(s.transcript_json,'$.target.moderationKeyId')=NEW.moderation_key_id)
    THEN RAISE(ABORT,'group_report_key_required') END);
END;
CREATE TRIGGER group_report_committed AFTER UPDATE OF state ON group_reports
WHEN NEW.state='committed'
BEGIN
  INSERT INTO group_report_tombstones VALUES (NEW.dedupe_key,NEW.id,NEW.committed_at);
END;
