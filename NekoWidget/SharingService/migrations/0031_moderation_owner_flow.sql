-- Local owner review foundation. Empty policy means no authority. No enrollment,
-- public route, delivery, restriction, deletion or independent privacy approval
-- is introduced. Legacy 0013-0018 guards remain in place.
-- Runtime verifies Access/WebAuthn and writes attempts before verification in a
-- separate committed transaction. Only the trusted isolated host writes read
-- events/receipts; SQL cannot prove that a human saw rendered content.
CREATE TABLE moderation_owner_policies (
  policy_revision INTEGER PRIMARY KEY CHECK (policy_revision BETWEEN 1 AND 2147483647),
  owner_operator_id TEXT NOT NULL REFERENCES moderation_operators(operator_id),
  enrollment_admission_id TEXT NOT NULL REFERENCES moderation_operator_enrollment_admissions(enrollment_admission_id),
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  session_rowid_floor INTEGER NOT NULL CHECK (session_rowid_floor >= 0)
) STRICT;
CREATE TABLE moderation_owner_policy_revocations (
  policy_revision INTEGER PRIMARY KEY REFERENCES moderation_owner_policies(policy_revision),
  revoked_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;

CREATE VIEW moderation_owner_current_policies AS
SELECT p.*, e.target_credential_id_sha256 AS credential_id_sha256,
       e.target_access_subject_hmac_key_version AS access_subject_hmac_key_version,
       e.target_access_subject_hmac AS access_subject_hmac
FROM moderation_owner_policies p
JOIN moderation_operator_enrollment_admissions a ON a.enrollment_admission_id=p.enrollment_admission_id
JOIN moderation_operator_enrollment_requests e ON e.enrollment_request_id=a.enrollment_request_id
JOIN moderation_operator_credentials k ON k.credential_id_sha256=e.target_credential_id_sha256
 AND k.operator_id=p.owner_operator_id AND k.public_key_cose=e.target_public_key_cose_snapshot
 AND k.registration_sign_count=e.target_registration_sign_count
JOIN moderation_operator_subject_identities i ON i.operator_id=p.owner_operator_id
 AND i.access_subject_hmac_key_version=e.target_access_subject_hmac_key_version
 AND i.access_subject_hmac=e.target_access_subject_hmac
WHERE p.policy_revision=(SELECT MAX(policy_revision) FROM moderation_owner_policies)
 AND e.target_operator_id=p.owner_operator_id
 AND NOT EXISTS (SELECT 1 FROM moderation_owner_policy_revocations r WHERE r.policy_revision=p.policy_revision)
 AND NOT EXISTS (SELECT 1 FROM moderation_operator_enrollment_admissions newer
   JOIN moderation_operator_enrollment_requests ne ON ne.enrollment_request_id=newer.enrollment_request_id
   WHERE ne.target_operator_id=p.owner_operator_id AND newer.rowid>a.rowid)
 AND NOT EXISTS (SELECT 1 FROM moderation_operator_subject_identities newer
   WHERE newer.operator_id=p.owner_operator_id AND newer.access_subject_hmac_key_version>i.access_subject_hmac_key_version)
 AND EXISTS (SELECT 1 FROM moderation_operator_state_events WHERE operator_id=p.owner_operator_id AND event_type='activated')
 AND NOT EXISTS (SELECT 1 FROM moderation_operator_state_events WHERE operator_id=p.owner_operator_id AND event_type='revoked')
 AND EXISTS (SELECT 1 FROM moderation_operator_role_events WHERE operator_id=p.owner_operator_id AND role_code='triage' AND event_type='granted')
 AND NOT EXISTS (SELECT 1 FROM moderation_operator_role_events WHERE operator_id=p.owner_operator_id AND role_code='triage' AND event_type='revoked')
 AND EXISTS (SELECT 1 FROM moderation_operator_credential_events WHERE credential_id_sha256=k.credential_id_sha256 AND event_type='registered')
 AND NOT EXISTS (SELECT 1 FROM moderation_operator_credential_events WHERE credential_id_sha256=k.credential_id_sha256 AND event_type='revoked');

CREATE TRIGGER moderation_owner_policy_insert BEFORE INSERT ON moderation_owner_policies
BEGIN
 SELECT (CASE WHEN NEW.created_at<>unixepoch()
  OR NEW.policy_revision<>COALESCE((SELECT MAX(policy_revision) FROM moderation_owner_policies),0)+1
  OR NEW.session_rowid_floor<>COALESCE((SELECT MAX(rowid) FROM moderation_operator_access_sessions),0)
  OR EXISTS (SELECT 1 FROM moderation_owner_policies WHERE owner_operator_id<>NEW.owner_operator_id)
  THEN RAISE(ABORT,'owner policy epoch is invalid') END);
END;
CREATE TRIGGER moderation_owner_policy_admitted AFTER INSERT ON moderation_owner_policies
BEGIN
 SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM moderation_owner_current_policies WHERE policy_revision=NEW.policy_revision)
 THEN RAISE(ABORT,'owner policy requires current admitted identity') END);
END;
CREATE TRIGGER moderation_owner_policy_revoke BEFORE INSERT ON moderation_owner_policy_revocations
BEGIN
 SELECT (CASE WHEN NEW.revoked_at<>unixepoch() OR EXISTS (
  SELECT 1 FROM moderation_owner_policy_revocations WHERE policy_revision=NEW.policy_revision)
 THEN RAISE(ABORT,'owner policy revocation cannot be replayed') END);
