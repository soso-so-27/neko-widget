PRAGMA foreign_keys = ON;

-- Keep this migration LF-only; Wrangler remote trigger parsing rejects CRLF.
-- One physical iPhone receives one APNs token for this app, but it may hold a
-- different signed device credential for every private window. Token identity
-- is therefore not globally unique; device_id remains the subscription owner.

DROP TRIGGER apns_subscriptions_require_current_active_device;
DROP TRIGGER apns_subscriptions_require_current_active_device_update;
DROP TRIGGER apns_subscriptions_refresh_pending_deliveries;
DROP TRIGGER apns_subscriptions_delete_on_device_close;
DROP TRIGGER notification_events_create_deliveries;
DROP TRIGGER apns_notifications_delete_on_participant_close;
DROP TRIGGER apns_notifications_delete_on_space_close;

ALTER TABLE apns_subscriptions RENAME TO apns_subscriptions_single_token;

CREATE TABLE apns_subscriptions (
    device_id TEXT PRIMARY KEY
        REFERENCES moment_devices(id) ON DELETE CASCADE,
    participant_id TEXT NOT NULL
        REFERENCES moment_participants(id) ON DELETE CASCADE,
    environment TEXT NOT NULL
        CHECK (environment IN ('development', 'production')),
    token_ciphertext TEXT NOT NULL,
    token_nonce TEXT NOT NULL,
    token_digest TEXT NOT NULL,
    encryption_key_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    CHECK (updated_at >= created_at),
    CHECK (expires_at > updated_at),
    CHECK (expires_at <= updated_at + 3024000)
) STRICT;

INSERT INTO apns_subscriptions(
  device_id, participant_id, environment,
  token_ciphertext, token_nonce, token_digest, encryption_key_id,
  created_at, updated_at, expires_at
)
SELECT device_id, participant_id, environment,
       token_ciphertext, token_nonce, token_digest, encryption_key_id,
       created_at, updated_at, expires_at
  FROM apns_subscriptions_single_token;

DROP TABLE apns_subscriptions_single_token;

CREATE INDEX apns_subscriptions_participant
    ON apns_subscriptions(participant_id, device_id);

CREATE INDEX apns_subscriptions_token_digest
    ON apns_subscriptions(token_digest, device_id);

CREATE TRIGGER apns_subscriptions_require_current_active_device
BEFORE INSERT ON apns_subscriptions
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moment_devices AS device
        JOIN moment_participants AS participant
          ON participant.id = device.participant_id
       WHERE device.id = NEW.device_id
         AND device.participant_id = NEW.participant_id
         AND device.state = 'active'
         AND participant.state = 'active'
    ) THEN RAISE(ABORT, 'APNs subscription device is not active') END);
END;

CREATE TRIGGER apns_subscriptions_require_current_active_device_update
BEFORE UPDATE ON apns_subscriptions
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moment_devices AS device
        JOIN moment_participants AS participant
          ON participant.id = device.participant_id
       WHERE device.id = NEW.device_id
         AND device.participant_id = NEW.participant_id
         AND device.state = 'active'
         AND participant.state = 'active'
    ) THEN RAISE(ABORT, 'APNs subscription device is not active') END);
END;

CREATE TRIGGER notification_events_create_deliveries
AFTER INSERT ON notification_events
BEGIN
    INSERT INTO notification_deliveries(
      event_id, device_id, token_digest, state, attempts,
      next_attempt_at, updated_at
    )
    SELECT NEW.id, subscription.device_id, subscription.token_digest,
           'pending', 0, NEW.created_at, NEW.created_at
      FROM apns_subscriptions AS subscription
      JOIN moment_devices AS device ON device.id = subscription.device_id
     WHERE subscription.participant_id = NEW.participant_id
       AND subscription.expires_at > NEW.created_at
       AND device.state = 'active';
END;

CREATE TRIGGER apns_subscriptions_refresh_pending_deliveries
AFTER UPDATE OF token_digest ON apns_subscriptions
WHEN OLD.token_digest <> NEW.token_digest
BEGIN
    UPDATE notification_deliveries
       SET token_digest = NEW.token_digest,
           state = 'pending', attempts = 0,
           next_attempt_at = NEW.updated_at,
           lease_id = NULL, lease_expires_at = NULL,
           last_status = NULL, last_reason = NULL,
           accepted_at = NULL, updated_at = NEW.updated_at
     WHERE device_id = NEW.device_id
       AND state <> 'accepted'
       AND EXISTS (
         SELECT 1 FROM notification_events AS event
          WHERE event.id = notification_deliveries.event_id
            AND event.expires_at > NEW.updated_at
       );
END;

CREATE TRIGGER apns_subscriptions_delete_on_device_close
AFTER UPDATE OF state ON moment_devices
WHEN OLD.state <> NEW.state AND NEW.state IN ('revoked', 'expired')
BEGIN
    DELETE FROM apns_subscriptions WHERE device_id = NEW.id;
END;

CREATE TRIGGER apns_notifications_delete_on_participant_close
AFTER UPDATE OF state ON moment_participants
WHEN OLD.state <> NEW.state AND NEW.state IN ('revoked', 'expired')
BEGIN
    DELETE FROM apns_subscriptions WHERE participant_id = NEW.id;
    DELETE FROM notification_events WHERE participant_id = NEW.id;
END;

CREATE TRIGGER apns_notifications_delete_on_space_close
AFTER UPDATE OF state ON moment_spaces
WHEN OLD.state <> NEW.state AND NEW.state = 'revoked'
BEGIN
    DELETE FROM notification_events
     WHERE participant_id IN (
       SELECT id FROM moment_participants WHERE space_id = NEW.space_id
     );
    DELETE FROM apns_subscriptions
     WHERE participant_id IN (
       SELECT id FROM moment_participants WHERE space_id = NEW.space_id
     );
END;
