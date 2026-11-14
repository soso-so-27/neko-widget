-- Indexes only; no queue state, payload or gate changes.
CREATE INDEX group_notification_cohort ON group_notification_events(space_id,kind,created_at,id);
CREATE INDEX group_notification_recipient_state ON group_notification_deliveries(device_id,token_digest,subscription_generation,state,event_id);
