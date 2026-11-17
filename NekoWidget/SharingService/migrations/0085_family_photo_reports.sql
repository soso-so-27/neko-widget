-- Family-photo moderation is separate from notebook history and window photos.
-- Additive, empty tables only. No gate or existing business row is changed.
CREATE TABLE family_photo_report_deliveries (
 family_id TEXT NOT NULL, asset_id TEXT NOT NULL, person_id TEXT NOT NULL,
 device_id TEXT NOT NULL, author_id TEXT NOT NULL, expires_at INTEGER NOT NULL,
 PRIMARY KEY(family_id,asset_id,device_id)
) STRICT;
CREATE TABLE family_photo_reports (
 report_id TEXT PRIMARY KEY, family_id TEXT NOT NULL, asset_id TEXT NOT NULL,
 reporter_person_id TEXT NOT NULL, reporter_device_id TEXT NOT NULL, author_id TEXT NOT NULL,
 operation_id TEXT NOT NULL, request_hash TEXT NOT NULL,
 reason_code TEXT NOT NULL CHECK(reason_code IN('objectionable','harassment','privacy','other')),
 moderation_key_id TEXT NOT NULL CHECK(moderation_key_id='moderation-v2'),
 ciphertext_size INTEGER NOT NULL CHECK(ciphertext_size BETWEEN 29 AND 1048576),
 ciphertext_sha256 TEXT NOT NULL CHECK(length(ciphertext_sha256)=43),
 object_key TEXT NOT NULL UNIQUE, state TEXT NOT NULL CHECK(state IN('reserved','committed','expired')),
 created_at INTEGER NOT NULL, upload_expires_at INTEGER NOT NULL,
 committed_at INTEGER, content_expires_at INTEGER, next_cleanup_at INTEGER NOT NULL DEFAULT 0,
 UNIQUE(reporter_device_id,operation_id), UNIQUE(family_id,asset_id,reporter_person_id),
 CHECK(upload_expires_at=created_at+3600),
 CHECK((committed_at IS NULL AND content_expires_at IS NULL) OR content_expires_at=committed_at+604800)
) STRICT;
CREATE TRIGGER family_photo_report_delivery_guard BEFORE INSERT ON family_photo_reports BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_report_deliveries d
 WHERE d.family_id=NEW.family_id AND d.asset_id=NEW.asset_id AND d.device_id=NEW.reporter_device_id
 AND d.person_id=NEW.reporter_person_id AND d.author_id=NEW.author_id AND d.author_id<>d.person_id
 AND d.expires_at>unixepoch()) THEN RAISE(ABORT,'family_photo_not_delivered') END);
 SELECT (CASE WHEN (SELECT COUNT(*) FROM family_photo_reports WHERE reporter_person_id=NEW.reporter_person_id
 AND created_at>=unixepoch()-86400)>=10 THEN RAISE(ABORT,'family_photo_report_quota') END);
END;
CREATE TABLE family_photo_report_records (
 report_id TEXT PRIMARY KEY,
 family_id TEXT NOT NULL, asset_id TEXT NOT NULL,
 committed_at INTEGER NOT NULL, evidence_expires_at INTEGER NOT NULL,
 revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),
 retention_until INTEGER DEFAULT(unixepoch()+2592000),
 outcome TEXT NOT NULL DEFAULT 'received' CHECK(outcome IN('received','photo','no_action','release')),
 CHECK(evidence_expires_at=committed_at+604800)
) STRICT;
CREATE TABLE family_photo_report_reminders (
 report_id TEXT NOT NULL REFERENCES family_photo_report_records(report_id),
 day INTEGER NOT NULL CHECK(day IN(0,1,5)),
 available_at INTEGER NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN('pending','sent','cancelled')),
 PRIMARY KEY(report_id,day)
) STRICT;
CREATE TABLE family_photo_report_deadlines (
 report_id TEXT PRIMARY KEY REFERENCES family_photo_report_records(report_id),
 family_id TEXT NOT NULL, asset_id TEXT NOT NULL,
 applied_at INTEGER NOT NULL
) STRICT;
CREATE TRIGGER family_photo_report_deadline_guard BEFORE INSERT ON family_photo_report_deadlines BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_report_records r
 WHERE r.report_id=NEW.report_id AND r.family_id=NEW.family_id AND r.asset_id=NEW.asset_id
 AND r.outcome='received' AND r.revision=0 AND r.evidence_expires_at<=unixepoch()
 AND NEW.applied_at=unixepoch()) THEN RAISE(ABORT,'family_photo_deadline_not_due') END);
