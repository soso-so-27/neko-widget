-- Only photos atomically created by a v2 moment commit are linked. Existing
-- delivery history and independently added family records are not migrated.
-- Keep the mapping after delivery media expires so a later photo withdrawal
-- cannot guess or revive an old delivery.
CREATE TABLE family_record_moments (
  space_id TEXT NOT NULL,
  photo_id TEXT NOT NULL,
  moment_id TEXT NOT NULL UNIQUE,
  PRIMARY KEY(space_id, photo_id)
) STRICT;

-- A linked record inherits only the delivery's actual audience at commit.
-- Delivery history can expire, so keep this snapshot with the record.
-- Existing independently added records have no link and retain room access.
CREATE TABLE family_record_moment_readers (
  space_id TEXT NOT NULL,
  photo_id TEXT NOT NULL,
  participant_id TEXT NOT NULL,
  PRIMARY KEY(space_id, photo_id, participant_id)
) STRICT;

-- R2 is not transactional with D1. A staged object is never readable through
-- the family-record API. Successful commit removes this row in the same D1
-- batch as photo publication; ambiguous failures wait for deferred cleanup.
CREATE TABLE family_record_staged_objects (
  object_key TEXT PRIMARY KEY,
  space_id TEXT NOT NULL,
  photo_id TEXT NOT NULL,
  created_at INTEGER NOT NULL
) STRICT;
CREATE INDEX family_record_staged_objects_age ON family_record_staged_objects(created_at);
