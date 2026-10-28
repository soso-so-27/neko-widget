-- NW3 only. No runtime flag, email binding, recipient or live authority is enabled.
-- Evidence still expires at seven days. These tables contain no image, name,
-- reason, ciphertext descriptor, object key, group key or access-session token.
CREATE TABLE group_report_numbers (
 report_id TEXT PRIMARY KEY,
 receipt_number TEXT UNIQUE CHECK(length(receipt_number)=14
  AND receipt_number GLOB 'R-????-????-??' AND length(replace(substr(receipt_number,3),'-',''))=10
  AND replace(substr(receipt_number,3),'-','') NOT GLOB '*[^0123456789ABCDEFGHJKMNPQRSTVWXYZ]*'),
 created_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE group_report_records (
 report_id TEXT PRIMARY KEY REFERENCES group_report_numbers(report_id),
 space_id TEXT, moment_id TEXT, reporter_person_id TEXT, reporter_device_id TEXT,
 committed_at INTEGER, evidence_expires_at INTEGER,
 revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),
 outcome TEXT NOT NULL DEFAULT 'received' CHECK(outcome IN('received','no_action','photo','person','window','release')),
 decided_at INTEGER, retention_until INTEGER,
 CHECK((committed_at IS NULL AND evidence_expires_at IS NULL) OR evidence_expires_at=committed_at+604800)
) STRICT;
CREATE INDEX group_report_records_due ON group_report_records(outcome,evidence_expires_at);
CREATE INDEX group_report_records_retention ON group_report_records(retention_until) WHERE retention_until IS NOT NULL;
CREATE TABLE group_report_events (
 report_id TEXT NOT NULL REFERENCES group_report_records(report_id), revision INTEGER NOT NULL CHECK(revision>0),
 origin TEXT NOT NULL CHECK(origin IN('operator','deadline')), manual_decision_id TEXT UNIQUE,
 outcome TEXT NOT NULL CHECK(outcome IN('no_action','photo','person','window','release')),
 reply_template TEXT NOT NULL CHECK(reply_template IN('review_no_action_v1','review_restricted_v1','review_released_v1')),
 created_at INTEGER NOT NULL DEFAULT(unixepoch()), PRIMARY KEY(report_id,revision),
 CHECK((origin='operator' AND manual_decision_id IS NOT NULL) OR
       (origin='deadline' AND manual_decision_id IS NULL AND outcome='photo' AND reply_template='review_restricted_v1'))
) STRICT;
CREATE TABLE group_report_mail_outbox (
 id TEXT PRIMARY KEY, report_id TEXT NOT NULL REFERENCES group_report_records(report_id),
 kind TEXT NOT NULL CHECK(kind IN('received','undecided')), state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN('pending','leased','sent','cancelled')),
 attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0), available_at INTEGER NOT NULL,
 lease_token TEXT, lease_until INTEGER, sent_at INTEGER, UNIQUE(report_id,kind)
) STRICT;
CREATE INDEX group_report_mail_due ON group_report_mail_outbox(state,available_at);
CREATE TRIGGER group_report_mail_identity BEFORE UPDATE ON group_report_mail_outbox BEGIN
 SELECT CASE WHEN NEW.id<>OLD.id OR NEW.report_id<>OLD.report_id OR NEW.kind<>OLD.kind THEN RAISE(ABORT,'mail_identity_immutable') END;
END;

-- Existing reports get an unissued placeholder. JS crypto.getRandomValues
-- assigns its number once on first authenticated access, with UNIQUE retry.
INSERT INTO group_report_numbers(report_id)
 SELECT id FROM group_reports UNION SELECT report_id FROM group_moderation_cases;
