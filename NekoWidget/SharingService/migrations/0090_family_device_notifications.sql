-- Only new, committed device registrations enqueue wake-ups. No backfill.
CREATE TABLE family_device_notification_events (
  family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id) ON DELETE CASCADE,
  source_device_id TEXT NOT NULL REFERENCES group_person_devices(id) ON DELETE CASCADE,
  recipient_device_id TEXT NOT NULL REFERENCES group_person_devices(id) ON DELETE CASCADE,
  recorded_at INTEGER NOT NULL,
  PRIMARY KEY(family_id,source_device_id,recipient_device_id),
  CHECK(source_device_id<>recipient_device_id)
) STRICT;
CREATE INDEX family_device_notification_expiry ON family_device_notification_events(recorded_at);

CREATE VIEW family_notification_candidates AS
SELECT * FROM family_notification_recipients
UNION ALL
SELECT e.family_id||':device_registered:'||CAST(e.recorded_at/120 AS INTEGER),
  e.family_id,s.device_id,'device_registered',
  s.token_ciphertext,s.token_nonce,s.token_digest,s.encryption_key_id,s.environment,s.generation,
  MIN(s.expires_at,MAX(e.recorded_at)+86400),MIN(e.recorded_at)
FROM family_device_notification_events e
JOIN family_notebook_spaces f ON f.id=e.family_id AND f.state='active'
JOIN family_notebook_crypto_live_devices source ON source.family_id=e.family_id AND source.device_id=e.source_device_id
JOIN family_notebook_crypto_live_devices recipient ON recipient.family_id=e.family_id AND recipient.device_id=e.recipient_device_id
JOIN family_push_subscriptions s ON s.space_id=e.family_id AND s.device_id=e.recipient_device_id
  AND s.expires_at>unixepoch() AND s.token_ciphertext<>''
WHERE e.recorded_at>unixepoch()-86400
GROUP BY e.family_id,CAST(e.recorded_at/120 AS INTEGER),s.device_id;
