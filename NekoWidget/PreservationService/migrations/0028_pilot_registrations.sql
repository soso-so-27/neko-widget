-- Operator-approved enrollment only; Apple identity HMAC, no tokens or raw subject.
CREATE TABLE pa_pilot_registrations (
  identity_key TEXT PRIMARY KEY CHECK(length(identity_key)=64),
  reference TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL CHECK(created_at>=0),
  expires_at INTEGER NOT NULL CHECK(expires_at>created_at AND expires_at<=created_at+600000)
);
