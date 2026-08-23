PRAGMA foreign_keys = ON;

-- Keep this migration LF-only; Wrangler remote trigger parsing rejects CRLF.
-- The Worker never receives or stores a plaintext display name. This row is
-- the opaque, combined-AEAD envelope currently published for one v2 space.
CREATE TABLE moment_window_names (
    space_id TEXT PRIMARY KEY
        REFERENCES moment_spaces(space_id) ON DELETE CASCADE,
    owner_member_id TEXT NOT NULL
        REFERENCES members(id) ON DELETE CASCADE,
    client_revision INTEGER NOT NULL CHECK (client_revision >= 0),
    key_epoch INTEGER NOT NULL CHECK (key_epoch > 0),
    ciphertext TEXT NOT NULL,
    ciphertext_size INTEGER NOT NULL CHECK (ciphertext_size BETWEEN 29 AND 512),
    ciphertext_sha256 TEXT NOT NULL,
    owner_signature TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    CHECK (length(ciphertext) BETWEEN 39 AND 683),
    CHECK (length(ciphertext_sha256) = 43),
    CHECK (length(owner_signature) = 86)
) STRICT;

CREATE TRIGGER moment_window_names_require_active_owner_insert
BEFORE INSERT ON moment_window_names
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moment_spaces AS space
        JOIN members AS owner
          ON owner.id = NEW.owner_member_id
       WHERE space.space_id = NEW.space_id
         AND space.state = 'active'
         AND space.current_key_epoch = NEW.key_epoch
         AND owner.space_id = space.space_id
         AND owner.role = 'owner'
         AND owner.state = 'active'
         AND NOT EXISTS (
           SELECT 1 FROM moment_blocks AS block
            WHERE block.space_id = NEW.space_id AND block.state = 'active'
         )
    ) THEN RAISE(ABORT, 'window name owner or key epoch is not active') END);
END;

CREATE TRIGGER moment_window_names_validate_update
BEFORE UPDATE ON moment_window_names
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
      SELECT 1
        FROM moment_spaces AS space
        JOIN members AS owner
          ON owner.id = NEW.owner_member_id
       WHERE space.space_id = NEW.space_id
         AND space.state = 'active'
         AND space.current_key_epoch = NEW.key_epoch
         AND owner.space_id = space.space_id
         AND owner.role = 'owner'
         AND owner.state = 'active'
         AND NOT EXISTS (
           SELECT 1 FROM moment_blocks AS block
            WHERE block.space_id = NEW.space_id AND block.state = 'active'
         )
    ) THEN RAISE(ABORT, 'window name owner or key epoch is not active') END);
    SELECT (CASE WHEN NEW.client_revision < OLD.client_revision
      THEN RAISE(ABORT, 'window name revision is stale') END);
    SELECT (CASE WHEN NEW.client_revision = OLD.client_revision AND (
      NEW.owner_member_id <> OLD.owner_member_id
      OR NEW.key_epoch <> OLD.key_epoch
      OR NEW.ciphertext <> OLD.ciphertext
      OR NEW.ciphertext_size <> OLD.ciphertext_size
      OR NEW.ciphertext_sha256 <> OLD.ciphertext_sha256
      OR NEW.owner_signature <> OLD.owner_signature
    ) THEN RAISE(ABORT, 'window name revision conflicts') END);
END;

-- Any trust-boundary change discards the old envelope. A block permanently
-- disables this per-space record; insert/update guards reject recreation.
CREATE TRIGGER moment_window_names_delete_on_block
AFTER INSERT ON moment_blocks
BEGIN
    DELETE FROM moment_window_names WHERE space_id = NEW.space_id;
    DELETE FROM idempotency_records
     WHERE space_id = NEW.space_id AND operation = 'put-window-name';
END;

CREATE TRIGGER moment_window_names_delete_on_participant_revoke
AFTER UPDATE OF state ON moment_participants
WHEN OLD.state <> NEW.state AND NEW.state IN ('revoked', 'expired')
BEGIN
    DELETE FROM moment_window_names WHERE space_id = NEW.space_id;
    DELETE FROM idempotency_records
     WHERE space_id = NEW.space_id AND operation = 'put-window-name';
END;

CREATE TRIGGER moment_window_names_delete_on_device_revoke
AFTER UPDATE OF state ON moment_devices
WHEN OLD.state <> NEW.state AND NEW.state IN ('revoked', 'expired')
BEGIN
    DELETE FROM moment_window_names
     WHERE space_id = (
       SELECT space_id FROM moment_participants WHERE id = NEW.participant_id
     );
    DELETE FROM idempotency_records
     WHERE operation = 'put-window-name'
       AND space_id = (
         SELECT space_id FROM moment_participants WHERE id = NEW.participant_id
       );
END;

CREATE TRIGGER moment_window_names_delete_on_space_revoke
AFTER UPDATE OF state ON moment_spaces
WHEN OLD.state <> NEW.state AND NEW.state = 'revoked'
BEGIN
    DELETE FROM moment_window_names WHERE space_id = NEW.space_id;
    DELETE FROM idempotency_records
     WHERE space_id = NEW.space_id AND operation = 'put-window-name';
END;

CREATE TRIGGER moment_window_names_delete_on_legacy_space_revoke
AFTER UPDATE OF state ON spaces
WHEN OLD.state <> NEW.state AND NEW.state = 'revoked'
BEGIN
    DELETE FROM moment_window_names WHERE space_id = NEW.id;
    DELETE FROM idempotency_records
     WHERE space_id = NEW.id AND operation = 'put-window-name';
END;

CREATE TRIGGER moment_window_names_cleanup_on_participant_delete
AFTER DELETE ON moment_participants
BEGIN
    DELETE FROM moment_window_names WHERE space_id = OLD.space_id;
    DELETE FROM idempotency_records
     WHERE space_id = OLD.space_id AND operation = 'put-window-name';
END;

CREATE TRIGGER moment_window_names_cleanup_on_device_delete
AFTER DELETE ON moment_devices
BEGIN
    DELETE FROM moment_window_names
     WHERE space_id = (
       SELECT space_id FROM moment_participants WHERE id = OLD.participant_id
     );
    DELETE FROM idempotency_records
     WHERE operation = 'put-window-name'
       AND space_id = (
         SELECT space_id FROM moment_participants WHERE id = OLD.participant_id
       );
END;

CREATE TRIGGER moment_window_names_cleanup_on_space_delete
AFTER DELETE ON moment_spaces
BEGIN
    DELETE FROM idempotency_records
     WHERE space_id = OLD.space_id AND operation = 'put-window-name';
END;