END;

CREATE TABLE moderation_owner_challenges (
  challenge_id TEXT PRIMARY KEY CHECK (length(challenge_id)=36),
  domain TEXT NOT NULL DEFAULT 'NW.MODERATION-OWNER.ACTION.v1' CHECK (domain='NW.MODERATION-OWNER.ACTION.v1'),
  policy_revision INTEGER NOT NULL REFERENCES moderation_owner_policies(policy_revision),
  operator_id TEXT NOT NULL REFERENCES moderation_operators(operator_id),
  credential_id_sha256 TEXT NOT NULL REFERENCES moderation_operator_credentials(credential_id_sha256),
  enrollment_admission_id TEXT NOT NULL REFERENCES moderation_operator_enrollment_admissions(enrollment_admission_id),
  access_session_sha256 TEXT NOT NULL REFERENCES moderation_operator_access_sessions(access_session_sha256),
  challenge_value_sha256 TEXT NOT NULL UNIQUE CHECK (length(challenge_value_sha256)=64 AND challenge_value_sha256 NOT GLOB '*[^0-9a-f]*'),
  purpose TEXT NOT NULL CHECK (purpose IN ('content_read','decision')),
  case_reference_hmac TEXT NOT NULL REFERENCES moderation_operator_versioned_case_references(case_reference_hmac),
  case_reference_hmac_key_version INTEGER NOT NULL CHECK (case_reference_hmac_key_version BETWEEN 1 AND 2147483647),
  source_sha256 TEXT NOT NULL,
  source_committed_at INTEGER NOT NULL,
  source_expires_at INTEGER NOT NULL,
  source_snapshot_sha256 TEXT NOT NULL CHECK (length(source_snapshot_sha256)=64 AND source_snapshot_sha256 NOT GLOB '*[^0-9a-f]*'),
  decision TEXT CHECK (decision='no_action'),
  reply_template TEXT CHECK (reply_template='review_no_action_v1'),
  read_receipt_id TEXT REFERENCES moderation_owner_read_receipts(read_receipt_id),
  issued_at INTEGER NOT NULL DEFAULT (unixepoch()),
  expires_at INTEGER NOT NULL,
  CHECK (expires_at>issued_at AND expires_at<=issued_at+300 AND expires_at<=source_expires_at),
  CHECK ((purpose='content_read' AND decision IS NULL AND reply_template IS NULL AND read_receipt_id IS NULL)
    OR (purpose='decision' AND decision IS 'no_action' AND reply_template IS 'review_no_action_v1' AND read_receipt_id IS NOT NULL))
) STRICT;
CREATE INDEX moderation_owner_challenge_operator_time ON moderation_owner_challenges(operator_id,issued_at,expires_at);

