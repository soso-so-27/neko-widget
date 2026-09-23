-- Dedicated preservation DB. Apple-verified address is sealed with an owner-bound contact context.
-- An absent address never authorizes delivery or deletion.
CREATE TABLE pa_notice_contacts (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  sealed_email BLOB NOT NULL,
  source TEXT NOT NULL CHECK (source = 'apple'),
  verified_at INTEGER NOT NULL CHECK (verified_at >= 0),
  updated_at INTEGER NOT NULL CHECK (updated_at >= verified_at)
);
