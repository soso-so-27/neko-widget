-- Opt-in registrations only. This migration does not enable delivery.
CREATE TABLE family_push_subscriptions (
  space_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
  device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  token_ciphertext TEXT NOT NULL, token_nonce TEXT NOT NULL, token_digest TEXT NOT NULL,
  encryption_key_id TEXT NOT NULL, environment TEXT NOT NULL CHECK(environment IN ('production','development')),
  generation INTEGER NOT NULL CHECK(generation>0), expires_at INTEGER NOT NULL,
  PRIMARY KEY(space_id,device_id)
) STRICT;
CREATE INDEX family_push_token ON family_push_subscriptions(token_digest);
CREATE TABLE family_notification_deliveries (
  event_id TEXT NOT NULL, device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  token_digest TEXT NOT NULL, subscription_generation INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','leased','accepted','skipped','invalid')),
  available_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
  lease_id TEXT, lease_expires_at INTEGER,
  PRIMARY KEY(event_id,device_id)
) STRICT;
CREATE INDEX family_notification_pending ON family_notification_deliveries(state,available_at);

CREATE TRIGGER family_push_registration_guard BEFORE INSERT ON family_push_subscriptions
WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
  OR NOT EXISTS(SELECT 1 FROM family_notebook_spaces f
    JOIN group_person_devices d ON d.id=NEW.device_id AND d.state='active'
    JOIN group_people p ON p.id=d.person_id AND p.state='active'
    WHERE f.id=NEW.space_id AND f.state='active' AND (
      EXISTS(SELECT 1 FROM family_notebook_members m WHERE m.family_id=f.id AND m.person_id=p.id AND m.state='active')
      OR EXISTS(SELECT 1 FROM family_notebook_join_requests j WHERE j.family_id=f.id AND j.device_id=d.id
        AND j.person_id=p.id AND j.state='pending' AND j.expires_at>unixepoch())))
BEGIN SELECT RAISE(ABORT,'family_notification_not_allowed'); END;

-- The event is derived from committed admission receipts, never a client claim.
-- A stable family/kind/two-minute bucket coalesces recipients across requests.
CREATE VIEW family_notification_recipients AS
SELECT f.id||':'||e.operation||':'||CAST(e.recorded_at/120 AS INTEGER) AS event_id,
  f.id AS space_id, s.device_id,
  (CASE e.operation WHEN 'join' THEN 'join_requested' ELSE 'join_approved' END) AS kind,
  s.token_ciphertext,s.token_nonce,s.token_digest,s.encryption_key_id,s.environment,
  s.generation AS subscription_generation,
  MIN(s.expires_at,MAX(e.recorded_at)+86400) AS expires_at,
  (CAST(e.recorded_at/120 AS INTEGER)+2)*120 AS available_at
FROM family_notebook_admission_events e
JOIN family_notebook_join_requests j ON j.id=e.join_id AND j.family_id=e.family_id
JOIN family_notebook_invitations i ON i.id=j.invitation_id
JOIN family_notebook_spaces f ON f.id=e.family_id AND f.state='active'
JOIN family_push_subscriptions s ON s.space_id=f.id AND s.expires_at>unixepoch() AND s.token_ciphertext<>''
JOIN group_person_devices d ON d.id=s.device_id AND d.state='active'
JOIN group_people p ON p.id=d.person_id AND p.state='active'
JOIN family_notebook_members m ON m.family_id=f.id AND m.person_id=p.id AND m.state='active'
JOIN group_people applicant ON applicant.id=j.person_id AND applicant.state='active'
JOIN group_person_devices applicant_device ON applicant_device.id=j.device_id AND applicant_device.state='active'
WHERE e.operation IN ('join','approve') AND e.recorded_at+86400>unixepoch()
  AND ((e.operation='join' AND j.state='pending' AND j.expires_at>unixepoch() AND i.state='used'
        AND (p.id=i.creator_person_id OR p.id=f.payer_person_id)
        AND EXISTS(SELECT 1 FROM family_notebook_members im JOIN group_person_devices id ON id.id=i.creator_device_id AND id.state='active'
          WHERE im.family_id=f.id AND im.person_id=i.creator_person_id AND im.state='active'))
    OR (e.operation='approve' AND j.state='approved' AND p.id=j.person_id AND d.id=j.device_id))