-- Full private source metadata is DB-derived, short-lived and purgeable. It is
-- never copied into the immutable challenges, decisions or audit receipts.
CREATE TABLE moderation_owner_source_snapshots (
  challenge_id TEXT PRIMARY KEY REFERENCES moderation_owner_challenges(challenge_id),
  report_id TEXT NOT NULL REFERENCES moment_reports(id) ON DELETE CASCADE,
  object_key TEXT NOT NULL,
  moment_id TEXT NOT NULL,
  reporter_participant_id TEXT NOT NULL,
  reason_code TEXT NOT NULL,
  moderation_key_id TEXT NOT NULL,
  ciphertext_size INTEGER NOT NULL,
  ciphertext_sha256 TEXT NOT NULL,
  committed_at INTEGER NOT NULL,
  content_expires_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX moderation_owner_source_expiry ON moderation_owner_source_snapshots(expires_at);
CREATE TABLE moderation_owner_snapshot_seals (
  challenge_id TEXT PRIMARY KEY REFERENCES moderation_owner_challenges(challenge_id)
) STRICT;
CREATE TABLE moderation_owner_assertion_attempts (
  challenge_id TEXT PRIMARY KEY REFERENCES moderation_owner_challenges(challenge_id),
  assertion_sha256 TEXT NOT NULL UNIQUE CHECK (length(assertion_sha256)=64 AND assertion_sha256 NOT GLOB '*[^0-9a-f]*'),
  attempted_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;
CREATE TABLE moderation_owner_challenge_consumptions (
  challenge_id TEXT PRIMARY KEY REFERENCES moderation_owner_assertion_attempts(challenge_id),
  verified_assertion_sha256 TEXT NOT NULL UNIQUE CHECK (length(verified_assertion_sha256)=64 AND verified_assertion_sha256 NOT GLOB '*[^0-9a-f]*'),
  authenticator_sign_count INTEGER NOT NULL CHECK (authenticator_sign_count BETWEEN 0 AND 4294967295),
  consumed_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;
CREATE TABLE moderation_owner_read_claims (
  challenge_id TEXT PRIMARY KEY REFERENCES moderation_owner_challenge_consumptions(challenge_id),
  read_receipt_id TEXT NOT NULL UNIQUE CHECK (length(read_receipt_id)=36),
  claimed_at INTEGER NOT NULL DEFAULT (unixepoch()),
  expires_at INTEGER NOT NULL CHECK (expires_at>claimed_at AND expires_at<=claimed_at+60)
) STRICT;
CREATE TABLE moderation_owner_read_events (
  read_receipt_id TEXT NOT NULL REFERENCES moderation_owner_read_claims(read_receipt_id),
  phase TEXT NOT NULL CHECK (phase IN ('started','disclosure_ready','failed','delivery_unknown')),
  recorded_at INTEGER NOT NULL DEFAULT (unixepoch()),
  PRIMARY KEY(read_receipt_id,phase)
) STRICT;
CREATE TABLE moderation_owner_read_receipts (
  read_receipt_id TEXT PRIMARY KEY REFERENCES moderation_owner_read_claims(read_receipt_id),
  completed_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;
CREATE TABLE moderation_owner_decisions (
  decision_id TEXT PRIMARY KEY CHECK (length(decision_id)=36),
  challenge_id TEXT NOT NULL UNIQUE REFERENCES moderation_owner_challenge_consumptions(challenge_id),
  case_reference_hmac TEXT NOT NULL UNIQUE REFERENCES moderation_operator_versioned_case_references(case_reference_hmac),
  recorded_at INTEGER NOT NULL DEFAULT (unixepoch())
) STRICT;
CREATE TABLE moderation_owner_reply_outbox (
  decision_id TEXT PRIMARY KEY REFERENCES moderation_owner_decisions(decision_id),
  report_id TEXT NOT NULL REFERENCES moment_reports(id) ON DELETE CASCADE,
  recipient_participant_id TEXT NOT NULL,
  template_code TEXT NOT NULL CHECK (template_code='review_no_action_v1'),
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX moderation_owner_reply_expiry ON moderation_owner_reply_outbox(expires_at);

-- This replacement only strengthens the 0030 predicate. Legacy terminal,
-- tombstone, TTL and committed-state conditions are preserved verbatim.
DROP VIEW moderation_advisory_live_sources;
CREATE VIEW moderation_advisory_live_sources AS
SELECT r.id AS report_id, c.case_reference_hmac, c.case_reference_hmac_key_version,
       r.ciphertext_sha256 AS source_sha256, r.committed_at AS source_committed_at,
       r.content_expires_at AS expires_at
FROM moment_reports r JOIN moment_report_tombstones t ON t.report_id=r.id
JOIN moderation_cases m ON m.report_id=r.id
JOIN moderation_operator_versioned_case_references c ON c.report_id=r.id
WHERE r.state='committed' AND r.closed_at IS NULL AND r.content_expires_at>unixepoch()
 AND t.content_deleted_at IS NULL AND t.content_expires_at=r.content_expires_at
 AND t.committed_at=r.committed_at AND m.committed_at=r.committed_at
 AND NOT EXISTS (SELECT 1 FROM moderation_case_events e WHERE e.report_id=r.id AND e.event_type='review_decided')
 AND NOT EXISTS (SELECT 1 FROM moderation_owner_decisions d WHERE d.case_reference_hmac=c.case_reference_hmac);

-- Owner terminal completion purges the same advisory payloads as the legacy
-- terminal event. Every previous live-retention condition remains unchanged.
DROP TRIGGER moderation_advisory_job_retention;
CREATE TRIGGER moderation_advisory_job_retention BEFORE DELETE ON moderation_advisory_jobs
WHEN OLD.expires_at>unixepoch() AND EXISTS (
 SELECT 1 FROM moment_reports WHERE id=OLD.report_id AND state='committed' AND closed_at IS NULL
) AND EXISTS (SELECT 1 FROM moment_report_tombstones WHERE report_id=OLD.report_id AND content_deleted_at IS NULL)
 AND NOT EXISTS (SELECT 1 FROM moderation_case_events WHERE report_id=OLD.report_id AND event_type='review_decided')
 AND NOT EXISTS (SELECT 1 FROM moderation_owner_decisions d
  JOIN moderation_operator_versioned_case_references r ON r.case_reference_hmac=d.case_reference_hmac WHERE r.report_id=OLD.report_id)
BEGIN SELECT RAISE(ABORT,'live advisory cannot be reset'); END;

CREATE VIEW moderation_owner_current_challenges AS
SELECT c.* FROM moderation_owner_challenges c
JOIN moderation_owner_current_policies p ON p.policy_revision=c.policy_revision AND p.owner_operator_id=c.operator_id
 AND p.enrollment_admission_id=c.enrollment_admission_id AND p.credential_id_sha256=c.credential_id_sha256
JOIN moderation_operator_access_sessions a ON a.access_session_sha256=c.access_session_sha256
 AND a.operator_id=c.operator_id AND a.access_subject_hmac=p.access_subject_hmac
 AND a.access_subject_hmac_key_version=p.access_subject_hmac_key_version
JOIN moderation_owner_source_snapshots snap ON snap.challenge_id=c.challenge_id
JOIN moderation_advisory_live_sources s ON s.case_reference_hmac=c.case_reference_hmac
 AND s.case_reference_hmac_key_version=c.case_reference_hmac_key_version
 AND s.source_sha256=c.source_sha256 AND s.source_committed_at=c.source_committed_at AND s.expires_at=c.source_expires_at
JOIN moment_reports r ON r.id=s.report_id AND r.id=snap.report_id
WHERE a.rowid>p.session_rowid_floor AND a.admitted_at>=p.created_at
 AND a.token_expires_at>unixepoch() AND a.admitted_at<=c.issued_at
 AND c.issued_at<=unixepoch() AND c.expires_at>unixepoch() AND snap.expires_at>unixepoch()
 AND r.object_key=snap.object_key AND r.moment_id=snap.moment_id
 AND r.reporter_participant_id=snap.reporter_participant_id AND r.reason_code=snap.reason_code
 AND r.moderation_key_id=snap.moderation_key_id AND r.ciphertext_size=snap.ciphertext_size
 AND r.ciphertext_sha256=snap.ciphertext_sha256 AND r.committed_at=snap.committed_at
 AND r.content_expires_at=snap.content_expires_at
 AND NOT EXISTS (SELECT 1 FROM moment_object_deletions d WHERE d.object_key=r.object_key OR (d.object_type='report' AND d.owner_id=r.id));

CREATE VIEW moderation_operator_credential_counters AS
SELECT credential_id_sha256, MAX(sign_count) AS sign_count FROM (
 SELECT credential_id_sha256, registration_sign_count AS sign_count FROM moderation_operator_credentials
 UNION ALL SELECT credential_id_sha256,authenticator_sign_count FROM moderation_operator_challenge_consumptions
 UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM moderation_owner_challenge_consumptions r
 JOIN moderation_owner_challenges c ON c.challenge_id=r.challenge_id
) GROUP BY credential_id_sha256;

CREATE TRIGGER moderation_owner_challenge_insert BEFORE INSERT ON moderation_owner_challenges
BEGIN
 SELECT (CASE WHEN NEW.issued_at<>unixepoch() OR EXISTS (
  SELECT 1 FROM moderation_owner_challenges WHERE challenge_id=NEW.challenge_id OR challenge_value_sha256=NEW.challenge_value_sha256)
  OR EXISTS (SELECT 1 FROM moderation_operator_challenges WHERE challenge_id=NEW.challenge_id OR challenge_value_sha256=NEW.challenge_value_sha256)
  THEN RAISE(ABORT,'owner challenge replay') END);
 SELECT (CASE WHEN (SELECT COUNT(*) FROM moderation_owner_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)
  +(SELECT COUNT(*) FROM moderation_operator_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)>=12
  OR (SELECT COUNT(*) FROM moderation_owner_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch()
    AND NOT EXISTS (SELECT 1 FROM moderation_owner_challenge_consumptions r WHERE r.challenge_id=c.challenge_id))
  +(SELECT COUNT(*) FROM moderation_operator_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch()
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_challenge_consumptions r WHERE r.challenge_id=c.challenge_id))>=8
  THEN RAISE(ABORT,'owner challenge quota exceeded') END);
END;
CREATE TRIGGER moderation_owner_challenge_snapshot AFTER INSERT ON moderation_owner_challenges
BEGIN
 INSERT INTO moderation_owner_source_snapshots
 SELECT NEW.challenge_id,r.id,r.object_key,r.moment_id,r.reporter_participant_id,r.reason_code,r.moderation_key_id,
  r.ciphertext_size,r.ciphertext_sha256,r.committed_at,r.content_expires_at,
  MIN(r.content_expires_at,a.token_expires_at,NEW.issued_at+900)
 FROM moderation_advisory_live_sources s JOIN moment_reports r ON r.id=s.report_id
 JOIN moderation_operator_access_sessions a ON a.access_session_sha256=NEW.access_session_sha256
 WHERE s.case_reference_hmac=NEW.case_reference_hmac AND s.case_reference_hmac_key_version=NEW.case_reference_hmac_key_version;
 SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM moderation_owner_current_challenges WHERE challenge_id=NEW.challenge_id)
  OR NEW.expires_at>(SELECT token_expires_at FROM moderation_operator_access_sessions WHERE access_session_sha256=NEW.access_session_sha256)
  THEN RAISE(ABORT,'owner challenge is not current') END);
 SELECT (CASE WHEN NEW.purpose='decision' AND NOT EXISTS (
  SELECT 1 FROM moderation_owner_read_receipts receipt
  JOIN moderation_owner_read_claims claim ON claim.read_receipt_id=receipt.read_receipt_id
  JOIN moderation_owner_current_challenges prior ON prior.challenge_id=claim.challenge_id
  JOIN moderation_owner_source_snapshots ps ON ps.challenge_id=prior.challenge_id
  JOIN moderation_owner_source_snapshots ns ON ns.challenge_id=NEW.challenge_id
  WHERE receipt.read_receipt_id=NEW.read_receipt_id AND receipt.completed_at>unixepoch()-300
   AND prior.purpose='content_read' AND prior.policy_revision=NEW.policy_revision AND prior.operator_id=NEW.operator_id
   AND prior.enrollment_admission_id=NEW.enrollment_admission_id AND prior.credential_id_sha256=NEW.credential_id_sha256
   AND prior.access_session_sha256=NEW.access_session_sha256 AND prior.case_reference_hmac=NEW.case_reference_hmac
   AND prior.case_reference_hmac_key_version=NEW.case_reference_hmac_key_version AND prior.source_snapshot_sha256=NEW.source_snapshot_sha256
   AND ps.report_id=ns.report_id AND ps.object_key=ns.object_key AND ps.moment_id=ns.moment_id
   AND ps.reporter_participant_id=ns.reporter_participant_id AND ps.reason_code=ns.reason_code
   AND ps.moderation_key_id=ns.moderation_key_id AND ps.ciphertext_size=ns.ciphertext_size
   AND ps.ciphertext_sha256=ns.ciphertext_sha256 AND ps.committed_at=ns.committed_at AND ps.content_expires_at=ns.content_expires_at
 ) THEN RAISE(ABORT,'owner decision requires same-scope completed read') END);
END;

CREATE TRIGGER moderation_owner_snapshot_insert BEFORE INSERT ON moderation_owner_source_snapshots
BEGIN
 SELECT (CASE WHEN EXISTS (SELECT 1 FROM moderation_owner_snapshot_seals WHERE challenge_id=NEW.challenge_id)
 OR NOT EXISTS (SELECT 1 FROM moderation_owner_challenges c
  JOIN moderation_advisory_live_sources s ON s.case_reference_hmac=c.case_reference_hmac AND s.case_reference_hmac_key_version=c.case_reference_hmac_key_version
  JOIN moment_reports r ON r.id=s.report_id JOIN moderation_operator_access_sessions a ON a.access_session_sha256=c.access_session_sha256
  WHERE c.challenge_id=NEW.challenge_id AND c.issued_at=unixepoch() AND r.id=NEW.report_id
   AND r.object_key=NEW.object_key AND r.moment_id=NEW.moment_id AND r.reporter_participant_id=NEW.reporter_participant_id
   AND r.reason_code=NEW.reason_code AND r.moderation_key_id=NEW.moderation_key_id AND r.ciphertext_size=NEW.ciphertext_size
   AND r.ciphertext_sha256=NEW.ciphertext_sha256 AND r.committed_at=NEW.committed_at AND r.content_expires_at=NEW.content_expires_at
   AND NEW.expires_at=MIN(r.content_expires_at,a.token_expires_at,c.issued_at+900)
   AND NOT EXISTS (SELECT 1 FROM moment_object_deletions d WHERE d.object_key=r.object_key OR (d.object_type='report' AND d.owner_id=r.id))
 ) THEN RAISE(ABORT,'owner source snapshot is not database-derived') END);
END;
CREATE TRIGGER moderation_owner_snapshot_seal AFTER INSERT ON moderation_owner_source_snapshots
BEGIN INSERT INTO moderation_owner_snapshot_seals(challenge_id) VALUES (NEW.challenge_id); END;
CREATE TRIGGER moderation_owner_snapshot_seal_insert BEFORE INSERT ON moderation_owner_snapshot_seals
BEGIN
 SELECT (CASE WHEN EXISTS (SELECT 1 FROM moderation_owner_snapshot_seals WHERE challenge_id=NEW.challenge_id)
 OR NOT EXISTS (SELECT 1 FROM moderation_owner_source_snapshots WHERE challenge_id=NEW.challenge_id)
 THEN RAISE(ABORT,'owner source seal cannot be replayed') END);
END;

CREATE TRIGGER moderation_owner_attempt_insert BEFORE INSERT ON moderation_owner_assertion_attempts
BEGIN
 SELECT (CASE WHEN NEW.attempted_at<>unixepoch()
  OR NOT EXISTS (SELECT 1 FROM moderation_owner_current_challenges WHERE challenge_id=NEW.challenge_id)
  OR EXISTS (SELECT 1 FROM moderation_owner_assertion_attempts WHERE challenge_id=NEW.challenge_id OR assertion_sha256=NEW.assertion_sha256)
  OR EXISTS (SELECT 1 FROM moderation_operator_assertion_attempts WHERE assertion_sha256=NEW.assertion_sha256)
 THEN RAISE(ABORT,'owner assertion attempt is stale or replayed') END);
END;
CREATE TRIGGER moderation_owner_consumption_insert BEFORE INSERT ON moderation_owner_challenge_consumptions
BEGIN
 SELECT (CASE WHEN NEW.consumed_at<>unixepoch()
  OR EXISTS (SELECT 1 FROM moderation_owner_challenge_consumptions WHERE challenge_id=NEW.challenge_id OR verified_assertion_sha256=NEW.verified_assertion_sha256)
  OR EXISTS (SELECT 1 FROM moderation_operator_challenge_consumptions WHERE verified_assertion_sha256=NEW.verified_assertion_sha256)
  OR NOT EXISTS (SELECT 1 FROM moderation_owner_current_challenges c JOIN moderation_owner_assertion_attempts a ON a.challenge_id=c.challenge_id
   WHERE c.challenge_id=NEW.challenge_id AND a.assertion_sha256=NEW.verified_assertion_sha256 AND a.attempted_at<=NEW.consumed_at)
 THEN RAISE(ABORT,'owner assertion consumption is stale or replayed') END);
 SELECT (CASE WHEN EXISTS (SELECT 1 FROM moderation_owner_challenges c
  JOIN moderation_operator_credential_counters k ON k.credential_id_sha256=c.credential_id_sha256
  WHERE c.challenge_id=NEW.challenge_id AND ((NEW.authenticator_sign_count=0 AND k.sign_count>0)
    OR (NEW.authenticator_sign_count>0 AND NEW.authenticator_sign_count<=k.sign_count)))
 THEN RAISE(ABORT,'shared authenticator counter did not increase') END);
END;

-- Additive guards at BOTH legacy boundaries; no previous trigger is dropped.
CREATE TRIGGER moderation_owner_legacy_challenge_guard BEFORE INSERT ON moderation_operator_challenges
BEGIN
 SELECT (CASE WHEN EXISTS (SELECT 1 FROM moderation_owner_challenges WHERE challenge_id=NEW.challenge_id OR challenge_value_sha256=NEW.challenge_value_sha256)
 THEN RAISE(ABORT,'cross-domain challenge replay') END);
 SELECT (CASE WHEN (SELECT COUNT(*) FROM moderation_owner_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)
  +(SELECT COUNT(*) FROM moderation_operator_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)>=12
  OR (SELECT COUNT(*) FROM moderation_owner_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch()
    AND NOT EXISTS (SELECT 1 FROM moderation_owner_challenge_consumptions r WHERE r.challenge_id=c.challenge_id))
  +(SELECT COUNT(*) FROM moderation_operator_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch()
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_challenge_consumptions r WHERE r.challenge_id=c.challenge_id))>=8
 THEN RAISE(ABORT,'shared operator challenge quota exceeded') END);
END;
CREATE TRIGGER moderation_owner_legacy_attempt_guard BEFORE INSERT ON moderation_operator_assertion_attempts
BEGIN
 SELECT (CASE WHEN EXISTS (SELECT 1 FROM moderation_owner_assertion_attempts WHERE assertion_sha256=NEW.assertion_sha256)
 THEN RAISE(ABORT,'cross-domain assertion attempt replay') END);
END;
CREATE TRIGGER moderation_owner_legacy_consumption_guard BEFORE INSERT ON moderation_operator_challenge_consumptions
BEGIN
 SELECT (CASE WHEN EXISTS (SELECT 1 FROM moderation_owner_challenge_consumptions WHERE verified_assertion_sha256=NEW.verified_assertion_sha256)
 THEN RAISE(ABORT,'cross-domain verified assertion replay') END);
 SELECT (CASE WHEN EXISTS (SELECT 1 FROM moderation_operator_credential_counters WHERE credential_id_sha256=NEW.credential_id_sha256
  AND ((NEW.authenticator_sign_count=0 AND sign_count>0) OR (NEW.authenticator_sign_count>0 AND NEW.authenticator_sign_count<=sign_count)))
 THEN RAISE(ABORT,'shared authenticator counter did not increase') END);
END;

CREATE TRIGGER moderation_owner_claim_insert BEFORE INSERT ON moderation_owner_read_claims
BEGIN
 SELECT (CASE WHEN NEW.claimed_at<>unixepoch() OR EXISTS (SELECT 1 FROM moderation_owner_read_claims
   WHERE challenge_id=NEW.challenge_id OR read_receipt_id=NEW.read_receipt_id)
  OR NOT EXISTS (SELECT 1 FROM moderation_owner_current_challenges c JOIN moderation_owner_challenge_consumptions r ON r.challenge_id=c.challenge_id
   WHERE c.challenge_id=NEW.challenge_id AND c.purpose='content_read' AND NEW.expires_at<=c.expires_at)
 THEN RAISE(ABORT,'owner read claim is stale or already spent') END);
END;
CREATE TRIGGER moderation_owner_read_event_insert BEFORE INSERT ON moderation_owner_read_events
BEGIN
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch()
  OR EXISTS (SELECT 1 FROM moderation_owner_read_events WHERE read_receipt_id=NEW.read_receipt_id AND phase=NEW.phase)
  OR EXISTS (SELECT 1 FROM moderation_owner_read_receipts WHERE read_receipt_id=NEW.read_receipt_id)
  OR EXISTS (SELECT 1 FROM moderation_owner_read_events WHERE read_receipt_id=NEW.read_receipt_id AND phase IN ('failed','delivery_unknown'))
 THEN RAISE(ABORT,'owner read audit cannot be replayed or contradicted') END);
 SELECT (CASE WHEN NEW.phase IN ('started','disclosure_ready') AND NOT EXISTS (
  SELECT 1 FROM moderation_owner_read_claims claim JOIN moderation_owner_current_challenges c ON c.challenge_id=claim.challenge_id
  WHERE claim.read_receipt_id=NEW.read_receipt_id AND claim.expires_at>unixepoch())
 THEN RAISE(ABORT,'owner read audit needs a live claim') END);
 SELECT (CASE WHEN NEW.phase='disclosure_ready' AND NOT EXISTS (
  SELECT 1 FROM moderation_owner_read_events WHERE read_receipt_id=NEW.read_receipt_id AND phase='started')
 THEN RAISE(ABORT,'disclosure requires a durable read-start audit') END);
