-- Additive, no backfill: unknown historical participation stays unknown.
CREATE TABLE group_recovery_participation (
 window_id TEXT NOT NULL REFERENCES group_windows(space_id),
 person_id TEXT NOT NULL REFERENCES group_people(id),
 participant_id TEXT NOT NULL REFERENCES group_members(participant_id),
 roster_hash TEXT NOT NULL, proof_json TEXT NOT NULL,
 PRIMARY KEY(window_id,person_id)
) STRICT;
CREATE TRIGGER group_recovery_participation_leave AFTER UPDATE OF state ON group_members
WHEN NEW.state<>'active'
BEGIN DELETE FROM group_recovery_participation WHERE participant_id=NEW.participant_id; END;
CREATE TRIGGER group_recovery_participation_close AFTER UPDATE OF mode ON group_windows
WHEN NEW.mode<>'active'
BEGIN DELETE FROM group_recovery_participation WHERE window_id=NEW.space_id; END;
CREATE TRIGGER group_recovery_participation_identity AFTER UPDATE OF state ON group_people
WHEN NEW.state<>'active'
BEGIN DELETE FROM group_recovery_participation WHERE person_id=NEW.id; END;
