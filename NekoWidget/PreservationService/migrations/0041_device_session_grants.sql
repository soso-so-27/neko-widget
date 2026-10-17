-- Access tokens remain 15 minutes. Device grants require a fresh, one-use
-- ES256 proof and expire after 30 days of inactivity. They are never recovery data.
ALTER TABLE pa_auth_challenges ADD COLUMN device_binding TEXT;
CREATE TABLE pa_device_session_grants (
  grant_id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  owner_epoch INTEGER NOT NULL CHECK(owner_epoch>=0),
  device_binding TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  idle_expires_at INTEGER NOT NULL CHECK(idle_expires_at>created_at),
  revoked_at INTEGER
);
CREATE INDEX pa_device_session_grants_owner ON pa_device_session_grants(owner_id);
CREATE INDEX pa_device_session_grants_expiry ON pa_device_session_grants(idle_expires_at);
ALTER TABLE pa_sessions ADD COLUMN device_grant_id TEXT REFERENCES pa_device_session_grants(grant_id) ON DELETE RESTRICT;
CREATE INDEX pa_sessions_device_grant ON pa_sessions(device_grant_id);
CREATE TABLE pa_device_session_challenges (
  challenge_id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  grant_id TEXT NOT NULL REFERENCES pa_device_session_grants(grant_id) ON DELETE RESTRICT,
  purpose TEXT NOT NULL CHECK(purpose IN ('renew','revoke')),
  nonce TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL CHECK(expires_at>created_at),
  consumed_by TEXT,
  UNIQUE(grant_id,purpose)
);
CREATE INDEX pa_device_session_challenges_expiry ON pa_device_session_challenges(expires_at);
CREATE INDEX pa_device_session_challenges_owner ON pa_device_session_challenges(owner_id);
CREATE TABLE pa_device_identity_checks (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  owner_epoch INTEGER NOT NULL,
  credential_hash TEXT NOT NULL,
  credential_updated_at INTEGER NOT NULL,
  verified_at INTEGER NOT NULL,
  attempt_after INTEGER NOT NULL,
  lease_id TEXT
);

-- This also covers deletion fencing, purge abort/re-enabling and other owner
-- epoch changes. No old device authority survives a restored/re-enabled owner.
CREATE TRIGGER pa_device_grants_owner_invalidation AFTER UPDATE OF identity_key,epoch,disabled ON pa_owners
WHEN NEW.identity_key<>OLD.identity_key OR NEW.epoch<>OLD.epoch OR NEW.disabled<>OLD.disabled
BEGIN
  UPDATE pa_device_session_grants SET revoked_at=COALESCE(revoked_at,0) WHERE owner_id=NEW.owner_id;
  DELETE FROM pa_sessions WHERE owner_id=NEW.owner_id;
  DELETE FROM pa_device_session_challenges WHERE owner_id=NEW.owner_id;
  DELETE FROM pa_device_identity_checks WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_device_grant_revocation AFTER UPDATE OF revoked_at ON pa_device_session_grants
WHEN NEW.revoked_at IS NOT NULL
BEGIN
  DELETE FROM pa_sessions WHERE device_grant_id=NEW.grant_id;
END;
