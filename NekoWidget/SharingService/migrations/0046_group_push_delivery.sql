PRAGMA foreign_keys = ON;

-- Additive only; does not rewrite existing events, subscriptions, runtime
-- switches, credentials or legacy tables. Remote application needs approval.
-- Keep an operation binding outside the old event table so old Workers can
-- continue inserting their eight-column events during a rolling deployment.
CREATE TABLE group_heart_notification_operations (
  event_id TEXT PRIMARY KEY REFERENCES group_notification_events(id) ON DELETE CASCADE,
  operation_id TEXT NOT NULL
) STRICT;
CREATE TABLE group_push_checks (
  id TEXT PRIMARY KEY,
  gate_generation INTEGER NOT NULL
) STRICT;
CREATE TRIGGER group_push_check BEFORE INSERT ON group_push_checks
BEGIN
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM personal_staging_runtime_gate
    WHERE singleton=1 AND generation=NEW.gate_generation AND media_enabled=1 AND apns_enabled=1)
    THEN RAISE(ABORT,'group_push_gate_closed') END;
END;

-- This live view is re-read AFTER token decryption, immediately before APNs.
-- A new roster generation does not retroactively admit a phone to old photos.
CREATE VIEW group_live_push_deliveries AS
SELECT q.event_id,q.device_id,q.token_digest,q.subscription_generation,
  s.token_ciphertext,s.token_nonce,s.encryption_key_id,s.environment,
  e.space_id,e.moment_id,e.kind,e.expires_at
FROM group_notification_deliveries q JOIN group_notification_events e ON e.id=q.event_id
JOIN group_push_subscriptions s ON s.space_id=e.space_id AND s.device_id=q.device_id
JOIN group_windows w ON w.space_id=e.space_id
JOIN group_moments photo ON photo.id=e.moment_id AND photo.space_id=e.space_id
JOIN group_moment_deliveries delivery ON delivery.moment_id=photo.id AND delivery.device_id=q.device_id
JOIN group_window_devices recipient ON recipient.space_id=e.space_id AND recipient.device_id=q.device_id
JOIN group_members member ON member.participant_id=recipient.participant_id AND member.space_id=e.space_id
JOIN group_person_devices device ON device.id=recipient.device_id AND device.person_id=member.person_id
JOIN group_people person ON person.id=member.person_id
JOIN group_window_devices actor ON actor.space_id=e.space_id AND actor.device_id=e.actor_device_id AND actor.participant_id=e.actor_participant_id
JOIN group_members actor_member ON actor_member.participant_id=actor.participant_id AND actor_member.space_id=e.space_id
JOIN group_person_devices actor_device ON actor_device.id=actor.device_id AND actor_device.person_id=actor_member.person_id
JOIN group_people actor_person ON actor_person.id=actor_member.person_id
WHERE w.mode='active' AND photo.state='committed' AND photo.unreceived_expires_at>unixepoch()
  AND e.expires_at>unixepoch() AND s.expires_at>unixepoch()
  AND s.token_digest=q.token_digest AND s.generation=q.subscription_generation
  AND recipient.state='active' AND member.state='active' AND device.state='active' AND person.state='active'
  AND actor.state='active' AND actor_member.state='active' AND actor_device.state='active' AND actor_person.state='active'
  AND delivery.participant_id=recipient.participant_id AND delivery.state IN ('pending','acknowledged') AND delivery.access_expires_at>unixepoch()
  AND delivery.roster_revision>=recipient.added_revision AND delivery.roster_revision>=member.joined_revision
  AND NOT EXISTS (SELECT 1 FROM group_participant_blocks b WHERE b.space_id=e.space_id AND b.active=1
    AND ((b.blocker_id=member.participant_id AND b.blocked_id IN (e.actor_participant_id,photo.sender_participant_id))
      OR (b.blocked_id=member.participant_id AND b.blocker_id IN (e.actor_participant_id,photo.sender_participant_id))))
  AND (e.kind='new_moment' OR EXISTS (SELECT 1 FROM group_moment_hearts h
    JOIN group_heart_notification_operations op ON op.event_id=e.id AND op.operation_id=h.operation_id
    WHERE h.moment_id=photo.id AND h.participant_id=e.actor_participant_id AND h.device_id=e.actor_device_id
      AND h.active=1 AND member.participant_id=photo.sender_participant_id));
