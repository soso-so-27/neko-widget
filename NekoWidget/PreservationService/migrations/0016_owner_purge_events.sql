-- Dedicated preservation DB. Metadata-only references to externally verified
-- append-only S3 purge intent events. This creates no fence or deletion path.
-- Old D1 bookmarks can still predate this table; S3 replay must be consulted
-- before any quarantine restore or owner reactivation.
CREATE TABLE pa_owner_purge_events (
  -- Keep the minimum owner identifier after pa_owners (identity data) is
  -- removed. A completed purge must not depend on retaining that row.
  owner_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  stage TEXT NOT NULL CHECK(stage IN ('prepared','aborted','erasing','completed')),
  owner_epoch INTEGER NOT NULL CHECK(owner_epoch >= 0),
  inventory_generation INTEGER NOT NULL CHECK(inventory_generation >= 0),
  retention_episode INTEGER NOT NULL CHECK(retention_episode > 0),
  retention_revision INTEGER NOT NULL CHECK(retention_revision > 0),
  due_at INTEGER NOT NULL CHECK(due_at > 0),
  recorded_at INTEGER NOT NULL CHECK(recorded_at >= due_at),
  manifest_sha256 TEXT CHECK(manifest_sha256 IS NULL OR length(manifest_sha256)=64),
  s3_object_key TEXT NOT NULL UNIQUE,
  s3_version_id TEXT NOT NULL CHECK(length(s3_version_id) > 0 AND s3_version_id <> 'null'),
  s3_sha256 TEXT NOT NULL CHECK(length(s3_sha256)=64),
  s3_bytes INTEGER NOT NULL CHECK(s3_bytes > 0 AND s3_bytes <= 4096),
  PRIMARY KEY(owner_id,intent_id,stage),
  CHECK(s3_object_key='purge/v1/'||owner_id||'/'||intent_id||'/'||stage),
  CHECK((stage IN ('prepared','aborted') AND manifest_sha256 IS NULL)
    OR (stage IN ('erasing','completed') AND manifest_sha256 IS NOT NULL))
);
CREATE INDEX pa_owner_purge_events_owner ON pa_owner_purge_events(owner_id,intent_id);

-- D1 cannot prove S3 contents. Only a caller that has read back the exact
-- S3 version may insert a reference. These guards prevent local ambiguity;
-- restore must independently list and verify every external event again.
CREATE TRIGGER pa_owner_purge_event_owner_required BEFORE INSERT ON pa_owner_purge_events
WHEN NEW.stage='prepared' AND NOT EXISTS(
    SELECT 1 FROM pa_owners o WHERE o.owner_id=NEW.owner_id)
BEGIN SELECT RAISE(ABORT,'PURGE_EVENT_OWNER_MISSING'); END;
CREATE TRIGGER pa_owner_purge_event_prepared_first BEFORE INSERT ON pa_owner_purge_events
WHEN NEW.stage='prepared' AND EXISTS(
    SELECT 1 FROM pa_owner_purge_events e
    WHERE e.owner_id=NEW.owner_id AND e.intent_id=NEW.intent_id)
BEGIN SELECT RAISE(ABORT,'PURGE_EVENT_PREPARED_NOT_FIRST'); END;
CREATE TRIGGER pa_owner_purge_event_requires_prepared BEFORE INSERT ON pa_owner_purge_events
WHEN NEW.stage<>'prepared' AND NOT EXISTS(
    SELECT 1 FROM pa_owner_purge_events p
    WHERE p.owner_id=NEW.owner_id AND p.intent_id=NEW.intent_id AND p.stage='prepared'
      AND p.owner_epoch=NEW.owner_epoch
      AND p.inventory_generation=NEW.inventory_generation
      AND p.retention_episode=NEW.retention_episode
      AND p.retention_revision=NEW.retention_revision AND p.due_at=NEW.due_at
      AND p.recorded_at<=NEW.recorded_at)
BEGIN SELECT RAISE(ABORT,'PURGE_EVENT_PREPARATION_MISSING'); END;
CREATE TRIGGER pa_owner_purge_event_abort_before_erasure BEFORE INSERT ON pa_owner_purge_events
WHEN NEW.stage='aborted' AND EXISTS(
    SELECT 1 FROM pa_owner_purge_events e
    WHERE e.owner_id=NEW.owner_id AND e.intent_id=NEW.intent_id
      AND e.stage IN ('erasing','completed'))
BEGIN SELECT RAISE(ABORT,'PURGE_EVENT_ERASURE_CANNOT_ABORT'); END;
CREATE TRIGGER pa_owner_purge_event_no_erasure_after_abort BEFORE INSERT ON pa_owner_purge_events
WHEN NEW.stage='erasing' AND EXISTS(
    SELECT 1 FROM pa_owner_purge_events e
    WHERE e.owner_id=NEW.owner_id AND e.intent_id=NEW.intent_id AND e.stage='aborted')
BEGIN SELECT RAISE(ABORT,'PURGE_EVENT_ABORTED_CANNOT_ERASE'); END;
CREATE TRIGGER pa_owner_purge_event_requires_erasure BEFORE INSERT ON pa_owner_purge_events
WHEN NEW.stage='completed' AND NOT EXISTS(
    SELECT 1 FROM pa_owner_purge_events e
    WHERE e.owner_id=NEW.owner_id AND e.intent_id=NEW.intent_id AND e.stage='erasing'
      AND e.manifest_sha256=NEW.manifest_sha256
      AND e.recorded_at<=NEW.recorded_at)
BEGIN SELECT RAISE(ABORT,'PURGE_EVENT_ERASURE_MISSING'); END;
CREATE TRIGGER pa_owner_purge_events_immutable_update BEFORE UPDATE ON pa_owner_purge_events
BEGIN SELECT RAISE(ABORT,'PURGE_EVENT_IMMUTABLE'); END;
