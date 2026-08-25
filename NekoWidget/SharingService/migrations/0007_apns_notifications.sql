PRAGMA foreign_keys = ON;

-- Keep this migration LF-only; Wrangler remote trigger parsing rejects CRLF.
-- APNs device tokens are opaque credentials. The Worker stores only an
-- application-encrypted token and a one-way digest used for CAS/revocation.

CREATE TABLE apns_subscriptions (
    device_id TEXT PRIMARY KEY
        REFERENCES moment_devices(id) ON DELETE CASCADE,
    participant_id TEXT NOT NULL
        REFERENCES moment_participants(id) ON DELETE CASCADE,
    environment TEXT NOT NULL
        CHECK (environment IN ('development', 'production')),
    token_ciphertext TEXT NOT NULL,
    token_nonce TEXT NOT NULL,
    token_digest TEXT NOT NULL UNIQUE,
    encryption_key_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    CHECK (updated_at >= created_at),
    CHECK (expires_at > updated_at),
    CHECK (expires_at <= updated_at + 3024000)
) STRICT;

CREATE INDEX apns_subscriptions_participant
    ON apns_subscriptions(participant_id, device_id);

CREATE TABLE notification_events (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('new_moment', 'heart')),
    participant_id TEXT NOT NULL
        REFERENCES moment_participants(id) ON DELETE CASCADE,
    moment_id TEXT REFERENCES moments(id) ON DELETE CASCADE,
    reaction_id TEXT REFERENCES moment_reactions(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    CHECK (expires_at > created_at),
    CHECK (
      (kind = 'new_moment' AND moment_id IS NOT NULL AND reaction_id IS NULL)
      OR (kind = 'heart' AND moment_id IS NULL AND reaction_id IS NOT NULL)
    )
) STRICT;

CREATE UNIQUE INDEX notification_events_one_moment_recipient
    ON notification_events(kind, participant_id, moment_id)
    WHERE kind = 'new_moment';

CREATE UNIQUE INDEX notification_events_one_heart_recipient
    ON notification_events(kind, participant_id, reaction_id)
    WHERE kind = 'heart';

CREATE INDEX notification_events_expiry
    ON notification_events(expires_at, id);

CREATE TABLE notification_deliveries (
    event_id TEXT NOT NULL
        REFERENCES notification_events(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL
        REFERENCES moment_devices(id) ON DELETE CASCADE,
    token_digest TEXT NOT NULL,
    state TEXT NOT NULL
        CHECK (state IN ('pending', 'leased', 'accepted', 'dead')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at INTEGER NOT NULL,
    lease_id TEXT,
    lease_expires_at INTEGER,
    last_status INTEGER,
    last_reason TEXT,
    accepted_at INTEGER,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (event_id, device_id),
    CHECK (
      (state = 'leased' AND lease_id IS NOT NULL AND lease_expires_at IS NOT NULL)
      OR (state <> 'leased' AND lease_id IS NULL AND lease_expires_at IS NULL)
    ),
    CHECK (
      (state = 'accepted' AND accepted_at IS NOT NULL)
      OR (state <> 'accepted')
    )
) STRICT;

CREATE INDEX notification_deliveries_dispatch
    ON notification_deliveries(state, next_attempt_at, lease_expires_at, event_id, device_id);

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

CREATE TRIGGER notification_events_require_live_source
BEFORE INSERT ON notification_events
BEGIN
    SELECT (CASE WHEN NEW.kind = 'new_moment' AND NOT EXISTS (
      SELECT 1
        FROM moments AS moment
        JOIN moment_deliveries AS delivery
          ON delivery.moment_id = moment.id
       WHERE moment.id = NEW.moment_id
         AND moment.state = 'committed'
         AND delivery.recipient_participant_id = NEW.participant_id
         AND delivery.state IN ('pending', 'acknowledged')
    ) THEN RAISE(ABORT, 'notification moment recipient is invalid') END);
    SELECT (CASE WHEN NEW.kind = 'heart' AND NOT EXISTS (
      SELECT 1 FROM moment_reactions AS reaction
       WHERE reaction.id = NEW.reaction_id
         AND reaction.recipient_participant_id = NEW.participant_id
    ) THEN RAISE(ABORT, 'notification reaction recipient is invalid') END);
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

-- Foreground synchronization can acknowledge a photo before a queued APNs
-- attempt runs. Once access has been observed or closed, a later alert would
-- be stale and is removed together with every pending/retry delivery.
CREATE TRIGGER apns_notifications_delete_on_delivery_close
AFTER UPDATE OF state ON moment_deliveries
WHEN OLD.state <> NEW.state
  AND NEW.state IN ('acknowledged', 'revoked', 'expired')
BEGIN
    DELETE FROM notification_events
     WHERE kind = 'new_moment'
       AND moment_id = NEW.moment_id
       AND participant_id = NEW.recipient_participant_id;
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

-- A block closes the trust boundary immediately. Delete every queued alert
-- whose source joins the newly blocked pair; the source rows themselves are
-- removed by the existing moment/reaction privacy triggers as applicable.
CREATE TRIGGER apns_notifications_delete_on_block
AFTER INSERT ON moment_blocks
BEGIN
    DELETE FROM notification_events
     WHERE (
       kind = 'new_moment'
       AND moment_id IN (
         SELECT moment.id
           FROM moments AS moment
          WHERE moment.space_id = NEW.space_id
            AND (
              (moment.sender_participant_id = NEW.blocker_participant_id
               AND participant_id = NEW.blocked_participant_id)
              OR
              (moment.sender_participant_id = NEW.blocked_participant_id
               AND participant_id = NEW.blocker_participant_id)
            )
       )
     ) OR (
       kind = 'heart'
       AND reaction_id IN (
         SELECT reaction.id
           FROM moment_reactions AS reaction
          WHERE reaction.space_id = NEW.space_id
            AND (
              (reaction.reactor_participant_id = NEW.blocker_participant_id
               AND reaction.recipient_participant_id = NEW.blocked_participant_id)
              OR
              (reaction.reactor_participant_id = NEW.blocked_participant_id
               AND reaction.recipient_participant_id = NEW.blocker_participant_id)
            )
       )
     );
END;
