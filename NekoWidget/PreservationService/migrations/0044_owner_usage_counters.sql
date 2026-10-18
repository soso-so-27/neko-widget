-- Exact derived usage counters. The legacy exemption and current-revision ACK
-- predicate are unchanged; every contributing table updates the same transaction.
ALTER TABLE pa_owner_record_counters ADD COLUMN live_count INTEGER NOT NULL DEFAULT 0 CHECK(live_count>=0);
ALTER TABLE pa_owner_record_counters ADD COLUMN record_bytes INTEGER NOT NULL DEFAULT 0 CHECK(record_bytes>=0);
ALTER TABLE pa_owner_record_counters ADD COLUMN pending_ack INTEGER NOT NULL DEFAULT 0 CHECK(pending_ack>=0);
ALTER TABLE pa_owner_record_counters ADD COLUMN accounting_valid INTEGER NOT NULL DEFAULT 1 CHECK(accounting_valid IN (0,1));
ALTER TABLE pa_owner_record_changes ADD COLUMN ack_pending INTEGER NOT NULL DEFAULT 0 CHECK(ack_pending IN (0,1));
UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=pa_owner_record_changes.owner_id AND r.record_id=pa_owner_record_changes.record_id),0);
UPDATE pa_owner_record_counters SET
  live_count=(SELECT count(*) FROM pa_records r WHERE r.owner_id=pa_owner_record_counters.owner_id AND r.deleted=0),
  record_bytes=(SELECT coalesce(sum(quota_bytes),0) FROM pa_records r WHERE r.owner_id=pa_owner_record_counters.owner_id),
  pending_ack=(SELECT coalesce(sum(ack_pending),0) FROM pa_owner_record_changes c WHERE c.owner_id=pa_owner_record_counters.owner_id);
CREATE TRIGGER pa_owner_ack_insert AFTER INSERT ON pa_owner_record_changes BEGIN
  UPDATE pa_owner_record_counters SET pending_ack=pending_ack+NEW.ack_pending WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_owner_ack_update AFTER UPDATE OF ack_pending ON pa_owner_record_changes BEGIN
  UPDATE pa_owner_record_counters SET pending_ack=pending_ack+NEW.ack_pending-OLD.ack_pending WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_owner_ack_delete AFTER DELETE ON pa_owner_record_changes BEGIN
  UPDATE pa_owner_record_counters SET pending_ack=pending_ack-OLD.ack_pending WHERE owner_id=OLD.owner_id;
  -- An offline repair may remove acceleration state. It must not turn a lost
  -- ACK row into fabricated free capacity or a successful recovery status.
  UPDATE pa_owner_record_counters SET accounting_valid=0 WHERE owner_id=OLD.owner_id
    AND EXISTS(SELECT 1 FROM pa_records WHERE owner_id=OLD.owner_id AND record_id=OLD.record_id);
END;
DROP TRIGGER pa_owner_record_change_insert;
CREATE TRIGGER pa_owner_record_change_insert AFTER INSERT ON pa_records BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_owner_record_counters WHERE owner_id=NEW.owner_id)
    THEN RAISE(ABORT,'OWNER_RECORD_COUNTER_MISSING') END;
  UPDATE pa_owner_record_counters SET sequence=sequence+1,record_count=record_count+1,live_count=live_count+(1-NEW.deleted),
    record_bytes=record_bytes+(NEW.quota_bytes) WHERE owner_id=NEW.owner_id;
  INSERT INTO pa_owner_record_changes(owner_id,record_id,sequence,ack_pending)
    SELECT NEW.owner_id,NEW.record_id,sequence,coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=NEW.owner_id AND r.record_id=NEW.record_id),0) FROM pa_owner_record_counters WHERE owner_id=NEW.owner_id
    ON CONFLICT(owner_id,record_id) DO UPDATE SET sequence=excluded.sequence,ack_pending=excluded.ack_pending;
END;
DROP TRIGGER pa_owner_record_change_update;
CREATE TRIGGER pa_owner_record_change_update AFTER UPDATE ON pa_records BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_owner_record_counters WHERE owner_id=NEW.owner_id)
    THEN RAISE(ABORT,'OWNER_RECORD_COUNTER_MISSING') END;
  UPDATE pa_owner_record_counters SET sequence=sequence+1,live_count=live_count+(OLD.deleted-NEW.deleted),
    record_bytes=record_bytes+(NEW.quota_bytes-OLD.quota_bytes) WHERE owner_id=NEW.owner_id;
  INSERT INTO pa_owner_record_changes(owner_id,record_id,sequence,ack_pending)
    SELECT NEW.owner_id,NEW.record_id,sequence,coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=NEW.owner_id AND r.record_id=NEW.record_id),0) FROM pa_owner_record_counters WHERE owner_id=NEW.owner_id
    ON CONFLICT(owner_id,record_id) DO UPDATE SET sequence=excluded.sequence,ack_pending=excluded.ack_pending;
