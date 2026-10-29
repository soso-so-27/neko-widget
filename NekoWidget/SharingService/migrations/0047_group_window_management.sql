PRAGMA foreign_keys = ON;

-- Additive management state only. No flags, existing photos, keys, members or
-- billing rows are changed by applying this migration. Owner approval required.
CREATE TABLE group_window_names (
  space_id TEXT PRIMARY KEY REFERENCES group_windows(space_id),
  name_revision INTEGER NOT NULL CHECK(name_revision>0),
  roster_revision INTEGER NOT NULL,
  key_epoch INTEGER NOT NULL,
  roster_hash TEXT NOT NULL,
  encrypted_name TEXT NOT NULL,
  signer_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  operation_id TEXT NOT NULL,
  signature TEXT NOT NULL,
  updated_at INTEGER NOT NULL
) STRICT;
CREATE TRIGGER group_name_insert BEFORE INSERT ON group_window_names
BEGIN
  SELECT (CASE WHEN NEW.name_revision<>COALESCE((SELECT (CASE WHEN key_epoch=NEW.key_epoch AND roster_revision=NEW.roster_revision
    THEN name_revision ELSE 0 END) FROM group_window_names WHERE space_id=NEW.space_id),0)+1
    THEN RAISE(ABORT,'group_name_stale_revision') END);
  SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_windows WHERE space_id=NEW.space_id AND mode='active'
    AND rotation_required=0 AND revision=NEW.roster_revision AND key_epoch=NEW.key_epoch AND roster_hash=NEW.roster_hash)
    THEN RAISE(ABORT,'group_stale_revision_or_epoch') END);
END;
CREATE TRIGGER group_name_update BEFORE UPDATE ON group_window_names
BEGIN
  SELECT (CASE WHEN NEW.space_id<>OLD.space_id OR NEW.name_revision<>(CASE WHEN OLD.key_epoch=NEW.key_epoch AND OLD.roster_revision=NEW.roster_revision
    THEN OLD.name_revision ELSE 0 END)+1 THEN RAISE(ABORT,'group_name_stale_revision') END);
  SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_windows WHERE space_id=NEW.space_id AND mode='active'
    AND rotation_required=0 AND revision=NEW.roster_revision AND key_epoch=NEW.key_epoch AND roster_hash=NEW.roster_hash)
    THEN RAISE(ABORT,'group_stale_revision_or_epoch') END);
END;
-- One terminal receipt, not a history of member activity or photograph content.
CREATE TABLE group_window_closures (
  space_id TEXT PRIMARY KEY REFERENCES group_windows(space_id),
  actor_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  operation_id TEXT NOT NULL,
  roster_revision INTEGER NOT NULL,
  key_epoch INTEGER NOT NULL,
  signature TEXT NOT NULL,
  closed_at INTEGER NOT NULL
) STRICT;