END;
CREATE TRIGGER moderation_owner_receipt_insert BEFORE INSERT ON moderation_owner_read_receipts
BEGIN
 SELECT (CASE WHEN NEW.completed_at<>unixepoch()
  OR EXISTS (SELECT 1 FROM moderation_owner_read_receipts WHERE read_receipt_id=NEW.read_receipt_id)
  OR EXISTS (SELECT 1 FROM moderation_owner_read_events WHERE read_receipt_id=NEW.read_receipt_id AND phase IN ('failed','delivery_unknown'))
  OR NOT EXISTS (SELECT 1 FROM moderation_owner_read_claims claim
   JOIN moderation_owner_current_challenges c ON c.challenge_id=claim.challenge_id
   JOIN moderation_owner_read_events event ON event.read_receipt_id=claim.read_receipt_id AND event.phase='disclosure_ready'
   WHERE claim.read_receipt_id=NEW.read_receipt_id AND claim.expires_at>unixepoch())
 THEN RAISE(ABORT,'owner read receipt requires completed current disclosure') END);
END;
CREATE TRIGGER moderation_owner_decision_insert BEFORE INSERT ON moderation_owner_decisions
BEGIN
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch() OR EXISTS (SELECT 1 FROM moderation_owner_decisions
   WHERE decision_id=NEW.decision_id OR challenge_id=NEW.challenge_id OR case_reference_hmac=NEW.case_reference_hmac)
  OR NOT EXISTS (SELECT 1 FROM moderation_owner_current_challenges c
   JOIN moderation_owner_challenge_consumptions consumed ON consumed.challenge_id=c.challenge_id
   JOIN moderation_owner_read_receipts receipt ON receipt.read_receipt_id=c.read_receipt_id
   JOIN moderation_owner_read_claims claim ON claim.read_receipt_id=receipt.read_receipt_id
   JOIN moderation_owner_current_challenges read ON read.challenge_id=claim.challenge_id
   WHERE c.challenge_id=NEW.challenge_id AND c.purpose='decision' AND c.decision='no_action'
    AND c.case_reference_hmac=NEW.case_reference_hmac AND receipt.completed_at>unixepoch()-300
    AND read.policy_revision=c.policy_revision AND read.enrollment_admission_id=c.enrollment_admission_id
    AND read.access_session_sha256=c.access_session_sha256 AND read.credential_id_sha256=c.credential_id_sha256
    AND read.case_reference_hmac=c.case_reference_hmac AND read.case_reference_hmac_key_version=c.case_reference_hmac_key_version
    AND read.source_snapshot_sha256=c.source_snapshot_sha256)
 THEN RAISE(ABORT,'owner decision requires current signed same-source read') END);
