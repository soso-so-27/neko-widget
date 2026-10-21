PRAGMA foreign_keys = ON;

-- The existing per-window limit remains. Add the approved per-PERSON limit
-- across group windows and phones, without counters, history rows, backfills,
-- deletions, billing changes or changing ciphertext/retention limits.
-- Applying this migration starts enforcement; remote application needs review.
CREATE INDEX group_members_person_participant ON group_members(person_id,participant_id);
CREATE INDEX group_moments_person_reserve ON group_moments(sender_participant_id,state,created_at,upload_expires_at);
CREATE INDEX group_moments_person_commit ON group_moments(sender_participant_id,state,committed_at);

CREATE TRIGGER group_reservation_person_quota BEFORE INSERT ON group_moments
BEGIN
  SELECT CASE WHEN (
    (SELECT COUNT(*) FROM group_members m JOIN group_moments p ON p.sender_participant_id=m.participant_id
      WHERE m.person_id=(SELECT person_id FROM group_members WHERE participant_id=NEW.sender_participant_id)
        AND p.state='committed' AND p.committed_at>=CAST(NEW.created_at/86400 AS INTEGER)*86400
        AND p.committed_at<(CAST(NEW.created_at/86400 AS INTEGER)+1)*86400)
    + (SELECT COUNT(*) FROM group_members m JOIN group_moments p ON p.sender_participant_id=m.participant_id
      WHERE m.person_id=(SELECT person_id FROM group_members WHERE participant_id=NEW.sender_participant_id)
        AND p.state IN ('reserved','uploaded') AND p.created_at>=CAST(NEW.created_at/86400 AS INTEGER)*86400
        AND p.created_at<(CAST(NEW.created_at/86400 AS INTEGER)+1)*86400 AND p.upload_expires_at>NEW.created_at)
    )>=5 THEN RAISE(ABORT,'group_photo_daily_limit') END;
END;
CREATE TRIGGER group_commit_person_quota BEFORE UPDATE OF state ON group_moments
WHEN NEW.state='committed' AND OLD.state<>'committed'
BEGIN
  SELECT CASE WHEN (SELECT COUNT(*) FROM group_members m JOIN group_moments p ON p.sender_participant_id=m.participant_id
    WHERE m.person_id=(SELECT person_id FROM group_members WHERE participant_id=NEW.sender_participant_id)
      AND p.id<>NEW.id AND p.state='committed' AND p.committed_at>=CAST(NEW.committed_at/86400 AS INTEGER)*86400
      AND p.committed_at<(CAST(NEW.committed_at/86400 AS INTEGER)+1)*86400)>=5
    THEN RAISE(ABORT,'group_photo_daily_limit') END;
END;
