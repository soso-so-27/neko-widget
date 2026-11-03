-- Additive queue: preserve the existing receipt and day-five reminder identities.
-- No deployment or mail configuration is enabled by this migration.
CREATE TABLE group_report_first_day_mail (
 id TEXT PRIMARY KEY, report_id TEXT NOT NULL UNIQUE REFERENCES group_report_records(report_id) ON DELETE CASCADE,
 kind TEXT NOT NULL DEFAULT 'undecided' CHECK(kind='undecided'),
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN('pending','leased','sent','cancelled')),
 attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0), available_at INTEGER NOT NULL,
 lease_token TEXT, lease_until INTEGER, sent_at INTEGER
) STRICT;
CREATE INDEX group_report_first_day_due ON group_report_first_day_mail(state,available_at);
CREATE TRIGGER group_report_first_day_identity BEFORE UPDATE ON group_report_first_day_mail BEGIN
 SELECT (CASE WHEN NEW.id<>OLD.id OR NEW.report_id<>OLD.report_id OR NEW.kind<>OLD.kind THEN RAISE(ABORT,'mail_identity_immutable') END);
END;
