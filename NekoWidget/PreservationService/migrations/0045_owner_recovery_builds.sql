-- Resumable derived reconstruction only. A checkpoint never acknowledges an
-- owner and cannot be used by readers as a recovery version.
CREATE TABLE pa_owner_recovery_builds (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES pa_owners(owner_id),
  generation INTEGER NOT NULL CHECK(generation>0),
  inventory_generation INTEGER NOT NULL CHECK(inventory_generation>=0),
  record_sequence INTEGER NOT NULL CHECK(record_sequence>=0),
  record_count INTEGER NOT NULL CHECK(record_count BETWEEN 0 AND 1000000),
  after_id TEXT NOT NULL DEFAULT '',
  processed INTEGER NOT NULL DEFAULT 0 CHECK(processed BETWEEN 0 AND 1000000),
  tree_json TEXT NOT NULL CHECK(length(tree_json)<=4096)
);
