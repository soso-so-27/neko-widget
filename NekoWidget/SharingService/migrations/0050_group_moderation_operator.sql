-- Additive operator-only workflow. No public runtime or authority is enabled.
CREATE TABLE group_moderation_cases (
 case_reference TEXT PRIMARY KEY CHECK(length(case_reference)=64),
 -- Opaque audit reference only: never pin expiring report metadata via an FK.
 report_id TEXT NOT NULL UNIQUE,
 key_version INTEGER NOT NULL CHECK(key_version=1),
 revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),
 outcome TEXT NOT NULL DEFAULT 'received' CHECK(outcome IN('received','no_action','photo','person','window','release')),
 created_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE group_moderation_challenges (
 id TEXT PRIMARY KEY, operator_id TEXT NOT NULL, credential_id_sha256 TEXT NOT NULL,
 enrollment_admission_id TEXT NOT NULL, access_session_sha256 TEXT NOT NULL,
 policy_revision INTEGER NOT NULL, value_sha256 TEXT NOT NULL,
 case_reference TEXT REFERENCES group_moderation_cases(case_reference),
 case_revision INTEGER, source_sha256 TEXT, receipt_id TEXT,
 action TEXT NOT NULL CHECK(action IN('queue','read','no_action','photo','person','window','release')),
 queue_after INTEGER NOT NULL DEFAULT 0 CHECK(queue_after>=0),
 created_at INTEGER NOT NULL DEFAULT(unixepoch()), expires_at INTEGER NOT NULL CHECK(expires_at>created_at)
) STRICT;
CREATE TABLE group_moderation_attempts (
 challenge_id TEXT PRIMARY KEY REFERENCES group_moderation_challenges(id), assertion_sha256 TEXT NOT NULL,
 created_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE group_moderation_consumptions (
 challenge_id TEXT PRIMARY KEY REFERENCES group_moderation_attempts(challenge_id),
 assertion_sha256 TEXT NOT NULL, authenticator_sign_count INTEGER NOT NULL CHECK(authenticator_sign_count>=0),
 created_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE group_moderation_read_events (
 challenge_id TEXT NOT NULL REFERENCES group_moderation_consumptions(challenge_id),
 phase TEXT NOT NULL CHECK(phase IN('started','disclosure_ready','delivered')),
 created_at INTEGER NOT NULL DEFAULT(unixepoch()), PRIMARY KEY(challenge_id,phase)
) STRICT;
CREATE TABLE group_moderation_receipts (
 id TEXT PRIMARY KEY, challenge_id TEXT NOT NULL UNIQUE REFERENCES group_moderation_consumptions(challenge_id),
 expires_at INTEGER NOT NULL
) STRICT;
CREATE TABLE group_moderation_decisions (
 id TEXT PRIMARY KEY, challenge_id TEXT NOT NULL UNIQUE REFERENCES group_moderation_consumptions(challenge_id),
 case_reference TEXT NOT NULL REFERENCES group_moderation_cases(case_reference),
 revision INTEGER NOT NULL CHECK(revision>0),
 outcome TEXT NOT NULL CHECK(outcome IN('no_action','photo','person','window','release')),
 reply_template TEXT NOT NULL CHECK(reply_template IN('review_no_action_v1','review_restricted_v1','review_released_v1')),
 created_at INTEGER NOT NULL DEFAULT(unixepoch()), UNIQUE(case_reference,revision)
) STRICT;
DROP VIEW moderation_operator_credential_counters;
CREATE VIEW moderation_operator_credential_counters AS
 SELECT credential_id_sha256, MAX(sign_count) AS sign_count FROM (
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
 ) GROUP BY credential_id_sha256;
CREATE TRIGGER group_moderation_consumption_guard BEFORE INSERT ON group_moderation_consumptions BEGIN
 SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_moderation_challenges c JOIN group_moderation_attempts a ON a.challenge_id=c.id
   JOIN moderation_operator_credential_counters counter ON counter.credential_id_sha256=c.credential_id_sha256
   WHERE c.id=NEW.challenge_id AND a.assertion_sha256=NEW.assertion_sha256 AND c.expires_at>unixepoch()
    AND ((counter.sign_count=0 AND NEW.authenticator_sign_count=0) OR NEW.authenticator_sign_count>counter.sign_count))
   THEN RAISE(ABORT,'group_moderation_proof_not_current') END);
END;
CREATE TRIGGER group_moderation_challenge_quota BEFORE INSERT ON group_moderation_challenges BEGIN
 SELECT (CASE WHEN (SELECT COUNT(*) FROM group_moderation_challenges WHERE operator_id=NEW.operator_id AND created_at>unixepoch()-300)>=40
 THEN RAISE(ABORT,'group_moderation_quota') END);
END;
CREATE TRIGGER group_moderation_receipt_guard BEFORE INSERT ON group_moderation_receipts BEGIN
 SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_moderation_challenges c WHERE c.id=NEW.challenge_id AND c.action='read' AND c.expires_at>unixepoch())
  OR (SELECT COUNT(*) FROM group_moderation_read_events WHERE challenge_id=NEW.challenge_id)!=3
 THEN RAISE(ABORT,'group_moderation_disclosure_incomplete') END);
END;
CREATE TRIGGER group_moderation_decision_guard BEFORE INSERT ON group_moderation_decisions BEGIN
 SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_moderation_challenges c JOIN group_moderation_cases k ON k.case_reference=c.case_reference
  WHERE c.id=NEW.challenge_id AND c.case_reference=NEW.case_reference AND c.case_revision=k.revision AND NEW.revision=k.revision+1
   AND NEW.outcome=c.action AND c.expires_at>unixepoch()
   AND (c.action='release' OR EXISTS(SELECT 1 FROM group_moderation_receipts r JOIN group_moderation_challenges read ON read.id=r.challenge_id
     WHERE r.id=c.receipt_id AND r.expires_at>unixepoch() AND read.case_reference=c.case_reference AND read.case_revision=c.case_revision
       AND read.source_sha256=c.source_sha256 AND read.operator_id=c.operator_id AND read.access_session_sha256=c.access_session_sha256)))
 THEN RAISE(ABORT,'group_moderation_decision_not_current') END);
END;
CREATE TRIGGER group_moderation_decisions_no_update BEFORE UPDATE ON group_moderation_decisions BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_moderation_decisions_no_delete BEFORE DELETE ON group_moderation_decisions BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_moderation_challenges_no_update BEFORE UPDATE ON group_moderation_challenges BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_moderation_challenges_no_delete BEFORE DELETE ON group_moderation_challenges BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_moderation_consumptions_no_update BEFORE UPDATE ON group_moderation_consumptions BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_moderation_consumptions_no_delete BEFORE DELETE ON group_moderation_consumptions BEGIN SELECT RAISE(ABORT,'append_only'); END;
