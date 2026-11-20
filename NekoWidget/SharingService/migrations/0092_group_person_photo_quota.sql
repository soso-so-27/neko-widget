-- Enforce the existing daily photo limit across a person's windows and
-- devices. Keep the existing membership, reservation-day and relay checks.
-- No new identity data is stored. Existing reservations count on their
-- original day, and an expired upload without a commit frees its slot.
-- Keep membership first in the SQLite join order. Starting from the day
-- index would scan photos across unrelated people when the sender is under quota.
CREATE TRIGGER group_person_photo_reservation_quota BEFORE INSERT ON group_moments
WHEN EXISTS (
  SELECT 1 FROM group_members actor
  CROSS JOIN group_members participant ON participant.person_id=actor.person_id
  CROSS JOIN group_moments used ON used.space_id=participant.space_id AND used.sender_participant_id=participant.participant_id
  CROSS JOIN group_moment_quota_days q ON q.moment_id=used.id
  WHERE actor.participant_id=NEW.sender_participant_id
    AND q.day_key=(SELECT CAST((NEW.created_at+(CASE WHEN NEW.created_at>=effective_at THEN utc_offset_seconds ELSE 0 END))/86400 AS INTEGER)
      FROM group_photo_day_policy WHERE singleton=1)
    AND (used.committed_at IS NOT NULL OR (used.state IN ('reserved','uploaded') AND used.upload_expires_at>NEW.created_at))
  LIMIT 1 OFFSET 4
)
BEGIN
  SELECT RAISE(ABORT,'group_photo_daily_limit');
END;

-- Reservations created before this migration may already exceed the shared
-- limit. Recheck successful sends at commit inside the same transaction.
CREATE TRIGGER group_person_photo_commit_quota BEFORE UPDATE OF state ON group_moments
WHEN NEW.state='committed' AND NEW.state<>OLD.state AND EXISTS (
  SELECT 1 FROM group_members actor
  CROSS JOIN group_members participant ON participant.person_id=actor.person_id
  CROSS JOIN group_moments used ON used.space_id=participant.space_id AND used.sender_participant_id=participant.participant_id
  CROSS JOIN group_moment_quota_days q ON q.moment_id=used.id
  WHERE actor.participant_id=NEW.sender_participant_id AND used.id<>NEW.id
    AND q.day_key=(SELECT day_key FROM group_moment_quota_days WHERE moment_id=NEW.id)
    AND used.committed_at IS NOT NULL
  LIMIT 1 OFFSET 4
)
BEGIN
  SELECT RAISE(ABORT,'group_photo_daily_limit');
END;