END;
CREATE TRIGGER family_photo_report_deadline_apply AFTER INSERT ON family_photo_report_deadlines BEGIN
 UPDATE family_photo_report_records SET revision=revision+1,outcome='photo',retention_until=NULL WHERE report_id=NEW.report_id;
 UPDATE family_photo_report_reminders SET state='cancelled' WHERE report_id=NEW.report_id AND state='pending';
END;
CREATE TRIGGER family_photo_report_target_immutable BEFORE UPDATE ON family_photo_report_records BEGIN
 SELECT (CASE WHEN NEW.report_id<>OLD.report_id OR NEW.family_id<>OLD.family_id OR NEW.asset_id<>OLD.asset_id
 OR NEW.committed_at<>OLD.committed_at OR NEW.evidence_expires_at<>OLD.evidence_expires_at
 THEN RAISE(ABORT,'family_photo_report_target_immutable') END);
END;
CREATE TRIGGER family_photo_report_deadline_immutable BEFORE UPDATE ON family_photo_report_deadlines BEGIN
 SELECT RAISE(ABORT,'append_only');
END;
CREATE TRIGGER family_photo_report_deadline_no_delete BEFORE DELETE ON family_photo_report_deadlines BEGIN
 SELECT RAISE(ABORT,'append_only');
END;
CREATE INDEX family_photo_report_due ON family_photo_report_records(outcome,evidence_expires_at);
CREATE TRIGGER family_photo_report_committed AFTER UPDATE OF state ON family_photo_reports
 WHEN NEW.state='committed' AND OLD.state='reserved' BEGIN
 INSERT INTO family_photo_report_records(report_id,family_id,asset_id,committed_at,evidence_expires_at)
 VALUES(NEW.report_id,NEW.family_id,NEW.asset_id,NEW.committed_at,NEW.content_expires_at);
 INSERT INTO family_photo_report_reminders(report_id,day,available_at) VALUES(NEW.report_id,0,NEW.committed_at);
END;
CREATE TRIGGER family_photo_report_evidence_immutable BEFORE UPDATE ON family_photo_reports BEGIN
 SELECT (CASE WHEN NEW.report_id<>OLD.report_id OR NEW.family_id<>OLD.family_id OR NEW.asset_id<>OLD.asset_id
 OR NEW.reporter_person_id<>OLD.reporter_person_id OR NEW.reporter_device_id<>OLD.reporter_device_id
 OR NEW.author_id<>OLD.author_id OR NEW.operation_id<>OLD.operation_id OR NEW.request_hash<>OLD.request_hash
 OR NEW.reason_code<>OLD.reason_code OR NEW.moderation_key_id<>OLD.moderation_key_id
 OR NEW.ciphertext_size<>OLD.ciphertext_size OR NEW.ciphertext_sha256<>OLD.ciphertext_sha256
 OR NEW.object_key<>OLD.object_key OR NEW.created_at<>OLD.created_at OR NEW.upload_expires_at<>OLD.upload_expires_at
 OR (OLD.committed_at IS NOT NULL AND (NEW.committed_at IS NOT OLD.committed_at OR NEW.content_expires_at IS NOT OLD.content_expires_at))
 OR (OLD.state='committed' AND NEW.state NOT IN('committed','expired')) OR (OLD.state='expired' AND NEW.state<>'expired')
 THEN RAISE(ABORT,'family_photo_report_evidence_immutable') END);
END;

