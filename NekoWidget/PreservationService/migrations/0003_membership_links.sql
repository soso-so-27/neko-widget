-- Dedicated preservation DB only. Never run this migration against billing DB.
CREATE TABLE pa_membership_links (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  billing_account_id TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);
-- Relinking needs a separately reviewed recovery procedure. Expiry, sign-out,
-- purchase-key rotation and owner revocation must not reassign another archive.
CREATE TRIGGER pa_membership_links_no_update BEFORE UPDATE ON pa_membership_links
BEGIN SELECT RAISE(ABORT, 'membership link is immutable'); END;
CREATE TRIGGER pa_membership_links_no_delete BEFORE DELETE ON pa_membership_links
BEGIN SELECT RAISE(ABORT, 'membership link is retained'); END;
CREATE TABLE pa_membership_challenges (
  challenge_id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  session_hash TEXT NOT NULL REFERENCES pa_sessions(session_hash) ON DELETE CASCADE,
  billing_account_id TEXT NOT NULL,
  audience TEXT NOT NULL,
  issued_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL CHECK (expires_at > issued_at)
);
CREATE INDEX pa_membership_challenges_expiry ON pa_membership_challenges(expires_at);
CREATE INDEX pa_membership_challenges_session ON pa_membership_challenges(session_hash);