END;
DROP TRIGGER pa_owner_record_change_delete;
CREATE TRIGGER pa_owner_record_change_delete AFTER DELETE ON pa_records BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_owner_record_counters WHERE owner_id=OLD.owner_id)
    THEN RAISE(ABORT,'OWNER_RECORD_COUNTER_MISSING') END;
  UPDATE pa_owner_record_counters SET sequence=sequence+1,record_count=record_count-1,live_count=live_count+(-(1-OLD.deleted)),
    record_bytes=record_bytes+(-OLD.quota_bytes) WHERE owner_id=OLD.owner_id;
  INSERT INTO pa_owner_record_changes(owner_id,record_id,sequence,ack_pending)
    SELECT OLD.owner_id,OLD.record_id,sequence,coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=OLD.owner_id AND r.record_id=OLD.record_id),0) FROM pa_owner_record_counters WHERE owner_id=OLD.owner_id
    ON CONFLICT(owner_id,record_id) DO UPDATE SET sequence=excluded.sequence,ack_pending=excluded.ack_pending;
END;
CREATE TRIGGER pa_owner_ack_marker_insert AFTER INSERT ON pa_record_commit_markers BEGIN
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=NEW.owner_id AND r.record_id=NEW.record_id),0) WHERE owner_id=NEW.owner_id AND record_id=NEW.record_id;
END;
CREATE TRIGGER pa_owner_ack_marker_update AFTER UPDATE ON pa_record_commit_markers BEGIN
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=OLD.owner_id AND r.record_id=OLD.record_id),0) WHERE owner_id=OLD.owner_id AND record_id=OLD.record_id;
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=NEW.owner_id AND r.record_id=NEW.record_id),0) WHERE owner_id=NEW.owner_id AND record_id=NEW.record_id;
END;
CREATE TRIGGER pa_owner_ack_marker_delete AFTER DELETE ON pa_record_commit_markers BEGIN
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=OLD.owner_id AND r.record_id=OLD.record_id),0) WHERE owner_id=OLD.owner_id AND record_id=OLD.record_id;
END;
CREATE TRIGGER pa_owner_ack_version_insert AFTER INSERT ON pa_record_recovery_versions BEGIN
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=NEW.owner_id AND r.record_id=NEW.record_id),0) WHERE owner_id=NEW.owner_id AND record_id=NEW.record_id;
END;
CREATE TRIGGER pa_owner_ack_version_update AFTER UPDATE ON pa_record_recovery_versions BEGIN
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=OLD.owner_id AND r.record_id=OLD.record_id),0) WHERE owner_id=OLD.owner_id AND record_id=OLD.record_id;
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=NEW.owner_id AND r.record_id=NEW.record_id),0) WHERE owner_id=NEW.owner_id AND record_id=NEW.record_id;
END;
CREATE TRIGGER pa_owner_ack_version_delete AFTER DELETE ON pa_record_recovery_versions BEGIN
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=OLD.owner_id AND r.record_id=OLD.record_id),0) WHERE owner_id=OLD.owner_id AND record_id=OLD.record_id;
END;
CREATE TRIGGER pa_owner_ack_legacy_insert AFTER INSERT ON pa_record_legacy_baseline BEGIN
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=NEW.owner_id AND r.record_id=NEW.record_id),0) WHERE owner_id=NEW.owner_id AND record_id=NEW.record_id;
END;
CREATE TRIGGER pa_owner_ack_legacy_update AFTER UPDATE ON pa_record_legacy_baseline BEGIN
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=OLD.owner_id AND r.record_id=OLD.record_id),0) WHERE owner_id=OLD.owner_id AND record_id=OLD.record_id;
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=NEW.owner_id AND r.record_id=NEW.record_id),0) WHERE owner_id=NEW.owner_id AND record_id=NEW.record_id;
END;
CREATE TRIGGER pa_owner_ack_legacy_delete AFTER DELETE ON pa_record_legacy_baseline BEGIN
  UPDATE pa_owner_record_changes SET ack_pending=coalesce((SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM pa_record_commit_markers m WHERE m.owner_id=r.owner_id AND m.record_id=r.record_id AND m.revision=r.revision)
    AND (EXISTS(SELECT 1 FROM pa_record_recovery_versions v WHERE v.owner_id=r.owner_id AND v.record_id=r.record_id AND v.revision=r.revision)
      OR NOT EXISTS(SELECT 1 FROM pa_record_legacy_baseline b WHERE b.owner_id=r.owner_id AND b.record_id=r.record_id AND b.revision=r.revision
        AND b.initial_operation=r.initial_operation AND b.initial_fingerprint=r.initial_fingerprint AND b.photo_key IS r.photo_key
        AND b.photo_bytes=r.photo_bytes AND b.quota_bytes=r.quota_bytes AND b.deleted=r.deleted)) THEN 1 ELSE 0 END FROM pa_records r WHERE r.owner_id=OLD.owner_id AND r.record_id=OLD.record_id),0) WHERE owner_id=OLD.owner_id AND record_id=OLD.record_id;
END;