END;
CREATE TRIGGER moderation_owner_decision_outbox AFTER INSERT ON moderation_owner_decisions
BEGIN
 INSERT INTO moderation_owner_reply_outbox(decision_id,report_id,recipient_participant_id,template_code,expires_at)
 SELECT NEW.decision_id,r.id,r.reporter_participant_id,'review_no_action_v1',MIN(r.content_expires_at,unixepoch()+86400)
 FROM moderation_owner_source_snapshots s JOIN moment_reports r ON r.id=s.report_id WHERE s.challenge_id=NEW.challenge_id;
 SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM moderation_owner_reply_outbox WHERE decision_id=NEW.decision_id)
 THEN RAISE(ABORT,'owner decision reply was not saved atomically') END);
 DELETE FROM moderation_advisory_jobs WHERE report_id=(
  SELECT report_id FROM moderation_operator_versioned_case_references WHERE case_reference_hmac=NEW.case_reference_hmac);
END;
CREATE TRIGGER moderation_owner_outbox_insert BEFORE INSERT ON moderation_owner_reply_outbox
BEGIN
 SELECT (CASE WHEN NEW.created_at<>unixepoch() OR EXISTS (SELECT 1 FROM moderation_owner_reply_outbox WHERE decision_id=NEW.decision_id)
 OR NOT EXISTS (SELECT 1 FROM moderation_owner_decisions d JOIN moderation_owner_challenges c ON c.challenge_id=d.challenge_id
  JOIN moderation_owner_source_snapshots s ON s.challenge_id=c.challenge_id JOIN moment_reports r ON r.id=s.report_id
  WHERE d.decision_id=NEW.decision_id AND d.recorded_at=unixepoch() AND r.id=NEW.report_id
   AND r.reporter_participant_id=NEW.recipient_participant_id AND c.reply_template=NEW.template_code
   AND NEW.expires_at=MIN(r.content_expires_at,unixepoch()+86400))
 THEN RAISE(ABORT,'owner reply recipient/template must come from the decided report') END);
