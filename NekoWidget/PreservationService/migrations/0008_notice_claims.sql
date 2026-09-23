-- A claim is a send reservation, never delivery evidence or deletion authority.
-- One active claim per owner prevents concurrent schedulers from sending twice.
CREATE TABLE pa_notice_claims (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  claim_id TEXT UNIQUE NOT NULL,
  episode INTEGER NOT NULL CHECK (episode > 0),
  due_at INTEGER NOT NULL CHECK (due_at > 0),
  contact_updated_at INTEGER NOT NULL CHECK (contact_updated_at >= 0),
  recipient_tag TEXT NOT NULL CHECK (length(recipient_tag) = 64),
  claimed_at INTEGER NOT NULL CHECK (claimed_at > 0),
  expires_at INTEGER NOT NULL CHECK (expires_at > claimed_at)
);
CREATE INDEX pa_notice_claims_expires ON pa_notice_claims(expires_at);

-- A provider submission consumes its claim at most once, even if two
-- callbacks race before the claim row is cleaned up. Older rows remain NULL.
ALTER TABLE pa_notice_submissions ADD COLUMN claim_id TEXT;
ALTER TABLE pa_notice_submissions ADD COLUMN claim_started_at INTEGER CHECK (claim_started_at >= 0);
ALTER TABLE pa_notice_submissions ADD COLUMN provider_accepted_at INTEGER CHECK (provider_accepted_at >= 0);
CREATE UNIQUE INDEX pa_notice_submissions_claim ON pa_notice_submissions(claim_id);

-- Advance the scan even when an owner has no readable Apple contact.
CREATE TABLE pa_notice_scan_cursor (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  due_at INTEGER NOT NULL DEFAULT 0,
  owner_id TEXT NOT NULL DEFAULT ''
);
INSERT INTO pa_notice_scan_cursor(id,due_at,owner_id) VALUES(1,0,'');

-- Reconciliation must also advance past a permanently ineligible old event.
-- The cursor is advisory: each promotion still verifies owner, contact,
-- membership, episode and the delivery evidence independently.
CREATE TABLE pa_notice_promotion_cursor (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  delivered_at INTEGER NOT NULL DEFAULT 0,
  message_id TEXT NOT NULL DEFAULT ''
);
INSERT INTO pa_notice_promotion_cursor(id,delivered_at,message_id) VALUES(1,0,'');
