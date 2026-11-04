-- Notification state only. No admission or owner data changes.
CREATE TABLE pa_intake_notification (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 observed_kind TEXT NOT NULL DEFAULT 'normal',
 delivered_kind TEXT NOT NULL DEFAULT 'normal',
 lease_token TEXT,
 lease_until INTEGER NOT NULL DEFAULT 0,
 next_attempt INTEGER NOT NULL DEFAULT 0
);
INSERT INTO pa_intake_notification(singleton) VALUES(1);