END;

-- Callers also delete expired snapshots/outbox rows before local operations.
-- Their purge never deletes the consumed scope, counter or minimal decision.
CREATE TRIGGER moderation_owner_snapshot_no_reset BEFORE DELETE ON moderation_owner_source_snapshots
WHEN OLD.expires_at>unixepoch() AND EXISTS (SELECT 1 FROM moment_reports r WHERE r.id=OLD.report_id AND r.state='committed' AND r.closed_at IS NULL)
 AND EXISTS (SELECT 1 FROM moment_report_tombstones t WHERE t.report_id=OLD.report_id AND t.content_deleted_at IS NULL)
 AND NOT EXISTS (SELECT 1 FROM moment_object_deletions d WHERE d.object_key=OLD.object_key OR (d.object_type='report' AND d.owner_id=OLD.report_id))
BEGIN SELECT RAISE(ABORT,'live owner source cannot be reset'); END;
CREATE TRIGGER moderation_owner_outbox_no_reset BEFORE DELETE ON moderation_owner_reply_outbox
WHEN OLD.expires_at>unixepoch() AND EXISTS (SELECT 1 FROM moment_reports r WHERE r.id=OLD.report_id AND r.state='committed' AND r.closed_at IS NULL)
 AND EXISTS (SELECT 1 FROM moment_report_tombstones t WHERE t.report_id=OLD.report_id AND t.content_deleted_at IS NULL)
 AND NOT EXISTS (SELECT 1 FROM moment_object_deletions d WHERE (d.object_type='report' AND d.owner_id=OLD.report_id)
  OR d.object_key=(SELECT object_key FROM moment_reports WHERE id=OLD.report_id))
