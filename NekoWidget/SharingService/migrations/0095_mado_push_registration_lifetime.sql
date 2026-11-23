PRAGMA foreign_keys = ON;

-- Keep the existing subscription rows and the legacy timestamp columns.
-- Only the window APNs subscription age stops controlling eligibility.
DROP TRIGGER notification_events_create_deliveries;

CREATE TRIGGER notification_events_create_deliveries
AFTER INSERT ON notification_events
BEGIN
    INSERT INTO notification_deliveries(
      event_id, device_id, token_digest, state, attempts,
      next_attempt_at, updated_at
    )
    SELECT NEW.id, MIN(subscription.device_id), subscription.token_digest,
           'pending', 0, NEW.created_at, NEW.created_at
      FROM apns_subscriptions AS subscription
      JOIN moment_devices AS device ON device.id = subscription.device_id
     WHERE subscription.participant_id = NEW.participant_id
       AND device.state = 'active'
     GROUP BY subscription.token_digest;
END;

-- Keep the previous group views available for a Worker rollback.
-- Blank ciphertext is an existing tombstone, even if its timestamp is positive.
CREATE VIEW group_current_push_deliveries AS
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
  AND e.expires_at>unixepoch() AND s.expires_at>0 AND s.token_ciphertext<>''
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

CREATE VIEW group_current_admission_recipients AS
SELECT j.id||'-requested' AS event_id,j.id AS request_id,j.space_id,'join_requested' AS kind,
 s.device_id,s.token_digest,s.generation AS subscription_generation,s.token_ciphertext,s.token_nonce,s.encryption_key_id,s.environment,j.expires_at
FROM group_join_requests j JOIN group_invitations i ON i.id=j.invitation_id
JOIN group_windows w ON w.space_id=j.space_id
JOIN group_members m ON m.space_id=w.space_id AND m.person_id=w.owner_person_id AND m.role='owner' AND m.state='active'
JOIN group_window_devices wd ON wd.space_id=w.space_id AND wd.participant_id=m.participant_id AND wd.state='active'
JOIN group_push_subscriptions s ON s.space_id=wd.space_id AND s.device_id=wd.device_id
JOIN group_person_devices d ON d.id=s.device_id AND d.state='active'
JOIN group_people p ON p.id=d.person_id AND p.state='active'
JOIN group_person_devices applicant ON applicant.id=j.candidate_device_id AND applicant.person_id=j.person_id AND applicant.state='active'
JOIN group_people ap ON ap.id=j.person_id AND ap.state='active'
WHERE j.state='pending' AND w.mode='active' AND i.revoked_at IS NULL AND i.expires_at>unixepoch()
 AND j.expires_at>unixepoch() AND s.expires_at>0 AND s.token_ciphertext<>''
UNION ALL
SELECT j.id||'-approved',j.id,j.space_id,'join_approved',s.device_id,s.token_digest,s.generation,
 s.token_ciphertext,s.token_nonce,s.encryption_key_id,s.environment,j.expires_at
FROM group_join_requests j JOIN group_windows w ON w.space_id=j.space_id
JOIN group_join_push_subscriptions s ON s.space_id=j.space_id AND s.device_id=j.candidate_device_id
JOIN group_window_devices wd ON wd.space_id=j.space_id AND wd.device_id=j.candidate_device_id AND wd.state='active'
JOIN group_members m ON m.space_id=j.space_id AND m.participant_id=wd.participant_id AND m.person_id=j.person_id AND m.state='active'
JOIN group_person_devices d ON d.id=s.device_id AND d.person_id=m.person_id AND d.state='active'
JOIN group_people p ON p.id=d.person_id AND p.state='active'
WHERE j.state='approved' AND w.mode='active' AND j.expires_at>unixepoch() AND s.expires_at>unixepoch()
 AND wd.added_revision=j.result_revision;