-- Additive operator-only workflow. No public runtime or authority is enabled.
CREATE TABLE family_photo_moderation_cases (
 case_reference TEXT PRIMARY KEY CHECK(length(case_reference)=64),
 -- Opaque audit reference only: never pin expiring report metadata via an FK.
 report_id TEXT NOT NULL UNIQUE,
 key_version INTEGER NOT NULL CHECK(key_version=1),
 revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),
 outcome TEXT NOT NULL DEFAULT 'received' CHECK(outcome IN('received','no_action','photo','release')),
 created_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE family_photo_moderation_challenges (
 id TEXT PRIMARY KEY, operator_id TEXT NOT NULL, credential_id_sha256 TEXT NOT NULL,
 enrollment_admission_id TEXT NOT NULL, access_session_sha256 TEXT NOT NULL,
 policy_revision INTEGER NOT NULL, value_sha256 TEXT NOT NULL,
 case_reference TEXT REFERENCES family_photo_moderation_cases(case_reference),
 case_revision INTEGER, source_sha256 TEXT, receipt_id TEXT,
 action TEXT NOT NULL CHECK(action IN('queue','read','no_action','photo','release')),
 queue_after INTEGER NOT NULL DEFAULT 0 CHECK(queue_after>=0),
 created_at INTEGER NOT NULL DEFAULT(unixepoch()), expires_at INTEGER NOT NULL CHECK(expires_at>created_at)
) STRICT;
CREATE TABLE family_photo_moderation_attempts (
 challenge_id TEXT PRIMARY KEY REFERENCES family_photo_moderation_challenges(id), assertion_sha256 TEXT NOT NULL,
 created_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE family_photo_moderation_consumptions (
 challenge_id TEXT PRIMARY KEY REFERENCES family_photo_moderation_attempts(challenge_id),
 assertion_sha256 TEXT NOT NULL, authenticator_sign_count INTEGER NOT NULL CHECK(authenticator_sign_count>=0),
 created_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE family_photo_moderation_read_events (
 challenge_id TEXT NOT NULL REFERENCES family_photo_moderation_consumptions(challenge_id),
 phase TEXT NOT NULL CHECK(phase IN('started','disclosure_ready','delivered')),
 created_at INTEGER NOT NULL DEFAULT(unixepoch()), PRIMARY KEY(challenge_id,phase)
) STRICT;
CREATE TABLE family_photo_moderation_receipts (
 id TEXT PRIMARY KEY, challenge_id TEXT NOT NULL UNIQUE REFERENCES family_photo_moderation_consumptions(challenge_id),
 expires_at INTEGER NOT NULL
) STRICT;
CREATE TABLE family_photo_moderation_decisions (
 id TEXT PRIMARY KEY, challenge_id TEXT NOT NULL UNIQUE REFERENCES family_photo_moderation_consumptions(challenge_id),
 case_reference TEXT NOT NULL REFERENCES family_photo_moderation_cases(case_reference),
 revision INTEGER NOT NULL CHECK(revision>0),
 outcome TEXT NOT NULL CHECK(outcome IN('no_action','photo','release')),
 reply_template TEXT NOT NULL CHECK(reply_template IN('review_no_action_v1','review_restricted_v1','review_released_v1')),
 created_at INTEGER NOT NULL DEFAULT(unixepoch()), UNIQUE(case_reference,revision)
) STRICT;
CREATE TRIGGER family_photo_moderation_consumption_guard BEFORE INSERT ON family_photo_moderation_consumptions BEGIN
 SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM family_photo_moderation_challenges c JOIN family_photo_moderation_attempts a ON a.challenge_id=c.id
   JOIN moderation_operator_credential_counters counter ON counter.credential_id_sha256=c.credential_id_sha256
   WHERE c.id=NEW.challenge_id AND a.assertion_sha256=NEW.assertion_sha256 AND c.expires_at>unixepoch()
    AND ((counter.sign_count=0 AND NEW.authenticator_sign_count=0) OR NEW.authenticator_sign_count>counter.sign_count))
   THEN RAISE(ABORT,'family_photo_moderation_proof_not_current') END);
END;
CREATE TRIGGER family_photo_moderation_challenge_quota BEFORE INSERT ON family_photo_moderation_challenges BEGIN
 SELECT (CASE WHEN (SELECT COUNT(*) FROM family_photo_moderation_challenges WHERE operator_id=NEW.operator_id AND created_at>unixepoch()-300)>=40
 THEN RAISE(ABORT,'family_photo_moderation_quota') END);
END;
CREATE TRIGGER family_photo_moderation_receipt_guard BEFORE INSERT ON family_photo_moderation_receipts BEGIN
 SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM family_photo_moderation_challenges c WHERE c.id=NEW.challenge_id AND c.action='read' AND c.expires_at>unixepoch())
  OR (SELECT COUNT(*) FROM family_photo_moderation_read_events WHERE challenge_id=NEW.challenge_id)!=3
 THEN RAISE(ABORT,'family_photo_moderation_disclosure_incomplete') END);
END;
CREATE TRIGGER family_photo_moderation_decision_guard BEFORE INSERT ON family_photo_moderation_decisions BEGIN
 SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM family_photo_moderation_challenges c JOIN family_photo_moderation_cases k ON k.case_reference=c.case_reference
  WHERE c.id=NEW.challenge_id AND c.case_reference=NEW.case_reference AND c.case_revision=k.revision AND NEW.revision=k.revision+1
   AND NEW.outcome=c.action AND c.expires_at>unixepoch()
   AND (c.action='release' OR EXISTS(SELECT 1 FROM family_photo_moderation_receipts r JOIN family_photo_moderation_challenges read ON read.id=r.challenge_id
     WHERE r.id=c.receipt_id AND r.expires_at>unixepoch() AND read.case_reference=c.case_reference AND read.case_revision=c.case_revision
       AND read.source_sha256=c.source_sha256 AND read.operator_id=c.operator_id AND read.access_session_sha256=c.access_session_sha256)))
 THEN RAISE(ABORT,'family_photo_moderation_decision_not_current') END);