BEGIN SELECT RAISE(ABORT,'live saved owner reply cannot be reset'); END;
CREATE TRIGGER moderation_owner_closed AFTER UPDATE OF state,closed_at ON moment_reports
WHEN NEW.state<>'committed' OR NEW.closed_at IS NOT NULL
BEGIN
 DELETE FROM moderation_owner_source_snapshots WHERE report_id=NEW.id;
 DELETE FROM moderation_owner_reply_outbox WHERE report_id=NEW.id;
END;
CREATE TRIGGER moderation_owner_deleted AFTER UPDATE OF content_deleted_at ON moment_report_tombstones
WHEN NEW.content_deleted_at IS NOT NULL
BEGIN
 DELETE FROM moderation_owner_source_snapshots WHERE report_id=NEW.report_id;
 DELETE FROM moderation_owner_reply_outbox WHERE report_id=NEW.report_id;
END;
CREATE TRIGGER moderation_owner_deletion_pending AFTER INSERT ON moment_object_deletions
BEGIN
 DELETE FROM moderation_owner_source_snapshots WHERE object_key=NEW.object_key OR (NEW.object_type='report' AND report_id=NEW.owner_id);
 DELETE FROM moderation_owner_reply_outbox WHERE report_id IN (
  SELECT id FROM moment_reports WHERE object_key=NEW.object_key OR (NEW.object_type='report' AND id=NEW.owner_id));
