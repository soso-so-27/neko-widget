-- Dedicated preservation DB. Submission is NOT proof of delivery or deletion authority.
-- No recipient email is stored in plaintext; recipient_tag is a keyed HMAC.
CREATE TABLE pa_notice_submissions (
  message_id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  episode INTEGER NOT NULL CHECK (episode > 0),
  retention_revision INTEGER NOT NULL CHECK (retention_revision > 0),
  due_at INTEGER NOT NULL CHECK (due_at > 0),
  contact_updated_at INTEGER NOT NULL CHECK (contact_updated_at >= 0),
  recipient_tag TEXT NOT NULL CHECK (length(recipient_tag) = 64),
  account_id TEXT NOT NULL,
  zone_id TEXT NOT NULL,
  subscription_id TEXT NOT NULL,
  domain TEXT NOT NULL,
  sender TEXT NOT NULL,
  submitted_at INTEGER NOT NULL CHECK (submitted_at > 0),
  delivered_at INTEGER CHECK (delivered_at IS NULL OR delivered_at >= submitted_at),
  delivery_event_id TEXT UNIQUE,
  CHECK ((delivered_at IS NULL) = (delivery_event_id IS NULL))
);
CREATE INDEX pa_notice_submissions_owner_episode
  ON pa_notice_submissions(owner_id, episode, submitted_at);
