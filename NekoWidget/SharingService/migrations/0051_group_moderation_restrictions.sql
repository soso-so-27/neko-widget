PRAGMA foreign_keys = ON;

-- Additive, default-OFF enforcement. Restrictions do not delete or rewrite
-- photos, memberships, signed rosters, local copies, or other windows.
CREATE TABLE group_moderation_restrictions (
  id TEXT PRIMARY KEY,
  case_reference TEXT NOT NULL CHECK(length(case_reference) BETWEEN 1 AND 128),
  space_id TEXT NOT NULL REFERENCES group_windows(space_id),
  target_kind TEXT NOT NULL CHECK(target_kind IN ('window','person','photo')),
  target_id TEXT NOT NULL,
  active INTEGER NOT NULL CHECK(active IN (0,1)),
  revision INTEGER NOT NULL CHECK(revision>=1),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL CHECK(updated_at>=created_at),
  UNIQUE(case_reference,space_id,target_kind,target_id)
) STRICT;
CREATE INDEX group_moderation_active_targets
  ON group_moderation_restrictions(space_id,target_kind,target_id) WHERE active=1;
CREATE TRIGGER group_moderation_target BEFORE INSERT ON group_moderation_restrictions
BEGIN
  SELECT (CASE WHEN NOT (
    (NEW.target_kind='window' AND NEW.target_id=NEW.space_id)
    OR (NEW.target_kind='person' AND EXISTS (SELECT 1 FROM group_members
      WHERE space_id=NEW.space_id AND person_id=NEW.target_id))
    OR (NEW.target_kind='photo' AND EXISTS (SELECT 1 FROM group_moments
      WHERE space_id=NEW.space_id AND id=NEW.target_id))
  ) THEN RAISE(ABORT,'group_moderation_invalid_target') END);
END;
CREATE TRIGGER group_moderation_revision BEFORE UPDATE ON group_moderation_restrictions
BEGIN
  SELECT (CASE WHEN NEW.id<>OLD.id OR NEW.case_reference<>OLD.case_reference OR NEW.space_id<>OLD.space_id
    OR NEW.target_kind<>OLD.target_kind OR NEW.target_id<>OLD.target_id OR NEW.created_at<>OLD.created_at
    OR NEW.revision<>OLD.revision+1 OR NEW.updated_at<OLD.updated_at
    THEN RAISE(ABORT,'group_moderation_invalid_revision') END);
END;

-- Ephemeral checks run inside the same D1 transaction as the existing media
-- authorization and mutation. Only runtime-ON code inserts these checks.
CREATE TABLE group_moderation_checks (
  id TEXT PRIMARY KEY,
  space_id TEXT NOT NULL,
  sender_person_id TEXT,
  moment_id TEXT,
  actor_person_id TEXT
) STRICT;
CREATE TRIGGER group_moderation_check BEFORE INSERT ON group_moderation_checks
BEGIN
  SELECT (CASE WHEN NEW.moment_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM group_moments WHERE id=NEW.moment_id AND space_id=NEW.space_id
  ) THEN RAISE(ABORT,'group_moderation_restricted') END);
  SELECT (CASE WHEN EXISTS (
    SELECT 1 FROM group_moderation_restrictions r WHERE r.active=1 AND r.space_id=NEW.space_id AND (
      (r.target_kind='window' AND r.target_id=NEW.space_id)
      OR (r.target_kind='photo' AND r.target_id=NEW.moment_id)
      OR (r.target_kind='person' AND (r.target_id=NEW.sender_person_id OR r.target_id=NEW.actor_person_id
        OR r.target_id=(SELECT m.person_id FROM group_moments p JOIN group_members m
          ON m.participant_id=p.sender_participant_id AND m.space_id=p.space_id
          WHERE p.id=NEW.moment_id AND p.space_id=NEW.space_id)))
    )
  ) THEN RAISE(ABORT,'group_moderation_restricted') END);
END;