END;
CREATE TRIGGER moderation_owner_snapshot_seals_immutable BEFORE UPDATE ON moderation_owner_snapshot_seals
BEGIN SELECT RAISE(ABORT,'source seals are immutable'); END;
CREATE TRIGGER moderation_owner_snapshot_seals_no_delete BEFORE DELETE ON moderation_owner_snapshot_seals
BEGIN SELECT RAISE(ABORT,'source seals cannot be reset'); END;

CREATE TRIGGER moderation_owner_policies_immutable BEFORE UPDATE ON moderation_owner_policies
BEGIN SELECT RAISE(ABORT, 'owner records are immutable'); END;
CREATE TRIGGER moderation_owner_policies_no_delete BEFORE DELETE ON moderation_owner_policies
BEGIN SELECT RAISE(ABORT, 'owner records cannot be deleted'); END;

CREATE TRIGGER moderation_owner_policy_revocations_immutable BEFORE UPDATE ON moderation_owner_policy_revocations
BEGIN SELECT RAISE(ABORT, 'owner records are immutable'); END;
CREATE TRIGGER moderation_owner_policy_revocations_no_delete BEFORE DELETE ON moderation_owner_policy_revocations
BEGIN SELECT RAISE(ABORT, 'owner records cannot be deleted'); END;

CREATE TRIGGER moderation_owner_challenges_immutable BEFORE UPDATE ON moderation_owner_challenges
BEGIN SELECT RAISE(ABORT, 'owner records are immutable'); END;
CREATE TRIGGER moderation_owner_challenges_no_delete BEFORE DELETE ON moderation_owner_challenges
BEGIN SELECT RAISE(ABORT, 'owner records cannot be deleted'); END;

CREATE TRIGGER moderation_owner_assertion_attempts_immutable BEFORE UPDATE ON moderation_owner_assertion_attempts
BEGIN SELECT RAISE(ABORT, 'owner records are immutable'); END;
CREATE TRIGGER moderation_owner_assertion_attempts_no_delete BEFORE DELETE ON moderation_owner_assertion_attempts
BEGIN SELECT RAISE(ABORT, 'owner records cannot be deleted'); END;

CREATE TRIGGER moderation_owner_challenge_consumptions_immutable BEFORE UPDATE ON moderation_owner_challenge_consumptions
BEGIN SELECT RAISE(ABORT, 'owner records are immutable'); END;
CREATE TRIGGER moderation_owner_challenge_consumptions_no_delete BEFORE DELETE ON moderation_owner_challenge_consumptions
BEGIN SELECT RAISE(ABORT, 'owner records cannot be deleted'); END;

CREATE TRIGGER moderation_owner_read_claims_immutable BEFORE UPDATE ON moderation_owner_read_claims
BEGIN SELECT RAISE(ABORT, 'owner records are immutable'); END;
CREATE TRIGGER moderation_owner_read_claims_no_delete BEFORE DELETE ON moderation_owner_read_claims
BEGIN SELECT RAISE(ABORT, 'owner records cannot be deleted'); END;

CREATE TRIGGER moderation_owner_read_events_immutable BEFORE UPDATE ON moderation_owner_read_events
BEGIN SELECT RAISE(ABORT, 'owner records are immutable'); END;
CREATE TRIGGER moderation_owner_read_events_no_delete BEFORE DELETE ON moderation_owner_read_events
BEGIN SELECT RAISE(ABORT, 'owner records cannot be deleted'); END;

CREATE TRIGGER moderation_owner_read_receipts_immutable BEFORE UPDATE ON moderation_owner_read_receipts
BEGIN SELECT RAISE(ABORT, 'owner records are immutable'); END;
CREATE TRIGGER moderation_owner_read_receipts_no_delete BEFORE DELETE ON moderation_owner_read_receipts
BEGIN SELECT RAISE(ABORT, 'owner records cannot be deleted'); END;

CREATE TRIGGER moderation_owner_decisions_immutable BEFORE UPDATE ON moderation_owner_decisions
BEGIN SELECT RAISE(ABORT, 'owner records are immutable'); END;
CREATE TRIGGER moderation_owner_decisions_no_delete BEFORE DELETE ON moderation_owner_decisions
BEGIN SELECT RAISE(ABORT, 'owner records cannot be deleted'); END;

CREATE TRIGGER moderation_owner_source_snapshots_immutable BEFORE UPDATE ON moderation_owner_source_snapshots
BEGIN SELECT RAISE(ABORT, 'private owner records are immutable'); END;

CREATE TRIGGER moderation_owner_reply_outbox_immutable BEFORE UPDATE ON moderation_owner_reply_outbox
BEGIN SELECT RAISE(ABORT, 'private owner records are immutable'); END;