INSERT INTO group_report_records(report_id,space_id,moment_id,reporter_person_id,reporter_device_id,committed_at,evidence_expires_at,revision,outcome,decided_at,retention_until)
 SELECT r.id,r.space_id,r.moment_id,r.reporter_person_id,r.reporter_device_id,r.committed_at,r.content_expires_at,
 COALESCE(c.revision,0),COALESCE(c.outcome,'received'),d.created_at,
 CASE WHEN c.outcome IN('no_action','release') THEN unixepoch(d.created_at,'unixepoch','+1 year') END
 FROM group_reports r LEFT JOIN group_moderation_cases c ON c.report_id=r.id
 LEFT JOIN group_moderation_decisions d ON d.case_reference=c.case_reference AND d.revision=c.revision
 WHERE r.committed_at IS NOT NULL;
-- Never invent the reporter or original commit time for already purged cases.
INSERT INTO group_report_records(report_id,revision,outcome,decided_at,retention_until)
 SELECT c.report_id,c.revision,c.outcome,d.created_at,
 CASE WHEN c.outcome IN('no_action','release') THEN unixepoch(d.created_at,'unixepoch','+1 year') END
 FROM group_moderation_cases c LEFT JOIN group_moderation_decisions d ON d.case_reference=c.case_reference AND d.revision=c.revision
 WHERE NOT EXISTS(SELECT 1 FROM group_report_records r WHERE r.report_id=c.report_id);
-- An undecided historical case with no remaining target cannot be safely
-- converted into an automatic stop. Deployment must surface this, not guess.
SELECT json(CASE WHEN EXISTS(SELECT 1 FROM group_report_records WHERE outcome='received' AND committed_at IS NULL)
 THEN 'unresolved_historical_report_target' ELSE 'true' END);
INSERT INTO group_report_events(report_id,revision,origin,manual_decision_id,outcome,reply_template,created_at)
 SELECT c.report_id,d.revision,'operator',d.id,d.outcome,d.reply_template,d.created_at
 FROM group_moderation_decisions d JOIN group_moderation_cases c USING(case_reference);

CREATE TRIGGER group_report_number_insert BEFORE INSERT ON group_report_numbers BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_reports WHERE id=NEW.report_id)
 THEN RAISE(ABORT,'report_number_target_missing') END;
END;
CREATE TRIGGER group_report_number_immutable BEFORE UPDATE ON group_report_numbers BEGIN
 SELECT CASE WHEN NEW.report_id<>OLD.report_id OR NEW.created_at<>OLD.created_at
  OR OLD.receipt_number IS NOT NULL OR NEW.receipt_number IS NULL THEN RAISE(ABORT,'append_only') END;
END;
CREATE TRIGGER group_report_record_insert BEFORE INSERT ON group_report_records BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_reports r WHERE r.id=NEW.report_id AND r.committed_at IS NOT NULL
  AND r.space_id=NEW.space_id AND r.moment_id=NEW.moment_id AND r.reporter_person_id=NEW.reporter_person_id
  AND r.reporter_device_id=NEW.reporter_device_id AND r.committed_at=NEW.committed_at AND r.content_expires_at=NEW.evidence_expires_at)
  OR NEW.revision<>0 OR NEW.outcome<>'received' OR NEW.decided_at IS NOT NULL OR NEW.retention_until IS NOT NULL
 THEN RAISE(ABORT,'report_record_binding') END;
END;
-- Commit and the notification obligation are the same transaction. Historical
-- imports above intentionally do not send a burst of arrival notifications.
CREATE TRIGGER group_report_commit_record AFTER UPDATE OF state ON group_reports
 WHEN OLD.committed_at IS NULL AND NEW.committed_at IS NOT NULL BEGIN
 INSERT INTO group_report_records(report_id,space_id,moment_id,reporter_person_id,reporter_device_id,committed_at,evidence_expires_at)
 VALUES(NEW.id,NEW.space_id,NEW.moment_id,NEW.reporter_person_id,NEW.reporter_device_id,NEW.committed_at,NEW.content_expires_at);
 INSERT INTO group_report_mail_outbox(id,report_id,kind,available_at) VALUES(lower(hex(randomblob(16))),NEW.id,'received',unixepoch());
