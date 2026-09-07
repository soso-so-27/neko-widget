-- A separate capability survives local sharing-key cleanup, but not space cleanup.
-- There is deliberately no FK to moment_blocks: the withdrawn receipt is retained
-- for retries after the block itself is removed. No legacy block gets a capability.
CREATE TABLE moment_block_withdrawals (
    id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL CHECK (
        length(token_hash) = 64 AND token_hash NOT GLOB '*[^0-9a-f]*'
    ),
    space_id TEXT NOT NULL REFERENCES moment_spaces(space_id) ON DELETE CASCADE,
    blocker_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    blocked_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
    created_key_epoch INTEGER NOT NULL CHECK (created_key_epoch > 1),
    created_at INTEGER NOT NULL,
    withdrawn_at INTEGER CHECK (withdrawn_at IS NULL OR withdrawn_at >= created_at),
    UNIQUE (blocker_participant_id, blocked_participant_id),
    FOREIGN KEY (space_id) REFERENCES spaces(id) ON DELETE CASCADE,
    CHECK (blocker_participant_id <> blocked_participant_id)
) STRICT;

CREATE INDEX moment_block_withdrawals_space ON moment_block_withdrawals(space_id);

CREATE TRIGGER moment_block_withdrawals_require_block
BEFORE INSERT ON moment_block_withdrawals
BEGIN
    SELECT CASE WHEN NEW.withdrawn_at IS NOT NULL OR NOT EXISTS (
        SELECT 1 FROM moment_blocks
        WHERE space_id = NEW.space_id
          AND blocker_participant_id = NEW.blocker_participant_id
          AND blocked_participant_id = NEW.blocked_participant_id
          AND created_key_epoch = NEW.created_key_epoch
          AND created_at = NEW.created_at
          AND state = 'active'
    ) THEN RAISE(ABORT, 'withdrawal_requires_matching_block') END;
END;

-- This never reactivates the old space, credentials, deliveries or notifications.
CREATE TRIGGER moment_block_withdrawals_remove_block
AFTER UPDATE OF withdrawn_at ON moment_block_withdrawals
WHEN OLD.withdrawn_at IS NULL AND NEW.withdrawn_at IS NOT NULL
BEGIN
    DELETE FROM moment_blocks
    WHERE space_id = NEW.space_id
      AND blocker_participant_id = NEW.blocker_participant_id
      AND blocked_participant_id = NEW.blocked_participant_id
      AND created_key_epoch = NEW.created_key_epoch
      AND created_at = NEW.created_at;
END;
