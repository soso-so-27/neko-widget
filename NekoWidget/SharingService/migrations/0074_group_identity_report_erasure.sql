-- Compute ownership only from surviving business records. This view stores
-- no person-to-report index. A record with no surviving link is out of scope.
CREATE VIEW group_identity_report_subjects AS
 SELECT id AS report_id,reporter_person_id AS person_id FROM group_reports
 UNION SELECT r.id,m.person_id FROM group_reports r JOIN group_members m
   ON m.space_id=r.space_id AND m.participant_id=r.accused_participant_id
 UNION SELECT report_id,reporter_person_id FROM group_report_records WHERE reporter_person_id IS NOT NULL
 UNION SELECT r.report_id,s.person_id FROM group_report_records r
   JOIN group_moments m ON m.id=r.moment_id AND m.space_id=r.space_id
   JOIN group_members s ON s.participant_id=m.sender_participant_id AND s.space_id=m.space_id
 UNION SELECT c.report_id,x.target_id FROM group_moderation_cases c
   JOIN group_moderation_restrictions x ON x.case_reference=c.case_reference AND x.target_kind='person';
CREATE VIEW group_identity_report_candidates AS
 SELECT s.person_id,n.report_id,COALESCE(r.created_at,h.committed_at,c.created_at,n.created_at) AS created_at,
 COALESCE(h.revision,-1) AS record_revision,COALESCE(c.revision,-1) AS case_revision,
 COALESCE(h.outcome,'absent') AS record_outcome,COALESCE(c.outcome,'absent') AS case_outcome
 FROM group_identity_report_subjects s JOIN group_report_numbers n USING(report_id)
 LEFT JOIN group_reports r ON r.id=n.report_id
 LEFT JOIN group_report_records h ON h.report_id=n.report_id
 LEFT JOIN group_moderation_cases c ON c.report_id=n.report_id
 WHERE COALESCE(h.outcome,'received') IN ('received','no_action','release')
 AND COALESCE(c.outcome,'received') IN ('received','no_action','release')
 AND NOT EXISTS(SELECT 1 FROM group_moderation_restrictions x WHERE x.active=1
  AND (x.case_reference='deadline:'||n.report_id OR x.case_reference=c.case_reference));
-- Only an in-flight request locator and its outstanding object cleanup. It is
-- removed after the exact moderation object is confirmed absent.
CREATE TABLE group_identity_report_object_work (
 request_id TEXT NOT NULL,report_id TEXT NOT NULL,object_key TEXT NOT NULL,
 PRIMARY KEY(request_id,report_id,object_key)
) STRICT;
-- Written atomically with the original D1 erasure, after the independent
-- work slot fixes this nonce. The earlier freeze anchor alone cannot resume
-- a destructive scan. Cleared once the global checkpoint reflects completion.
CREATE TABLE group_identity_report_seals (
 request_id TEXT PRIMARY KEY,nonce TEXT NOT NULL UNIQUE
) STRICT;
CREATE TRIGGER group_identity_report_seal_no_update BEFORE UPDATE ON group_identity_report_seals
BEGIN SELECT RAISE(ABORT,'immutable_report_seal'); END;
-- A transient authorization scoped to one verified fence and one report.
CREATE TABLE group_identity_report_erase_commands (
 report_id TEXT PRIMARY KEY,person_id TEXT NOT NULL,request_id TEXT NOT NULL,
 accepted_at INTEGER NOT NULL,record_revision INTEGER NOT NULL,case_revision INTEGER NOT NULL,record_outcome TEXT NOT NULL,case_outcome TEXT NOT NULL
) STRICT;
CREATE TRIGGER group_identity_report_erase_guard BEFORE INSERT ON group_identity_report_erase_commands BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM group_identity_report_seals s
 JOIN group_identity_deletion_acceptance a ON a.request_id=s.request_id AND a.nonce=s.nonce
 WHERE s.request_id=NEW.request_id AND a.subject_id=NEW.person_id AND a.accepted_at=NEW.accepted_at)
 THEN RAISE(ABORT,'identity_report_seal_missing') END);
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM group_identity_report_candidates
 WHERE person_id=NEW.person_id AND report_id=NEW.report_id AND created_at<=NEW.accepted_at
 AND record_revision=NEW.record_revision AND case_revision=NEW.case_revision
 AND record_outcome=NEW.record_outcome AND case_outcome=NEW.case_outcome)
 THEN RAISE(ABORT,'identity_report_eligibility_changed') END);
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM (
  SELECT object_key FROM group_reports WHERE id=NEW.report_id
  UNION SELECT object_key FROM group_report_object_deletions WHERE report_id=NEW.report_id) WHERE
  length(NEW.report_id)<>22 OR NEW.report_id GLOB '*[^A-Za-z0-9_-]*'
  OR substr(object_key,1,length('groups/reports/v3/'||NEW.report_id||'/'))<>'groups/reports/v3/'||NEW.report_id||'/'
  OR length(object_key)<>length('groups/reports/v3/'||NEW.report_id||'/')+32 OR substr(object_key,-32) GLOB '*[^A-Za-z0-9_-]*')
 THEN RAISE(ABORT,'invalid_identity_report_object') END);
