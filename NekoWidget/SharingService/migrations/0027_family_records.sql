-- Independent encrypted records, not delivery receipts or TTL media. No FK
-- cascade to delivery spaces: losing pairing never resurrects or republishes
-- records, and an ended space cannot authorize access to this retained catalog.
CREATE TABLE family_records (
  space_id TEXT NOT NULL,
  id TEXT NOT NULL,
  entry_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('photo', 'words')),
  author_member_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  state TEXT NOT NULL CHECK(state IN ('active', 'withdrawn')),
  key_epoch INTEGER NOT NULL CHECK(key_epoch = 1),
  ciphertext TEXT,
  object_key TEXT,
  ciphertext_size INTEGER NOT NULL,
  payload_hash TEXT NOT NULL,
  last_operation_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(space_id, id),
  CHECK((state = 'withdrawn' AND ciphertext IS NULL AND object_key IS NULL)
     OR (state = 'active' AND kind = 'photo' AND object_key IS NOT NULL AND ciphertext IS NULL)
     OR (state = 'active' AND kind = 'words' AND ciphertext IS NOT NULL AND object_key IS NULL))
);
CREATE INDEX family_records_entry ON family_records(space_id, entry_id, created_at);
CREATE TABLE family_record_object_deletions (
  object_key TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL
);