END;
CREATE TRIGGER family_photo_moderation_decisions_no_update BEFORE UPDATE ON family_photo_moderation_decisions BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER family_photo_moderation_decisions_no_delete BEFORE DELETE ON family_photo_moderation_decisions BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER family_photo_moderation_challenges_no_update BEFORE UPDATE ON family_photo_moderation_challenges BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER family_photo_moderation_challenges_no_delete BEFORE DELETE ON family_photo_moderation_challenges BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER family_photo_moderation_consumptions_no_update BEFORE UPDATE ON family_photo_moderation_consumptions BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER family_photo_moderation_consumptions_no_delete BEFORE DELETE ON family_photo_moderation_consumptions BEGIN SELECT RAISE(ABORT,'append_only'); END;

DROP VIEW moderation_operator_credential_counters;
CREATE VIEW moderation_operator_credential_counters AS SELECT credential_id_sha256,MAX(sign_count) AS sign_count FROM (
 SELECT credential_id_sha256,sign_count FROM (
 SELECT credential_id_sha256,sign_count FROM (
 SELECT credential_id_sha256,sign_count FROM (
 SELECT credential_id_sha256,sign_count FROM (
 SELECT credential_id_sha256,registration_sign_count AS sign_count FROM moderation_operator_credentials
 UNION ALL SELECT credential_id_sha256,authenticator_sign_count FROM moderation_operator_challenge_consumptions
 UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM moderation_owner_challenge_consumptions r JOIN moderation_owner_challenges c USING(challenge_id)
 UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM moderation_resolution_consumptions r JOIN moderation_resolution_challenges c USING(challenge_id)
 UNION ALL SELECT credential_id_sha256,authenticator_sign_count FROM moderation_operator_enrollment_ceremony_possessions
 )
 UNION ALL SELECT q.target_credential_id_sha256,s.counter_floor FROM moderation_owner_scope_adoptions s JOIN moderation_operator_enrollment_requests q USING(enrollment_request_id)
 )
 UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM group_moderation_consumptions r JOIN group_moderation_challenges c ON c.id=r.challenge_id
 )
 UNION ALL SELECT credential_id_sha256,sign_count FROM group_operator_counter_floors
)
 UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM group_invitation_consumptions r JOIN group_invitation_challenges c ON c.id=r.challenge_id
 UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM family_photo_moderation_consumptions r JOIN family_photo_moderation_challenges c ON c.id=r.challenge_id
) GROUP BY credential_id_sha256;

CREATE TRIGGER family_photo_moderation_decision_apply AFTER INSERT ON family_photo_moderation_decisions BEGIN
 UPDATE family_photo_report_records SET revision=NEW.revision,outcome=NEW.outcome,
 retention_until=(CASE WHEN NEW.outcome='photo' THEN NULL ELSE unixepoch('now','+1 year') END)
 WHERE report_id=(SELECT report_id FROM family_photo_moderation_cases WHERE case_reference=NEW.case_reference);
 UPDATE family_photo_moderation_cases SET revision=NEW.revision,outcome=NEW.outcome WHERE case_reference=NEW.case_reference;
 UPDATE family_photo_report_reminders SET state='cancelled' WHERE state='pending'
 AND report_id=(SELECT report_id FROM family_photo_moderation_cases WHERE case_reference=NEW.case_reference);
END;
CREATE TRIGGER family_photo_deadline_case_sync AFTER UPDATE OF revision ON family_photo_report_records BEGIN
 UPDATE family_photo_moderation_cases SET revision=NEW.revision,outcome=NEW.outcome WHERE report_id=NEW.report_id;
END;

