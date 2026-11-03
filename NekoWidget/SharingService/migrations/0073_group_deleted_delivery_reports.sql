-- The deletion journal fixes these digests and absolute deadlines at acceptance.
-- Commands bind the same signed receiver and original accused FK for one D1
-- batch. Raw command values never remain in the tombstone or after commit.
CREATE TABLE group_deleted_deliveries (
 window_digest TEXT NOT NULL CHECK(length(window_digest)=43),
 moment_digest TEXT NOT NULL CHECK(length(moment_digest)=43),
 sender_person_digest TEXT NOT NULL CHECK(length(sender_person_digest)=43),
 sender_participant_digest TEXT NOT NULL CHECK(length(sender_participant_digest)=43),
 receiver_person_digest TEXT NOT NULL CHECK(length(receiver_person_digest)=43),
 receiver_device_digest TEXT NOT NULL CHECK(length(receiver_device_digest)=43),
 generation INTEGER NOT NULL CHECK(generation>0),
 expires_at INTEGER NOT NULL CHECK(expires_at>0),
 PRIMARY KEY(window_digest,moment_digest,receiver_person_digest,receiver_device_digest)
) STRICT;
CREATE INDEX group_deleted_deliveries_expiry ON group_deleted_deliveries(expires_at);
CREATE TRIGGER group_deleted_delivery_no_update BEFORE UPDATE ON group_deleted_deliveries
WHEN OLD.sender_person_digest<>NEW.sender_person_digest OR OLD.sender_participant_digest<>NEW.sender_participant_digest
 OR OLD.generation<>NEW.generation OR OLD.expires_at<>NEW.expires_at
 OR OLD.window_digest<>NEW.window_digest OR OLD.moment_digest<>NEW.moment_digest
 OR OLD.receiver_person_digest<>NEW.receiver_person_digest OR OLD.receiver_device_digest<>NEW.receiver_device_digest
BEGIN SELECT RAISE(ABORT,'deleted_delivery_mismatch'); END;
CREATE TABLE group_deleted_delivery_commands (
 report_id TEXT PRIMARY KEY, space TEXT NOT NULL, moment TEXT NOT NULL, sender TEXT NOT NULL, accused TEXT NOT NULL,
 receiver TEXT NOT NULL, device TEXT NOT NULL, window_digest TEXT NOT NULL, moment_digest TEXT NOT NULL,
 sender_person_digest TEXT NOT NULL, sender_participant_digest TEXT NOT NULL, receiver_person_digest TEXT NOT NULL,
 receiver_device_digest TEXT NOT NULL, generation INTEGER NOT NULL
) STRICT;
ALTER TABLE group_reports ADD COLUMN deleted_delivery_until INTEGER CHECK(deleted_delivery_until IS NULL OR deleted_delivery_until>0);
CREATE TRIGGER group_deleted_report_expiry BEFORE UPDATE ON group_reports
WHEN OLD.deleted_delivery_until IS NOT NEW.deleted_delivery_until OR
 (NEW.deleted_delivery_until<=unixepoch() AND NEW.state IN ('uploaded','committed') AND NEW.state<>OLD.state)
BEGIN SELECT RAISE(ABORT,'group_report_not_authorized'); END;
DROP TRIGGER group_report_reserve;
CREATE TRIGGER group_report_reserve BEFORE INSERT ON group_reports
BEGIN
  SELECT (CASE WHEN NEW.state<>'reserved' OR NEW.created_at NOT BETWEEN unixepoch()-300 AND unixepoch()
    OR NEW.reporter_consented_at<unixepoch()-300 OR NEW.reporter_consented_at>unixepoch()+300
    OR NEW.uploaded_at IS NOT NULL OR NEW.committed_at IS NOT NULL OR NEW.expired_at IS NOT NULL
    THEN RAISE(ABORT,'group_report_invalid_reservation') END);
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM group_report_credentials c JOIN group_moment_deliveries d ON d.device_id=c.device_id
    JOIN group_moments m ON m.id=d.moment_id AND m.space_id=c.space_id
    WHERE c.space_id=NEW.space_id AND c.device_id=NEW.reporter_device_id
      AND c.person_id=NEW.reporter_person_id AND c.participant_id=NEW.reporter_participant_id
      AND d.participant_id=c.participant_id AND d.state IN ('pending','acknowledged','expired')
      AND m.id=NEW.moment_id AND m.committed_at IS NOT NULL
      AND m.sender_participant_id=NEW.accused_participant_id AND m.sender_participant_id<>c.participant_id)
    AND NOT EXISTS (
      SELECT 1 FROM group_deleted_delivery_commands cmd
      JOIN group_deleted_deliveries marker ON marker.window_digest=cmd.window_digest AND marker.moment_digest=cmd.moment_digest
        AND marker.receiver_person_digest=cmd.receiver_person_digest AND marker.receiver_device_digest=cmd.receiver_device_digest
        AND marker.sender_person_digest=cmd.sender_person_digest AND marker.sender_participant_digest=cmd.sender_participant_digest
        AND marker.generation=cmd.generation AND marker.expires_at=NEW.deleted_delivery_until
      JOIN group_report_credentials c ON c.space_id=cmd.space AND c.device_id=cmd.device AND c.person_id=cmd.receiver
      JOIN group_members accused ON accused.space_id=cmd.space AND accused.participant_id=cmd.accused AND accused.person_id=cmd.sender
      WHERE cmd.report_id=NEW.id AND cmd.space=NEW.space_id AND cmd.moment=NEW.moment_id
        AND cmd.device=NEW.reporter_device_id AND cmd.receiver=NEW.reporter_person_id
        AND cmd.accused=NEW.accused_participant_id AND c.participant_id=NEW.reporter_participant_id
        AND cmd.sender<>cmd.receiver AND marker.expires_at>unixepoch())
    THEN RAISE(ABORT,'group_report_not_delivered') END);
  SELECT (CASE WHEN EXISTS (SELECT 1 FROM group_report_tombstones WHERE dedupe_key=NEW.dedupe_key)
    THEN RAISE(ABORT,'group_report_already_reported') END);
  SELECT (CASE WHEN COALESCE((SELECT attempts FROM group_report_daily_usage
    WHERE person_id=NEW.reporter_person_id AND day_key=(SELECT CAST((NEW.created_at+(CASE WHEN NEW.created_at>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER) FROM daily_quota_day_policy WHERE singleton=1)),0)>=10
    THEN RAISE(ABORT,'group_report_daily_limit') END);
END;
