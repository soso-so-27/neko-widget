PRAGMA foreign_keys = ON;

-- Keep this migration LF-only; Wrangler remote trigger parsing rejects CRLF.
-- A device is one credential for a participant. Closing one of several
-- devices must not erase participant-scoped reactions, idempotency evidence,
-- or the encrypted window name. Participant/space close and block triggers
-- remain the authoritative shared-data cleanup boundaries.

DROP TRIGGER moment_window_names_delete_on_device_revoke;
DROP TRIGGER moment_window_names_cleanup_on_device_delete;
DROP TRIGGER moment_reactions_delete_on_device_close;

-- `moment_deliveries` is participant-scoped. Its first ACK must not delete
-- pending APNs work for the participant's other physical iPhones. The signed
-- ACK route now removes only the requesting device token's delivery and drops
-- the event after its last physical-device delivery is gone.
DROP TRIGGER apns_notifications_delete_on_delivery_close;

-- One physical installation may have several active device credentials for
-- the same participant, all carrying the same APNs token. Enqueue exactly one
-- delivery per event/token digest and choose a stable active device row to
-- authenticate/decrypt the subscription at send time.
DROP TRIGGER notification_events_create_deliveries;

CREATE TRIGGER notification_events_create_deliveries
AFTER INSERT ON notification_events
BEGIN
    INSERT INTO notification_deliveries(
      event_id, device_id, token_digest, state, attempts,
      next_attempt_at, updated_at
    )
    SELECT NEW.id, MIN(subscription.device_id), subscription.token_digest,
           'pending', 0, NEW.created_at, NEW.created_at
      FROM apns_subscriptions AS subscription
      JOIN moment_devices AS device ON device.id = subscription.device_id
     WHERE subscription.participant_id = NEW.participant_id
       AND subscription.expires_at > NEW.created_at
       AND device.state = 'active'
     GROUP BY subscription.token_digest;
END;