CREATE VIEW group_identity_window_report_candidates AS
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
DROP VIEW group_identity_report_candidates;
CREATE VIEW group_identity_report_candidates AS
 SELECT * FROM group_identity_window_report_candidates
 UNION SELECT s.person_id,'family:'||e.report_id,e.created_at,COALESCE(r.revision,-1),COALESCE(c.revision,-1),
 COALESCE(r.outcome,'absent'),COALESCE(c.outcome,'absent')
 FROM family_photo_reports e JOIN (
  SELECT report_id,reporter_person_id AS person_id FROM family_photo_reports
  UNION SELECT report_id,author_id FROM family_photo_reports
 ) s USING(report_id)
 LEFT JOIN family_photo_report_records r USING(report_id)
 LEFT JOIN family_photo_moderation_cases c USING(report_id)
 WHERE COALESCE(r.outcome,'received') IN('received','no_action','release')
 AND COALESCE(c.outcome,'received') IN('received','no_action','release');
CREATE TABLE family_photo_report_purge_tickets(report_id TEXT PRIMARY KEY,revision INTEGER NOT NULL) STRICT;
CREATE TRIGGER family_photo_report_purge_ticket_guard BEFORE INSERT ON family_photo_report_purge_tickets BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_report_records r WHERE r.report_id=NEW.report_id
 AND r.revision=NEW.revision AND r.outcome<>'photo' AND r.retention_until<=unixepoch())
 THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE VIEW family_photo_report_purge_allowed AS
 SELECT t.report_id FROM family_photo_report_purge_tickets t JOIN family_photo_report_records r USING(report_id)
 WHERE t.revision=r.revision AND r.outcome<>'photo' AND r.retention_until<=unixepoch()
 UNION SELECT substr(report_id,8) FROM group_identity_report_erase_commands WHERE substr(report_id,1,7)='family:';
CREATE VIEW family_photo_moderation_purge_challenges AS SELECT q.id FROM family_photo_moderation_challenges q
 WHERE (q.case_reference IS NULL AND q.expires_at+172800<=unixepoch()) OR EXISTS(
 SELECT 1 FROM family_photo_report_purge_allowed p JOIN family_photo_moderation_cases c USING(report_id)
 WHERE c.case_reference=q.case_reference);
DROP TRIGGER family_photo_moderation_decisions_no_delete;
DROP TRIGGER family_photo_moderation_challenges_no_delete;
DROP TRIGGER family_photo_moderation_consumptions_no_delete;
DROP TRIGGER family_photo_report_deadline_no_delete;
CREATE TRIGGER family_photo_moderation_decisions_retention BEFORE DELETE ON family_photo_moderation_decisions BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_report_purge_allowed p JOIN family_photo_moderation_cases c USING(report_id)
 WHERE c.case_reference=OLD.case_reference) THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE TRIGGER family_photo_moderation_cases_retention BEFORE DELETE ON family_photo_moderation_cases BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_report_purge_allowed p JOIN family_photo_moderation_cases c USING(report_id)
 WHERE c.case_reference=OLD.case_reference) THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE TRIGGER family_photo_moderation_challenges_retention BEFORE DELETE ON family_photo_moderation_challenges BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_moderation_purge_challenges WHERE id=OLD.id) THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE TRIGGER family_photo_moderation_consumptions_retention BEFORE DELETE ON family_photo_moderation_consumptions BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_moderation_purge_challenges WHERE id=OLD.challenge_id) THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE TRIGGER family_photo_moderation_attempts_retention BEFORE DELETE ON family_photo_moderation_attempts BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_moderation_purge_challenges WHERE id=OLD.challenge_id) THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE TRIGGER family_photo_moderation_read_events_retention BEFORE DELETE ON family_photo_moderation_read_events BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_moderation_purge_challenges WHERE id=OLD.challenge_id) THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE TRIGGER family_photo_moderation_receipts_retention BEFORE DELETE ON family_photo_moderation_receipts BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_moderation_purge_challenges WHERE id=OLD.challenge_id) THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE TRIGGER family_photo_report_records_retention BEFORE DELETE ON family_photo_report_records BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_report_purge_allowed WHERE report_id=OLD.report_id)
 THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE TRIGGER family_photo_report_deadlines_retention BEFORE DELETE ON family_photo_report_deadlines BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_report_purge_allowed WHERE report_id=OLD.report_id)
 THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE TRIGGER family_photo_report_reminders_retention BEFORE DELETE ON family_photo_report_reminders BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_photo_report_purge_allowed WHERE report_id=OLD.report_id)
 THEN RAISE(ABORT,'family_photo_retention_not_due') END);
END;
CREATE TRIGGER family_photo_operator_counter_floor_capture BEFORE DELETE ON family_photo_moderation_consumptions BEGIN
 INSERT INTO group_operator_counter_floors SELECT credential_id_sha256,OLD.authenticator_sign_count
 FROM family_photo_moderation_challenges WHERE id=OLD.challenge_id
 ON CONFLICT(credential_id_sha256) DO UPDATE SET sign_count=MAX(sign_count,excluded.sign_count);