END;
CREATE TRIGGER group_report_record_update BEFORE UPDATE ON group_report_records BEGIN
 SELECT CASE WHEN NEW.report_id<>OLD.report_id OR NEW.space_id IS NOT OLD.space_id OR NEW.moment_id IS NOT OLD.moment_id
  OR NEW.reporter_person_id IS NOT OLD.reporter_person_id OR NEW.reporter_device_id IS NOT OLD.reporter_device_id
  OR NEW.committed_at IS NOT OLD.committed_at OR NEW.evidence_expires_at IS NOT OLD.evidence_expires_at
  OR NEW.revision<>OLD.revision+1 OR NOT EXISTS(SELECT 1 FROM group_report_events e WHERE e.report_id=OLD.report_id
    AND e.revision=NEW.revision AND e.outcome=NEW.outcome AND e.created_at=NEW.decided_at)
  OR NEW.retention_until IS NOT (CASE WHEN NEW.outcome IN('release','no_action') THEN unixepoch(NEW.decided_at,'unixepoch','+1 year') END)
 THEN RAISE(ABORT,'report_record_immutable') END;
END;
CREATE TRIGGER group_report_event_guard BEFORE INSERT ON group_report_events BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_report_records r WHERE r.report_id=NEW.report_id AND NEW.revision=r.revision+1)
  OR NEW.created_at<>unixepoch()
  OR (NEW.origin='deadline' AND NOT EXISTS(SELECT 1 FROM group_report_records r WHERE r.report_id=NEW.report_id
      AND r.outcome='received' AND r.revision=0 AND r.evidence_expires_at<=unixepoch() AND r.moment_id IS NOT NULL))
  OR (NEW.origin='operator' AND NOT EXISTS(SELECT 1 FROM group_moderation_decisions d JOIN group_moderation_cases c USING(case_reference)
      WHERE d.id=NEW.manual_decision_id AND c.report_id=NEW.report_id AND d.revision=NEW.revision
       AND d.outcome=NEW.outcome AND d.reply_template=NEW.reply_template AND d.created_at=NEW.created_at))
 THEN RAISE(ABORT,'report_event_not_current') END;
END;
CREATE TRIGGER group_report_event_apply AFTER INSERT ON group_report_events BEGIN
 UPDATE group_report_records SET revision=NEW.revision,outcome=NEW.outcome,decided_at=NEW.created_at,
  retention_until=(CASE WHEN NEW.outcome IN('no_action','release') THEN unixepoch(NEW.created_at,'unixepoch','+1 year') END)
  WHERE report_id=NEW.report_id;
 UPDATE group_moderation_cases SET revision=NEW.revision,outcome=NEW.outcome WHERE report_id=NEW.report_id;
 UPDATE group_report_mail_outbox SET state='cancelled',lease_token=NULL,lease_until=NULL
  WHERE report_id=NEW.report_id AND kind='undecided' AND state='pending';
END;
CREATE TRIGGER group_report_event_no_update BEFORE UPDATE ON group_report_events BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_moderation_record_decision AFTER INSERT ON group_moderation_decisions BEGIN
 INSERT INTO group_report_events(report_id,revision,origin,manual_decision_id,outcome,reply_template,created_at)
 SELECT report_id,NEW.revision,'operator',NEW.id,NEW.outcome,NEW.reply_template,NEW.created_at
 FROM group_moderation_cases WHERE case_reference=NEW.case_reference;
END;

