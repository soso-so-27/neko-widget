PRAGMA foreign_keys = ON;

-- Additive preparation. No existing notebook requires the new contract yet.
CREATE TABLE family_notebook_write_policy (
 family_id TEXT PRIMARY KEY REFERENCES family_notebook_spaces(id),
 required_version INTEGER NOT NULL CHECK(required_version>=1)
) STRICT;
CREATE TABLE family_notebook_write_checks (
 id TEXT PRIMARY KEY,
 family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
 version INTEGER NOT NULL CHECK(version>=0)
) STRICT;
CREATE TRIGGER family_notebook_write_check BEFORE INSERT ON family_notebook_write_checks
BEGIN
 SELECT (CASE WHEN NEW.version<COALESCE((SELECT required_version FROM family_notebook_write_policy WHERE family_id=NEW.family_id),0)
 THEN RAISE(ABORT,'photo_protocol_upgrade_required') END);
END;

CREATE TABLE family_representative_slots (
 family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
 slot_id TEXT NOT NULL,
 revision INTEGER NOT NULL DEFAULT 0,
 asset_id TEXT,
 state TEXT NOT NULL CHECK(state IN ('active','retired')),
 PRIMARY KEY(family_id,slot_id)
) STRICT;
CREATE TABLE family_representative_assets (
 asset_id TEXT PRIMARY KEY,
 family_id TEXT NOT NULL,
 slot_id TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 person_id TEXT NOT NULL,
 device_id TEXT NOT NULL,
 revision INTEGER NOT NULL,
 key_epoch INTEGER NOT NULL,
 roster_hash TEXT NOT NULL,
 object_key TEXT NOT NULL UNIQUE,
 bytes INTEGER NOT NULL CHECK(bytes BETWEEN 29 AND 200028),
 hash TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('reserved','uploaded','active','retired','deleted')),
 created_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL,
 request_hash TEXT NOT NULL,
 UNIQUE(family_id,operation_id),
 FOREIGN KEY(family_id,slot_id) REFERENCES family_representative_slots(family_id,slot_id)
) STRICT;
CREATE TABLE family_representative_daily_usage (
 family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
 day INTEGER NOT NULL,
 uploads INTEGER NOT NULL,
 PRIMARY KEY(family_id,day)
) STRICT;
CREATE INDEX family_representative_cleanup ON family_representative_assets(state,expires_at);
CREATE TRIGGER family_representative_slot_limit BEFORE INSERT ON family_representative_slots
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_representative_slots WHERE family_id=NEW.family_id AND slot_id=NEW.slot_id) AND (SELECT COUNT(*) FROM family_representative_slots WHERE family_id=NEW.family_id AND state='active')>=10
 THEN RAISE(ABORT,'photo_slots_full') END);
END;
CREATE TRIGGER family_representative_asset_limit BEFORE INSERT ON family_representative_assets
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_representative_slots WHERE family_id=NEW.family_id AND slot_id=NEW.slot_id AND state='active' AND revision=NEW.revision-1)
 THEN RAISE(ABORT,'revision_conflict') END);
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM family_representative_assets WHERE family_id=NEW.family_id AND slot_id=NEW.slot_id AND state IN ('reserved','uploaded','retired'))
 THEN RAISE(ABORT,'photo_cleanup_pending') END);
 SELECT (CASE WHEN COALESCE((SELECT uploads FROM family_representative_daily_usage WHERE family_id=NEW.family_id AND day=(NEW.created_at+32400)/86400),0)>=20
 THEN RAISE(ABORT,'photo_daily_limit') END);
END;
CREATE TRIGGER family_representative_asset_count AFTER INSERT ON family_representative_assets
BEGIN
 INSERT INTO family_representative_daily_usage VALUES(NEW.family_id,(NEW.created_at+32400)/86400,1)
 ON CONFLICT(family_id,day) DO UPDATE SET uploads=uploads+1;
END;

CREATE TABLE family_representative_commit_checks (
 id TEXT PRIMARY KEY,
 family_id TEXT NOT NULL,
 slot_id TEXT NOT NULL,
 asset_id TEXT NOT NULL,
 expected_revision INTEGER NOT NULL,
 mode TEXT NOT NULL CHECK(mode IN ('upload','commit'))
) STRICT;
CREATE TRIGGER family_representative_commit_validate BEFORE INSERT ON family_representative_commit_checks
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_representative_slots s JOIN family_representative_assets a ON a.family_id=s.family_id AND a.slot_id=s.slot_id
 WHERE s.family_id=NEW.family_id AND s.slot_id=NEW.slot_id AND s.state='active' AND s.revision=NEW.expected_revision
 AND a.asset_id=NEW.asset_id AND a.revision=NEW.expected_revision+1 AND a.expires_at>unixepoch()
 AND ((NEW.mode='upload' AND a.state IN ('reserved','uploaded')) OR (NEW.mode='commit' AND a.state='uploaded')))
 THEN RAISE(ABORT,'revision_conflict') END);
 SELECT (CASE WHEN COALESCE((SELECT required_version FROM family_notebook_write_policy WHERE family_id=NEW.family_id),0)>1
 THEN RAISE(ABORT,'photo_protocol_upgrade_required') END);
END;