END;
CREATE TRIGGER family_photo_delivery_identity_cleanup AFTER INSERT ON group_identity_deletion_acceptance BEGIN
 DELETE FROM family_photo_report_deliveries WHERE person_id=NEW.subject_id OR author_id=NEW.subject_id;
END;
CREATE TRIGGER family_photo_report_purge_apply AFTER INSERT ON family_photo_report_purge_tickets BEGIN
DELETE FROM family_photo_moderation_decisions WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=NEW.report_id);
DELETE FROM family_photo_moderation_receipts WHERE challenge_id IN (SELECT id FROM family_photo_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=NEW.report_id));
DELETE FROM family_photo_moderation_read_events WHERE challenge_id IN (SELECT id FROM family_photo_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=NEW.report_id));
DELETE FROM family_photo_moderation_consumptions WHERE challenge_id IN (SELECT id FROM family_photo_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=NEW.report_id));
DELETE FROM family_photo_moderation_attempts WHERE challenge_id IN (SELECT id FROM family_photo_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=NEW.report_id));
DELETE FROM family_photo_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=NEW.report_id);
DELETE FROM family_photo_moderation_cases WHERE report_id=NEW.report_id;
DELETE FROM family_photo_report_deadlines WHERE report_id=NEW.report_id;
DELETE FROM family_photo_report_reminders WHERE report_id=NEW.report_id;
DELETE FROM family_photo_report_records WHERE report_id=NEW.report_id;
DELETE FROM family_photo_report_purge_tickets WHERE report_id=NEW.report_id;
END;
DROP TRIGGER group_identity_report_erase_apply;
CREATE TRIGGER group_identity_report_erase_apply AFTER INSERT ON group_identity_report_erase_commands BEGIN

 INSERT INTO group_identity_report_object_work
 SELECT NEW.request_id,NEW.report_id,object_key FROM family_photo_reports
 WHERE 'family:'||report_id=NEW.report_id;
DELETE FROM family_photo_moderation_decisions WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=(CASE WHEN substr(NEW.report_id,1,7)='family:' THEN substr(NEW.report_id,8) ELSE NULL END));
DELETE FROM family_photo_moderation_receipts WHERE challenge_id IN (SELECT id FROM family_photo_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=(CASE WHEN substr(NEW.report_id,1,7)='family:' THEN substr(NEW.report_id,8) ELSE NULL END)));
DELETE FROM family_photo_moderation_read_events WHERE challenge_id IN (SELECT id FROM family_photo_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=(CASE WHEN substr(NEW.report_id,1,7)='family:' THEN substr(NEW.report_id,8) ELSE NULL END)));
DELETE FROM family_photo_moderation_consumptions WHERE challenge_id IN (SELECT id FROM family_photo_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=(CASE WHEN substr(NEW.report_id,1,7)='family:' THEN substr(NEW.report_id,8) ELSE NULL END)));
DELETE FROM family_photo_moderation_attempts WHERE challenge_id IN (SELECT id FROM family_photo_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=(CASE WHEN substr(NEW.report_id,1,7)='family:' THEN substr(NEW.report_id,8) ELSE NULL END)));
DELETE FROM family_photo_moderation_challenges WHERE case_reference IN (SELECT case_reference FROM family_photo_moderation_cases WHERE report_id=(CASE WHEN substr(NEW.report_id,1,7)='family:' THEN substr(NEW.report_id,8) ELSE NULL END));
DELETE FROM family_photo_moderation_cases WHERE report_id=(CASE WHEN substr(NEW.report_id,1,7)='family:' THEN substr(NEW.report_id,8) ELSE NULL END);
DELETE FROM family_photo_report_deadlines WHERE report_id=(CASE WHEN substr(NEW.report_id,1,7)='family:' THEN substr(NEW.report_id,8) ELSE NULL END);
DELETE FROM family_photo_report_reminders WHERE report_id=(CASE WHEN substr(NEW.report_id,1,7)='family:' THEN substr(NEW.report_id,8) ELSE NULL END);
DELETE FROM family_photo_report_records WHERE report_id=(CASE WHEN substr(NEW.report_id,1,7)='family:' THEN substr(NEW.report_id,8) ELSE NULL END);
DELETE FROM family_photo_reports WHERE 'family:'||report_id=NEW.report_id;
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