-- The deadline identity is distinct from the local HMAC operator reference.
-- Only a committed immutable report target can authorize this exception when
-- normal photo metadata has already expired. It never widens to a person/window.
DROP TRIGGER group_moderation_target;
CREATE TRIGGER group_moderation_target BEFORE INSERT ON group_moderation_restrictions BEGIN
 SELECT CASE WHEN NOT (
  (NEW.case_reference NOT LIKE 'deadline:%' AND ((NEW.target_kind='window' AND NEW.target_id=NEW.space_id)
  OR (NEW.target_kind='person' AND EXISTS(SELECT 1 FROM group_members WHERE space_id=NEW.space_id AND person_id=NEW.target_id))
  OR (NEW.target_kind='photo' AND EXISTS(SELECT 1 FROM group_moments WHERE space_id=NEW.space_id AND id=NEW.target_id))))
  OR (NEW.target_kind='photo' AND EXISTS(SELECT 1 FROM group_report_records r JOIN group_report_events e ON e.report_id=r.report_id AND e.revision=r.revision
    WHERE NEW.case_reference='deadline:'||r.report_id AND r.space_id=NEW.space_id AND r.moment_id=NEW.target_id
     AND e.origin='deadline' AND r.outcome='photo' AND r.evidence_expires_at<=unixepoch())))
 THEN RAISE(ABORT,'group_moderation_invalid_target') END;
END;

-- Retention authority can only be created for an elapsed terminal decision.
-- Every deletion guard rechecks the current record, so re-stopping invalidates
-- an old purge ticket. No update guard on audit evidence is removed.
CREATE TABLE group_report_purge_tickets(report_id TEXT PRIMARY KEY,revision INTEGER NOT NULL,created_at INTEGER NOT NULL DEFAULT(unixepoch())) STRICT;
CREATE VIEW group_report_purge_allowed AS SELECT p.report_id FROM group_report_purge_tickets p JOIN group_report_records r USING(report_id)
 WHERE p.revision=r.revision AND r.outcome IN('no_action','release') AND r.retention_until<=unixepoch()
 AND NOT EXISTS(SELECT 1 FROM group_moderation_restrictions x WHERE x.active=1 AND
  (x.case_reference='deadline:'||r.report_id OR x.case_reference IN(SELECT case_reference FROM group_moderation_cases WHERE report_id=r.report_id)));
CREATE TRIGGER group_report_purge_ticket_guard BEFORE INSERT ON group_report_purge_tickets BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_report_records r WHERE r.report_id=NEW.report_id AND r.revision=NEW.revision
  AND r.outcome IN('no_action','release') AND r.retention_until<=unixepoch()) THEN RAISE(ABORT,'retention_not_due') END;
END;
CREATE TRIGGER group_report_purge_ticket_no_update BEFORE UPDATE ON group_report_purge_tickets BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_report_event_delete BEFORE DELETE ON group_report_events BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_report_purge_allowed WHERE report_id=OLD.report_id) THEN RAISE(ABORT,'retention_not_due') END;
END;
CREATE TRIGGER group_report_record_delete BEFORE DELETE ON group_report_records BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_report_purge_allowed WHERE report_id=OLD.report_id) THEN RAISE(ABORT,'retention_not_due') END;
END;
CREATE TRIGGER group_report_number_delete BEFORE DELETE ON group_report_numbers BEGIN
 SELECT CASE WHEN EXISTS(SELECT 1 FROM group_report_records WHERE report_id=OLD.report_id)
  OR EXISTS(SELECT 1 FROM group_reports WHERE id=OLD.report_id) THEN RAISE(ABORT,'report_number_in_use') END;
END;
DROP TRIGGER group_moderation_decisions_no_delete;
CREATE TRIGGER group_moderation_decisions_no_delete BEFORE DELETE ON group_moderation_decisions BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_report_purge_allowed p JOIN group_moderation_cases c USING(report_id)
  WHERE c.case_reference=OLD.case_reference) THEN RAISE(ABORT,'retention_not_due') END;
END;
DROP TRIGGER group_moderation_challenges_no_delete;
CREATE TRIGGER group_moderation_challenges_no_delete BEFORE DELETE ON group_moderation_challenges BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_report_purge_allowed p JOIN group_moderation_cases c USING(report_id)
  WHERE c.case_reference=OLD.case_reference) AND NOT (OLD.case_reference IS NULL AND OLD.expires_at+172800<=unixepoch())
 THEN RAISE(ABORT,'retention_not_due') END;
