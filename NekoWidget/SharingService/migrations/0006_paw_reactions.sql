PRAGMA foreign_keys = ON;

-- Keep this migration LF-only; Wrangler remote trigger parsing rejects CRLF.
-- Paw reactions are deliberately separate from the encrypted moment-change
-- feed. A reaction is a bounded, non-secret acknowledgement from an active
-- recipient to the original sender; it never changes ciphertext access.

CREATE TABLE moment_reaction_daily_usage (
    participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    day_key INTEGER NOT NULL,
    reaction_count INTEGER NOT NULL DEFAULT 0 CHECK (reaction_count BETWEEN 0 AND 30),
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (participant_id, day_key)
) STRICT;

CREATE TABLE moment_reactions (
    id TEXT PRIMARY KEY,
    moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
    space_id TEXT NOT NULL REFERENCES moment_spaces(space_id) ON DELETE CASCADE,
    reactor_participant_id TEXT NOT NULL
        REFERENCES moment_participants(id) ON DELETE CASCADE,
    recipient_participant_id TEXT NOT NULL
        REFERENCES moment_participants(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind = 'paw'),
    quota_day_key INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (moment_id, reactor_participant_id, kind),
    CHECK (reactor_participant_id <> recipient_participant_id)
) STRICT;

CREATE INDEX moment_reactions_recipient_created
    ON moment_reactions(recipient_participant_id, created_at, id);

CREATE TABLE reaction_changes (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    cursor TEXT NOT NULL UNIQUE,
    participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    -- ON DELETE SET NULL leaves only an opaque participant-scoped cursor
    -- position after trust/access cleanup. No moment or reactor identifier
    -- survives, while an offline sender can continue from its saved cursor.
    -- created_at remains server-internal for ordering/audit and is never sent.
    reaction_id TEXT UNIQUE REFERENCES moment_reactions(id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL
) STRICT;

CREATE INDEX reaction_changes_participant_sequence
    ON reaction_changes(participant_id, sequence);

CREATE TRIGGER moment_reactions_require_live_delivery
BEFORE INSERT ON moment_reactions
BEGIN
    SELECT (CASE WHEN NEW.quota_day_key <> CAST(NEW.created_at / 86400 AS INTEGER)
      THEN RAISE(ABORT, 'reaction day key is invalid') END);
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moments AS moment
        JOIN moment_spaces AS space ON space.space_id = moment.space_id
        JOIN moment_participants AS reactor
          ON reactor.id = NEW.reactor_participant_id
        JOIN moment_participants AS recipient
          ON recipient.id = NEW.recipient_participant_id
        JOIN moment_deliveries AS delivery
          ON delivery.moment_id = moment.id
         AND delivery.recipient_participant_id = reactor.id
       WHERE moment.id = NEW.moment_id
         AND moment.space_id = NEW.space_id
         AND moment.state = 'committed'
         AND moment.sender_participant_id = recipient.id
         AND space.state = 'active'
         AND reactor.space_id = moment.space_id
         AND reactor.state = 'active'
         AND recipient.space_id = moment.space_id
         AND recipient.state = 'active'
         AND reactor.id <> recipient.id
         AND delivery.state IN ('pending', 'acknowledged')
         AND delivery.access_expires_at > NEW.created_at
         AND EXISTS (
           SELECT 1 FROM moment_devices AS reactor_device
            WHERE reactor_device.participant_id = reactor.id
              AND reactor_device.state = 'active'
         )
         AND EXISTS (
           SELECT 1 FROM moment_devices AS recipient_device
            WHERE recipient_device.participant_id = recipient.id
              AND recipient_device.state = 'active'
         )
         AND NOT EXISTS (
           SELECT 1 FROM moment_blocks AS block
            WHERE block.space_id = moment.space_id
              AND block.state = 'active'
              AND (
                (block.blocker_participant_id = reactor.id
                 AND block.blocked_participant_id = recipient.id)
                OR
                (block.blocker_participant_id = recipient.id
                 AND block.blocked_participant_id = reactor.id)
              )
         )
    ) THEN RAISE(ABORT, 'reaction recipient is not eligible') END);
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moment_reactions AS existing
       WHERE existing.moment_id = NEW.moment_id
         AND existing.reactor_participant_id = NEW.reactor_participant_id
         AND existing.kind = NEW.kind
    ) AND COALESCE((
      SELECT usage.reaction_count
        FROM moment_reaction_daily_usage AS usage
       WHERE usage.participant_id = NEW.reactor_participant_id
         AND usage.day_key = NEW.quota_day_key
    ), 0) >= 30 THEN RAISE(ABORT, 'reaction daily quota reached') END);