END;
DROP VIEW group_report_purge_allowed;
CREATE VIEW group_report_purge_allowed AS
 SELECT p.report_id FROM group_report_purge_tickets p JOIN group_report_retention_due r
 ON r.report_id=p.report_id AND r.revision=p.revision
 UNION SELECT report_id FROM group_identity_report_erase_commands;
CREATE TRIGGER group_identity_report_erase_apply AFTER INSERT ON group_identity_report_erase_commands BEGIN
 INSERT INTO group_identity_report_object_work
 SELECT NEW.request_id,id,object_key FROM group_reports WHERE id=NEW.report_id
 UNION SELECT NEW.request_id,report_id,object_key FROM group_report_object_deletions WHERE report_id=NEW.report_id;
 DELETE FROM group_report_events WHERE report_id=NEW.report_id;
 DELETE FROM group_moderation_decisions WHERE case_reference IN (SELECT case_reference FROM group_moderation_cases WHERE report_id=NEW.report_id);
 DELETE FROM group_moderation_receipts WHERE challenge_id IN (SELECT id FROM group_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM group_moderation_cases WHERE report_id=NEW.report_id));
 DELETE FROM group_moderation_read_events WHERE challenge_id IN (SELECT id FROM group_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM group_moderation_cases WHERE report_id=NEW.report_id));
 DELETE FROM group_moderation_consumptions WHERE challenge_id IN (SELECT id FROM group_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM group_moderation_cases WHERE report_id=NEW.report_id));
 DELETE FROM group_moderation_attempts WHERE challenge_id IN (SELECT id FROM group_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM group_moderation_cases WHERE report_id=NEW.report_id));

 DELETE FROM group_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM group_moderation_cases WHERE report_id=NEW.report_id);
 DELETE FROM group_moderation_restrictions WHERE active=0 AND (case_reference='deadline:'||NEW.report_id
  OR case_reference IN (SELECT case_reference FROM group_moderation_cases WHERE report_id=NEW.report_id));
 DELETE FROM group_moderation_cases WHERE report_id=NEW.report_id;
 DELETE FROM group_report_mail_outbox WHERE report_id=NEW.report_id;
 DELETE FROM group_report_records WHERE report_id=NEW.report_id;
 DELETE FROM group_mutations WHERE json_valid(response_json) AND json_extract(response_json,'$.report.id')=NEW.report_id;
 DELETE FROM group_reports WHERE id=NEW.report_id;
 DELETE FROM group_report_numbers WHERE report_id=NEW.report_id;
 DELETE FROM group_report_purge_tickets WHERE report_id=NEW.report_id;
 DELETE FROM group_identity_report_erase_commands WHERE report_id=NEW.report_id;
END;
