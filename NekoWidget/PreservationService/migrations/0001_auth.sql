CREATE TABLE pa_owners (
  owner_id TEXT PRIMARY KEY NOT NULL,
  identity_key TEXT NOT NULL UNIQUE,
  epoch INTEGER NOT NULL DEFAULT 0 CHECK (epoch >= 0),
  disabled INTEGER NOT NULL DEFAULT 0 CHECK (disabled IN (0, 1)),
  created_at INTEGER NOT NULL
);

CREATE TABLE pa_identity_credentials (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  owner_epoch INTEGER NOT NULL CHECK (owner_epoch >= 0),
  sealed_credentials BLOB NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE pa_auth_challenges (
  challenge_id TEXT PRIMARY KEY NOT NULL,
  proof_hash TEXT NOT NULL,
  nonce TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL CHECK (expires_at > created_at)
);
CREATE INDEX pa_auth_challenges_expiry ON pa_auth_challenges(expires_at);

CREATE TABLE pa_sessions (
  session_hash TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  owner_epoch INTEGER NOT NULL CHECK (owner_epoch >= 0),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL CHECK (expires_at > created_at)
);
CREATE INDEX pa_sessions_expiry ON pa_sessions(expires_at);
CREATE INDEX pa_sessions_owner ON pa_sessions(owner_id);