GROUP BY f.id,e.operation,CAST(e.recorded_at/120 AS INTEGER),s.device_id;

CREATE VIEW family_live_notification_deliveries AS
SELECT v.* FROM family_notification_recipients v
JOIN family_notification_deliveries q ON q.event_id=v.event_id AND q.device_id=v.device_id
  AND q.token_digest=v.token_digest AND q.subscription_generation=v.subscription_generation;

-- Identity erasure also clears tokens and delivery identifiers. No retained
-- signed notebook history is modified by this notification-only cleanup.
CREATE TRIGGER family_push_device_revoked AFTER UPDATE OF state ON group_person_devices
WHEN NEW.state<>'active'
BEGIN
  UPDATE family_push_subscriptions SET generation=generation+1,expires_at=0,
    token_ciphertext='',token_nonce='',token_digest='' WHERE device_id=NEW.id;
  DELETE FROM family_notification_deliveries WHERE device_id=NEW.id;
END;

-- A physical token must not continue receiving the previous identity's alerts.
CREATE TRIGGER family_push_token_insert AFTER INSERT ON family_push_subscriptions
WHEN NEW.token_digest<>'' AND NEW.expires_at>unixepoch()
BEGIN
  UPDATE family_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest=''
    WHERE token_digest=NEW.token_digest AND device_id<>NEW.device_id;
  UPDATE group_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest=''
    WHERE token_digest=NEW.token_digest AND device_id<>NEW.device_id;
  UPDATE group_join_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest=''
    WHERE token_digest=NEW.token_digest AND device_id<>NEW.device_id;
END;
CREATE TRIGGER family_push_token_update AFTER UPDATE OF token_digest ON family_push_subscriptions
WHEN NEW.token_digest<>'' AND NEW.expires_at>unixepoch()
BEGIN
  UPDATE family_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest=''
    WHERE token_digest=NEW.token_digest AND device_id<>NEW.device_id;
  UPDATE group_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest=''
    WHERE token_digest=NEW.token_digest AND device_id<>NEW.device_id;
  UPDATE group_join_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest=''
    WHERE token_digest=NEW.token_digest AND device_id<>NEW.device_id;
END;
CREATE TRIGGER group_push_clears_old_family_insert AFTER INSERT ON group_push_subscriptions
WHEN NEW.token_digest<>'' AND NEW.expires_at>unixepoch()
BEGIN UPDATE family_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest=''
  WHERE token_digest=NEW.token_digest AND device_id<>NEW.device_id; END;
CREATE TRIGGER group_push_clears_old_family_update AFTER UPDATE OF token_digest ON group_push_subscriptions
WHEN NEW.token_digest<>'' AND NEW.expires_at>unixepoch()
BEGIN UPDATE family_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest=''
  WHERE token_digest=NEW.token_digest AND device_id<>NEW.device_id; END;
CREATE TRIGGER group_join_push_clears_old_family_insert AFTER INSERT ON group_join_push_subscriptions
WHEN NEW.token_digest<>'' AND NEW.expires_at>unixepoch()
BEGIN UPDATE family_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest=''
  WHERE token_digest=NEW.token_digest AND device_id<>NEW.device_id; END;
CREATE TRIGGER group_join_push_clears_old_family_update AFTER UPDATE OF token_digest ON group_join_push_subscriptions
WHEN NEW.token_digest<>'' AND NEW.expires_at>unixepoch()
BEGIN UPDATE family_push_subscriptions SET expires_at=0,generation=generation+1,token_ciphertext='',token_nonce='',token_digest=''
  WHERE token_digest=NEW.token_digest AND device_id<>NEW.device_id; END;
