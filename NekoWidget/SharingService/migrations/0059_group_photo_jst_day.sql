-- One source of truth for the product day: Japan UTC+09:00, no DST.
-- Applying at any time keeps UTC until the NEXT JST midnight. No mid-day reset.
-- Existing rows/receipts are never rewritten. In-flight reservations count on
-- the new day, so they cannot overbook its five slots across midnight.
CREATE TABLE group_photo_day_policy (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    utc_offset_seconds INTEGER NOT NULL CHECK(utc_offset_seconds BETWEEN 0 AND 86399),
    effective_at INTEGER NOT NULL
) STRICT;
INSERT INTO group_photo_day_policy VALUES (1,32400,0);
UPDATE group_photo_day_policy SET effective_at=
    (CAST((unixepoch()+utc_offset_seconds)/86400 AS INTEGER)+1)*86400-utc_offset_seconds;
DROP TRIGGER group_reservation_authority;
DROP TRIGGER group_moment_commit;
CREATE TRIGGER group_reservation_authority BEFORE INSERT ON group_moments
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_windows w JOIN group_window_devices d ON d.space_id=w.space_id
        JOIN group_members m ON m.participant_id=d.participant_id JOIN group_person_devices p ON p.id=d.device_id
        WHERE w.space_id=NEW.space_id AND w.mode='active' AND w.rotation_required=0
            AND w.revision=NEW.roster_revision AND w.key_epoch=NEW.key_epoch AND w.roster_hash=NEW.roster_hash
            AND d.device_id=NEW.sender_device_id AND d.state='active' AND m.state='active' AND p.state='active'
            AND m.participant_id=NEW.sender_participant_id)
        THEN RAISE(ABORT,'group_stale_epoch_or_membership') END);
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_moments
        WHERE space_id=NEW.space_id AND sender_participant_id=NEW.sender_participant_id
            AND ((state='committed' AND committed_at>=(SELECT (CASE WHEN NEW.created_at>=effective_at
            THEN CAST((NEW.created_at+utc_offset_seconds)/86400 AS INTEGER)*86400-utc_offset_seconds
            ELSE CAST(NEW.created_at/86400 AS INTEGER)*86400 END) FROM group_photo_day_policy WHERE singleton=1))
                OR (state IN ('reserved','uploaded') AND ((NEW.created_at>=(SELECT effective_at FROM group_photo_day_policy WHERE singleton=1)) OR created_at>=(SELECT (CASE WHEN NEW.created_at>=effective_at
            THEN CAST((NEW.created_at+utc_offset_seconds)/86400 AS INTEGER)*86400-utc_offset_seconds
            ELSE CAST(NEW.created_at/86400 AS INTEGER)*86400 END) FROM group_photo_day_policy WHERE singleton=1)) AND upload_expires_at>NEW.created_at))) >= 5
        THEN RAISE(ABORT,'group_photo_daily_limit') END);
END;
CREATE TRIGGER group_moment_commit BEFORE UPDATE OF state ON group_moments
WHEN NEW.state IN ('uploaded','committed') AND NEW.state <> OLD.state
BEGIN
    SELECT (CASE WHEN OLD.state NOT IN ('reserved','uploaded') OR OLD.upload_expires_at<=unixepoch()
        OR (NEW.state='committed' AND OLD.state<>'uploaded')
        THEN RAISE(ABORT,'group_reservation_expired') END);
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_windows w JOIN group_window_devices d ON d.space_id=w.space_id
        JOIN group_members m ON m.participant_id=d.participant_id JOIN group_person_devices p ON p.id=d.device_id
        WHERE w.space_id=NEW.space_id AND w.mode='active' AND w.rotation_required=0 AND w.key_epoch=NEW.key_epoch
            AND w.revision=NEW.roster_revision AND w.roster_hash=NEW.roster_hash AND d.device_id=NEW.sender_device_id
            AND d.state='active' AND p.state='active' AND m.state='active' AND m.participant_id=NEW.sender_participant_id)
        THEN RAISE(ABORT,'group_stale_epoch_or_membership') END);
    SELECT (CASE WHEN NEW.state='committed' AND (SELECT COUNT(*) FROM group_moments
        WHERE space_id=NEW.space_id AND sender_participant_id=NEW.sender_participant_id AND state='committed'
            AND committed_at>=(SELECT (CASE WHEN NEW.committed_at>=effective_at
            THEN CAST((NEW.committed_at+utc_offset_seconds)/86400 AS INTEGER)*86400-utc_offset_seconds
            ELSE CAST(NEW.committed_at/86400 AS INTEGER)*86400 END) FROM group_photo_day_policy WHERE singleton=1)) >= 5
        THEN RAISE(ABORT,'group_photo_daily_limit') END);
END;
