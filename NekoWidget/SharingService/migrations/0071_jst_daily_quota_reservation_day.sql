-- Do not reset populated UTC counters in the middle of a day.
-- New Worker code must be deployed before effective_at; old UTC writes fail
-- closed after cutover. Existing counters, retries and receipts are unchanged.
CREATE TABLE daily_quota_day_policy (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 utc_offset_seconds INTEGER NOT NULL CHECK(utc_offset_seconds=32400),
 effective_at INTEGER NOT NULL
) STRICT;
INSERT INTO daily_quota_day_policy VALUES (1,32400,(CAST((unixepoch()+32400)/86400 AS INTEGER)+1)*86400-32400);
CREATE TRIGGER moments_require_product_day BEFORE INSERT ON moments
WHEN NEW.kind<>'bootstrap' AND NEW.quota_counted=1
BEGIN
 SELECT (CASE WHEN NEW.quota_day_key<>(SELECT CAST((NEW.created_at+(CASE WHEN NEW.created_at>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER) FROM daily_quota_day_policy WHERE singleton=1) THEN RAISE(ABORT,'moment day key is invalid') END);
END;
CREATE TRIGGER moment_reports_require_product_day BEFORE INSERT ON moment_reports
BEGIN
 SELECT (CASE WHEN NEW.quota_day_key<>(SELECT CAST((NEW.created_at+(CASE WHEN NEW.created_at>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER) FROM daily_quota_day_policy WHERE singleton=1) THEN RAISE(ABORT,'report day key is invalid') END);
END;
CREATE TRIGGER group_hearts_require_product_day BEFORE INSERT ON group_heart_usage
WHEN NEW.day_key>=CAST(unixepoch()/86400 AS INTEGER)
BEGIN
 SELECT (CASE WHEN NEW.day_key<>(SELECT CAST((unixepoch()+(CASE WHEN unixepoch()>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER) FROM daily_quota_day_policy WHERE singleton=1) THEN RAISE(ABORT,'heart day key is invalid') END);
END;
DROP TRIGGER moment_reactions_require_live_delivery;
CREATE TRIGGER moment_reactions_require_live_delivery
BEFORE INSERT ON moment_reactions
BEGIN
    SELECT (CASE WHEN NEW.quota_day_key <> (SELECT CAST((NEW.created_at+(CASE WHEN NEW.created_at>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER) FROM daily_quota_day_policy WHERE singleton=1)
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
    THEN RAISE(ABORT,'group_report_not_delivered') END);
  SELECT (CASE WHEN EXISTS (SELECT 1 FROM group_report_tombstones WHERE dedupe_key=NEW.dedupe_key)
    THEN RAISE(ABORT,'group_report_already_reported') END);
  SELECT (CASE WHEN COALESCE((SELECT attempts FROM group_report_daily_usage
    WHERE person_id=NEW.reporter_person_id AND day_key=(SELECT CAST((NEW.created_at+(CASE WHEN NEW.created_at>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER) FROM daily_quota_day_policy WHERE singleton=1)),0)>=10
    THEN RAISE(ABORT,'group_report_daily_limit') END);
END;
DROP TRIGGER group_report_charge;
CREATE TRIGGER group_report_charge AFTER INSERT ON group_reports
BEGIN
  INSERT INTO group_report_daily_usage VALUES (NEW.reporter_person_id,(SELECT CAST((NEW.created_at+(CASE WHEN NEW.created_at>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER) FROM daily_quota_day_policy WHERE singleton=1),1)
    ON CONFLICT(person_id,day_key) DO UPDATE SET attempts=attempts+1;
END;
-- Add a child ledger, not a column: old positional INSERTs remain valid.
CREATE TABLE group_moment_quota_days (
 moment_id TEXT PRIMARY KEY REFERENCES group_moments(id) ON DELETE CASCADE,
 day_key INTEGER NOT NULL
) STRICT;
CREATE INDEX group_moment_quota_day ON group_moment_quota_days(day_key,moment_id);
-- Preserve already-charged commit days. Existing live reservations were
-- counted on the deployment day by 0059: retain that conservative charge.
INSERT INTO group_moment_quota_days SELECT id,(SELECT CAST((CASE WHEN committed_at IS NOT NULL THEN committed_at WHEN state IN ('reserved','uploaded') AND upload_expires_at>unixepoch() THEN MAX(created_at,unixepoch()) ELSE created_at END+(CASE WHEN (CASE WHEN committed_at IS NOT NULL THEN committed_at WHEN state IN ('reserved','uploaded') AND upload_expires_at>unixepoch() THEN MAX(created_at,unixepoch()) ELSE created_at END)>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER) FROM group_photo_day_policy WHERE singleton=1) FROM group_moments;
CREATE TRIGGER group_moment_hold_reservation_day AFTER INSERT ON group_moments
BEGIN
 INSERT INTO group_moment_quota_days VALUES (NEW.id,(SELECT CAST((NEW.created_at+(CASE WHEN NEW.created_at>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER) FROM group_photo_day_policy WHERE singleton=1));
END;
CREATE TRIGGER group_moment_reservation_day_immutable BEFORE UPDATE ON group_moment_quota_days
BEGIN
 SELECT RAISE(ABORT,'group reservation day is immutable');
END;
DROP TRIGGER group_reservation_authority;
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
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_moments m JOIN group_moment_quota_days q ON q.moment_id=m.id
        WHERE m.space_id=NEW.space_id AND m.sender_participant_id=NEW.sender_participant_id
          AND q.day_key=(SELECT CAST((NEW.created_at+(CASE WHEN NEW.created_at>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER) FROM group_photo_day_policy WHERE singleton=1)
          AND (m.state='committed' OR (m.state IN ('reserved','uploaded') AND m.upload_expires_at>NEW.created_at)))>=5
        THEN RAISE(ABORT,'group_photo_daily_limit') END);
END;
DROP TRIGGER group_moment_commit;
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
    SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM group_moment_quota_days WHERE moment_id=NEW.id)
        THEN RAISE(ABORT,'group_reservation_day_missing') END);
    SELECT (CASE WHEN NEW.state='committed' AND (SELECT COUNT(*) FROM group_moments m
        JOIN group_moment_quota_days q ON q.moment_id=m.id
        WHERE m.space_id=NEW.space_id AND m.sender_participant_id=NEW.sender_participant_id AND m.state='committed'
          AND q.day_key=(SELECT day_key FROM group_moment_quota_days WHERE moment_id=NEW.id))>=5
        THEN RAISE(ABORT,'group_photo_daily_limit') END);
END;