END;
DROP TRIGGER group_moderation_consumptions_no_delete;
CREATE TRIGGER group_moderation_consumptions_no_delete BEFORE DELETE ON group_moderation_consumptions BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_moderation_challenges q WHERE q.id=OLD.challenge_id AND (
  EXISTS(SELECT 1 FROM group_report_purge_allowed p JOIN group_moderation_cases c USING(report_id) WHERE c.case_reference=q.case_reference)
  OR (q.case_reference IS NULL AND q.expires_at+172800<=unixepoch()))) THEN RAISE(ABORT,'retention_not_due') END;
END;
CREATE TRIGGER group_moderation_case_delete BEFORE DELETE ON group_moderation_cases BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_report_purge_allowed WHERE report_id=OLD.report_id) THEN RAISE(ABORT,'retention_not_due') END;
END;
CREATE VIEW group_moderation_purge_challenges AS SELECT q.id FROM group_moderation_challenges q
 WHERE (q.case_reference IS NULL AND q.expires_at+172800<=unixepoch()) OR EXISTS(
  SELECT 1 FROM group_report_purge_allowed p JOIN group_moderation_cases c USING(report_id) WHERE c.case_reference=q.case_reference);
CREATE TRIGGER group_moderation_attempt_retention BEFORE DELETE ON group_moderation_attempts BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_moderation_purge_challenges WHERE id=OLD.challenge_id) THEN RAISE(ABORT,'retention_not_due') END;
END;
CREATE TRIGGER group_moderation_read_retention BEFORE DELETE ON group_moderation_read_events BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_moderation_purge_challenges WHERE id=OLD.challenge_id) THEN RAISE(ABORT,'retention_not_due') END;
END;
CREATE TRIGGER group_moderation_receipt_retention BEFORE DELETE ON group_moderation_receipts BEGIN
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM group_moderation_purge_challenges WHERE id=OLD.challenge_id) THEN RAISE(ABORT,'retention_not_due') END;
END;
CREATE TRIGGER group_moderation_restriction_retention BEFORE DELETE ON group_moderation_restrictions BEGIN
 SELECT CASE WHEN OLD.active=1 OR NOT EXISTS(SELECT 1 FROM group_report_purge_allowed p WHERE
  OLD.case_reference='deadline:'||p.report_id OR OLD.case_reference IN(SELECT case_reference FROM group_moderation_cases WHERE report_id=p.report_id))
 THEN RAISE(ABORT,'retention_not_due') END;
END;
-- Keep only a per-credential high-water counter when case-specific proofs
-- expire, so deleting an old case cannot re-admit an old authenticator counter.
CREATE TABLE group_operator_counter_floors(credential_id_sha256 TEXT PRIMARY KEY,sign_count INTEGER NOT NULL CHECK(sign_count>=0)) STRICT;
CREATE TRIGGER group_operator_counter_floor_update BEFORE UPDATE ON group_operator_counter_floors BEGIN
 SELECT CASE WHEN NEW.credential_id_sha256<>OLD.credential_id_sha256 OR NEW.sign_count<OLD.sign_count THEN RAISE(ABORT,'counter_regression') END;
END;
CREATE TRIGGER group_operator_counter_floor_delete BEFORE DELETE ON group_operator_counter_floors BEGIN SELECT RAISE(ABORT,'counter_regression'); END;
CREATE TRIGGER group_operator_counter_floor_capture BEFORE DELETE ON group_moderation_consumptions BEGIN
 INSERT INTO group_operator_counter_floors SELECT credential_id_sha256,OLD.authenticator_sign_count FROM group_moderation_challenges WHERE id=OLD.challenge_id
 ON CONFLICT(credential_id_sha256) DO UPDATE SET sign_count=MAX(sign_count,excluded.sign_count);
END;
DROP VIEW moderation_operator_credential_counters;
CREATE VIEW moderation_operator_credential_counters AS SELECT credential_id_sha256,MAX(sign_count) AS sign_count FROM (
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
) GROUP BY credential_id_sha256;
