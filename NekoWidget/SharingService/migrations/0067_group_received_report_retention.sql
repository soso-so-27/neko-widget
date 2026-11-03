-- Accepted undecided records expire after 30 elapsed days, including while
-- enforcement is OFF. Seven-day evidence expiry and terminal one-year policy
-- are unchanged. Current stops always invalidate this deletion authority.
CREATE INDEX group_report_received_retention ON group_report_records(committed_at,report_id)
 WHERE outcome='received';
CREATE VIEW group_report_retention_due AS
 SELECT r.report_id,r.revision,
  (CASE WHEN r.outcome='received' THEN r.committed_at+2592000 ELSE r.retention_until END) AS due_at
 FROM group_report_records r
 WHERE ((r.outcome='received' AND r.committed_at+2592000<=unixepoch())
  OR (r.outcome IN('no_action','release') AND r.retention_until<=unixepoch()))
 AND NOT EXISTS(SELECT 1 FROM group_moderation_restrictions x WHERE x.active=1 AND
  (x.case_reference='deadline:'||r.report_id OR x.case_reference IN
   (SELECT case_reference FROM group_moderation_cases WHERE report_id=r.report_id)));

DROP VIEW group_report_purge_allowed;
CREATE VIEW group_report_purge_allowed AS
 SELECT p.report_id FROM group_report_purge_tickets p
 JOIN group_report_retention_due r ON r.report_id=p.report_id AND r.revision=p.revision;
DROP TRIGGER group_report_purge_ticket_guard;
CREATE TRIGGER group_report_purge_ticket_guard BEFORE INSERT ON group_report_purge_tickets BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM group_report_retention_due r
  WHERE r.report_id=NEW.report_id AND r.revision=NEW.revision)
  THEN RAISE(ABORT,'retention_not_due') END);
END;