END;

CREATE TRIGGER moment_reactions_count_daily_usage
AFTER INSERT ON moment_reactions
BEGIN
    INSERT INTO moment_reaction_daily_usage(
      participant_id, day_key, reaction_count, updated_at
    ) VALUES (
      NEW.reactor_participant_id, NEW.quota_day_key, 1, NEW.created_at
    )
    ON CONFLICT(participant_id, day_key) DO UPDATE SET
      reaction_count = moment_reaction_daily_usage.reaction_count + 1,
      updated_at = MAX(moment_reaction_daily_usage.updated_at, excluded.updated_at);
END;

CREATE TRIGGER reaction_changes_require_original_sender
BEFORE INSERT ON reaction_changes
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1 FROM moment_reactions AS reaction
       WHERE reaction.id = NEW.reaction_id
         AND reaction.recipient_participant_id = NEW.participant_id
         AND reaction.created_at = NEW.created_at
    ) THEN RAISE(ABORT, 'reaction change recipient is invalid') END);
END;

-- Once any trust or access boundary closes, the reaction payload disappears.
-- The opaque sender-scoped cursor position remains; daily usage does not decrement.
CREATE TRIGGER moment_reactions_delete_on_delivery_close
AFTER UPDATE OF state ON moment_deliveries
WHEN OLD.state <> NEW.state AND NEW.state IN ('expired', 'revoked')
BEGIN
    DELETE FROM moment_reactions
     WHERE moment_id = NEW.moment_id
       AND reactor_participant_id = NEW.recipient_participant_id;
    DELETE FROM idempotency_records
     WHERE operation = 'post-paw-reaction'
       AND space_id = (
         SELECT space_id FROM moments WHERE id = NEW.moment_id
       );
END;

CREATE TRIGGER moment_reactions_delete_on_moment_close
AFTER UPDATE OF state ON moments
WHEN OLD.state <> NEW.state AND NEW.state IN ('expired', 'deleted')
BEGIN
    DELETE FROM moment_reactions WHERE moment_id = NEW.id;
    DELETE FROM idempotency_records
     WHERE operation = 'post-paw-reaction' AND space_id = NEW.space_id;
END;

CREATE TRIGGER moment_reactions_delete_on_block
AFTER INSERT ON moment_blocks
BEGIN
    DELETE FROM moment_reactions
     WHERE space_id = NEW.space_id
       AND (
         (reactor_participant_id = NEW.blocker_participant_id
          AND recipient_participant_id = NEW.blocked_participant_id)
         OR
         (reactor_participant_id = NEW.blocked_participant_id
          AND recipient_participant_id = NEW.blocker_participant_id)
       );
    DELETE FROM idempotency_records
     WHERE operation = 'post-paw-reaction' AND space_id = NEW.space_id;
END;

CREATE TRIGGER moment_reactions_delete_on_participant_close
AFTER UPDATE OF state ON moment_participants
WHEN OLD.state <> NEW.state AND NEW.state IN ('revoked', 'expired')
BEGIN
    DELETE FROM moment_reactions
     WHERE reactor_participant_id = NEW.id OR recipient_participant_id = NEW.id;
    DELETE FROM idempotency_records
     WHERE operation = 'post-paw-reaction' AND space_id = NEW.space_id;
END;

CREATE TRIGGER moment_reactions_delete_on_device_close
AFTER UPDATE OF state ON moment_devices
WHEN OLD.state <> NEW.state AND NEW.state IN ('revoked', 'expired')
BEGIN
    DELETE FROM moment_reactions
     WHERE reactor_participant_id = NEW.participant_id
        OR recipient_participant_id = NEW.participant_id;
    DELETE FROM idempotency_records
     WHERE operation = 'post-paw-reaction'
       AND space_id = (
         SELECT space_id FROM moment_participants WHERE id = NEW.participant_id
       );
END;

CREATE TRIGGER moment_reactions_delete_on_space_close
AFTER UPDATE OF state ON moment_spaces
WHEN OLD.state <> NEW.state AND NEW.state = 'revoked'
BEGIN
    DELETE FROM moment_reactions WHERE space_id = NEW.space_id;
    DELETE FROM idempotency_records
     WHERE operation = 'post-paw-reaction' AND space_id = NEW.space_id;
END;
