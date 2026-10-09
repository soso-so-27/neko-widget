-- Owner operations remain local-only; this migration grants no authority.
-- Immutable signature records are separate from cascade-deletable target and
-- recipient bindings. Existing delivery state, TTL and deletion are untouched.
-- The ACK guard also covers a hide racing the HTTP preflight read. It never
-- changes the original delivery expiry or turns hidden content into revoked.
CREATE TABLE moderation_resolution_challenges (
 challenge_id TEXT PRIMARY KEY CHECK(length(challenge_id)=36),
 policy_revision INTEGER NOT NULL REFERENCES moderation_owner_policies(policy_revision),
 operator_id TEXT NOT NULL, credential_id_sha256 TEXT NOT NULL, enrollment_admission_id TEXT NOT NULL,
 access_session_sha256 TEXT NOT NULL,
 challenge_value_sha256 TEXT NOT NULL UNIQUE CHECK(length(challenge_value_sha256)=64),
 case_reference_hmac TEXT NOT NULL, case_reference_hmac_key_version INTEGER NOT NULL,
 operation TEXT NOT NULL CHECK(operation IN ('hide','release','no_action')),
 expected_revision INTEGER NOT NULL CHECK(expected_revision>=0 AND expected_revision<2147483647),
 restriction_event_id TEXT,
 read_receipt_id TEXT,
 binding_sha256 TEXT NOT NULL CHECK(length(binding_sha256)=64),
 source_sha256 TEXT NOT NULL CHECK(length(source_sha256)=64),
 issued_at INTEGER NOT NULL DEFAULT(unixepoch()), expires_at INTEGER NOT NULL,
 CHECK(expires_at>issued_at AND expires_at<=issued_at+300),
 CHECK((operation='release' AND restriction_event_id IS NOT NULL AND read_receipt_id IS NULL)
    OR (operation IN ('hide','no_action') AND restriction_event_id IS NULL AND read_receipt_id IS NOT NULL))
) STRICT;
CREATE TABLE moderation_resolution_scopes (
 challenge_id TEXT PRIMARY KEY REFERENCES moderation_resolution_challenges(challenge_id),
 moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
 space_id TEXT NOT NULL, key_epoch INTEGER NOT NULL, ciphertext_sha256 TEXT NOT NULL,
 committed_at INTEGER NOT NULL, unreceived_expires_at INTEGER NOT NULL
) STRICT;
CREATE TABLE moderation_resolution_attempts (
 challenge_id TEXT PRIMARY KEY REFERENCES moderation_resolution_challenges(challenge_id),
 assertion_sha256 TEXT NOT NULL UNIQUE, attempted_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE moderation_resolution_consumptions (
 challenge_id TEXT PRIMARY KEY REFERENCES moderation_resolution_attempts(challenge_id),
 verified_assertion_sha256 TEXT NOT NULL UNIQUE,
 authenticator_sign_count INTEGER NOT NULL CHECK(authenticator_sign_count BETWEEN 0 AND 4294967295),
 consumed_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE moderation_resolution_events (
 event_id TEXT PRIMARY KEY CHECK(length(event_id)=36),
 challenge_id TEXT NOT NULL UNIQUE REFERENCES moderation_resolution_consumptions(challenge_id),
 recorded_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
ALTER TABLE moment_changes ADD COLUMN moderation_event_id TEXT REFERENCES moderation_resolution_events(event_id);
CREATE TABLE moderation_resolution_targets (
 event_id TEXT PRIMARY KEY REFERENCES moderation_resolution_events(event_id),
 moment_id TEXT NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL CHECK(revision>0 AND revision<=2147483647),
 space_id TEXT NOT NULL, key_epoch INTEGER NOT NULL, ciphertext_sha256 TEXT NOT NULL,
 committed_at INTEGER NOT NULL, unreceived_expires_at INTEGER NOT NULL,
 UNIQUE(moment_id,revision)
) STRICT;
CREATE TABLE moderation_resolution_replies (
 event_id TEXT PRIMARY KEY REFERENCES moderation_resolution_events(event_id),
 report_id TEXT NOT NULL REFERENCES moment_reports(id) ON DELETE CASCADE,
 recipient_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE CASCADE,
 template_code TEXT NOT NULL CHECK(template_code IN ('hide','release','no_action')),
 created_at INTEGER NOT NULL DEFAULT(unixepoch()), expires_at INTEGER NOT NULL,
 CHECK(expires_at>created_at AND expires_at<=created_at+86400)
) STRICT;
CREATE INDEX moderation_resolution_recipient ON moderation_resolution_replies(recipient_participant_id,created_at,event_id);
CREATE TABLE moderation_resolution_reply_receipts (
 event_id TEXT PRIMARY KEY REFERENCES moderation_resolution_replies(event_id) ON DELETE CASCADE,
 acknowledged_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;

CREATE VIEW moderation_resolution_case_states AS
 SELECT e.event_id,c.case_reference_hmac,c.case_reference_hmac_key_version,c.operation,c.source_sha256,t.*
 FROM moderation_resolution_events e JOIN moderation_resolution_challenges c USING(challenge_id)
 JOIN moderation_resolution_targets t ON t.event_id=e.event_id
 WHERE NOT EXISTS(SELECT 1 FROM moderation_resolution_events newer
  JOIN moderation_resolution_challenges nc ON nc.challenge_id=newer.challenge_id
  JOIN moderation_resolution_targets nt ON nt.event_id=newer.event_id
  WHERE nc.case_reference_hmac=c.case_reference_hmac AND nt.revision>t.revision);
CREATE VIEW moderation_moment_states AS
 SELECT moment_id,MAX(revision) AS revision,MAX(operation='hide') AS hidden
 FROM moderation_resolution_case_states GROUP BY moment_id;

CREATE TRIGGER moderation_resolution_ack_guard BEFORE INSERT ON moment_ack_events
WHEN EXISTS(SELECT 1 FROM moderation_moment_states WHERE moment_id=NEW.moment_id AND hidden=1)
BEGIN
 SELECT RAISE(ABORT,'moment moderation hidden');
END;

CREATE VIEW moderation_resolution_current_challenges AS
 SELECT c.* FROM moderation_resolution_challenges c
 JOIN moderation_owner_current_policies p ON p.policy_revision=c.policy_revision
  AND p.owner_operator_id=c.operator_id AND p.enrollment_admission_id=c.enrollment_admission_id
  AND p.credential_id_sha256=c.credential_id_sha256
 JOIN moderation_operator_access_sessions a ON a.access_session_sha256=c.access_session_sha256
  AND a.operator_id=c.operator_id AND a.access_subject_hmac=p.access_subject_hmac
  AND a.access_subject_hmac_key_version=p.access_subject_hmac_key_version
 JOIN moderation_resolution_scopes s ON s.challenge_id=c.challenge_id
 JOIN moments m ON m.id=s.moment_id AND m.space_id=s.space_id AND m.key_epoch=s.key_epoch
  AND m.ciphertext_sha256=s.ciphertext_sha256 AND m.committed_at=s.committed_at
  AND m.unreceived_expires_at=s.unreceived_expires_at
 JOIN moment_spaces ms ON ms.space_id=m.space_id AND ms.state='active'
 WHERE a.rowid>p.session_rowid_floor AND a.admitted_at>=p.created_at
  AND a.token_expires_at>unixepoch() AND a.admitted_at<=c.issued_at
  AND c.issued_at<=unixepoch() AND c.expires_at>unixepoch()
  AND ((m.state='committed' AND m.closed_at IS NULL AND m.unreceived_expires_at>unixepoch()
    AND NOT EXISTS(SELECT 1 FROM moment_object_deletions d WHERE d.object_key=m.object_key OR (d.object_type='moment' AND d.owner_id=m.id)))
   OR EXISTS(SELECT 1 FROM family_record_moments link JOIN family_records record ON record.space_id=link.space_id AND record.id=link.photo_id
     WHERE link.moment_id=m.id AND link.space_id=m.space_id AND record.kind='photo' AND record.state='active' AND record.key_epoch=m.key_epoch))
  AND c.expected_revision=COALESCE((SELECT revision FROM moderation_moment_states WHERE moment_id=m.id),0)
  AND NOT EXISTS(SELECT 1 FROM moderation_resolution_case_states cs WHERE cs.case_reference_hmac=c.case_reference_hmac AND cs.operation='no_action')
  AND ((c.operation='release' AND EXISTS(
    SELECT 1 FROM moderation_resolution_case_states cs WHERE cs.case_reference_hmac=c.case_reference_hmac
     AND cs.case_reference_hmac_key_version=c.case_reference_hmac_key_version
     AND cs.event_id=c.restriction_event_id AND cs.operation='hide' AND cs.moment_id=m.id
     AND cs.source_sha256=c.source_sha256 AND cs.space_id=m.space_id AND cs.key_epoch=m.key_epoch
     AND cs.ciphertext_sha256=m.ciphertext_sha256 AND cs.committed_at=m.committed_at
     AND cs.unreceived_expires_at=m.unreceived_expires_at))
   OR (c.operation IN ('hide','no_action')
    AND NOT EXISTS(SELECT 1 FROM moderation_resolution_case_states cs WHERE cs.case_reference_hmac=c.case_reference_hmac AND cs.operation='hide')
    AND EXISTS(SELECT 1 FROM moderation_owner_read_receipts receipt
     JOIN moderation_owner_read_claims claim ON claim.read_receipt_id=receipt.read_receipt_id
     JOIN moderation_owner_current_challenges rc ON rc.challenge_id=claim.challenge_id
     JOIN moderation_owner_source_snapshots snap ON snap.challenge_id=rc.challenge_id
     WHERE receipt.read_receipt_id=c.read_receipt_id AND claim.expires_at>unixepoch()
      AND rc.case_reference_hmac=c.case_reference_hmac AND rc.case_reference_hmac_key_version=c.case_reference_hmac_key_version
      AND rc.operator_id=c.operator_id AND rc.credential_id_sha256=c.credential_id_sha256
      AND rc.enrollment_admission_id=c.enrollment_admission_id AND rc.access_session_sha256=c.access_session_sha256
      AND rc.policy_revision=c.policy_revision AND rc.source_snapshot_sha256=c.source_sha256 AND snap.moment_id=m.id)));

DROP VIEW moderation_operator_credential_counters;
CREATE VIEW moderation_operator_credential_counters AS
 SELECT credential_id_sha256,MAX(sign_count) AS sign_count FROM (
  SELECT credential_id_sha256,registration_sign_count AS sign_count FROM moderation_operator_credentials
  UNION ALL SELECT credential_id_sha256,authenticator_sign_count FROM moderation_operator_challenge_consumptions
  UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM moderation_owner_challenge_consumptions r JOIN moderation_owner_challenges c USING(challenge_id)
  UNION ALL SELECT c.credential_id_sha256,r.authenticator_sign_count FROM moderation_resolution_consumptions r JOIN moderation_resolution_challenges c USING(challenge_id)
 ) GROUP BY credential_id_sha256;

CREATE TRIGGER moderation_resolution_scope_insert BEFORE INSERT ON moderation_resolution_scopes
BEGIN
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_resolution_challenges c
   JOIN moderation_resolution_challenges old ON old.case_reference_hmac=c.case_reference_hmac
   JOIN moderation_resolution_events e ON e.challenge_id=old.challenge_id
   LEFT JOIN moderation_resolution_targets t ON t.event_id=e.event_id
   WHERE c.challenge_id=NEW.challenge_id AND (t.moment_id IS NULL OR t.moment_id<>NEW.moment_id
    OR t.space_id<>NEW.space_id OR t.key_epoch<>NEW.key_epoch OR t.ciphertext_sha256<>NEW.ciphertext_sha256
    OR t.committed_at<>NEW.committed_at OR t.unreceived_expires_at<>NEW.unreceived_expires_at))
  THEN RAISE(ABORT,'resolution case target cannot change') END);
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_resolution_scopes WHERE challenge_id=NEW.challenge_id)
  OR NOT EXISTS(SELECT 1 FROM moderation_resolution_challenges c JOIN moments m ON m.id=NEW.moment_id
   WHERE c.challenge_id=NEW.challenge_id AND c.issued_at=unixepoch() AND m.space_id=NEW.space_id AND m.key_epoch=NEW.key_epoch
    AND m.ciphertext_sha256=NEW.ciphertext_sha256 AND m.committed_at=NEW.committed_at AND m.unreceived_expires_at=NEW.unreceived_expires_at
    AND ((c.operation='release' AND EXISTS(SELECT 1 FROM moderation_resolution_case_states cs WHERE cs.event_id=c.restriction_event_id AND cs.moment_id=m.id))
      OR EXISTS(SELECT 1 FROM moderation_owner_read_claims claim JOIN moderation_owner_source_snapshots s USING(challenge_id)
       WHERE claim.read_receipt_id=c.read_receipt_id AND s.moment_id=m.id)))
 THEN RAISE(ABORT,'resolution scope must be database derived') END);
END;
CREATE TRIGGER moderation_resolution_scope_admitted AFTER INSERT ON moderation_resolution_scopes
BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM moderation_resolution_current_challenges WHERE challenge_id=NEW.challenge_id)
 THEN RAISE(ABORT,'resolution scope is not current') END);
END;
CREATE TRIGGER moderation_resolution_attempt_insert BEFORE INSERT ON moderation_resolution_attempts
BEGIN
 SELECT (CASE WHEN NEW.attempted_at<>unixepoch() OR length(NEW.assertion_sha256)<>64 OR NEW.assertion_sha256 GLOB '*[^0-9a-f]*'
  OR NOT EXISTS(SELECT 1 FROM moderation_resolution_current_challenges WHERE challenge_id=NEW.challenge_id)
  OR EXISTS(SELECT 1 FROM moderation_resolution_attempts WHERE challenge_id=NEW.challenge_id OR assertion_sha256=NEW.assertion_sha256)
  OR EXISTS(SELECT 1 FROM moderation_owner_assertion_attempts WHERE assertion_sha256=NEW.assertion_sha256)
  OR EXISTS(SELECT 1 FROM moderation_operator_assertion_attempts WHERE assertion_sha256=NEW.assertion_sha256)
 THEN RAISE(ABORT,'resolution attempt replay or stale scope') END);
END;
CREATE TRIGGER moderation_resolution_consumption_insert BEFORE INSERT ON moderation_resolution_consumptions
BEGIN
 SELECT (CASE WHEN NEW.consumed_at<>unixepoch()
  OR NOT EXISTS(SELECT 1 FROM moderation_resolution_current_challenges c JOIN moderation_resolution_attempts a USING(challenge_id)
   WHERE c.challenge_id=NEW.challenge_id AND a.assertion_sha256=NEW.verified_assertion_sha256 AND a.attempted_at<=NEW.consumed_at)
  OR EXISTS(SELECT 1 FROM moderation_resolution_consumptions WHERE challenge_id=NEW.challenge_id OR verified_assertion_sha256=NEW.verified_assertion_sha256)
  OR EXISTS(SELECT 1 FROM moderation_owner_challenge_consumptions WHERE verified_assertion_sha256=NEW.verified_assertion_sha256)
  OR EXISTS(SELECT 1 FROM moderation_operator_challenge_consumptions WHERE verified_assertion_sha256=NEW.verified_assertion_sha256)
 THEN RAISE(ABORT,'resolution consumption replay or stale scope') END);
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_resolution_challenges c JOIN moderation_operator_credential_counters k USING(credential_id_sha256)
  WHERE c.challenge_id=NEW.challenge_id AND ((NEW.authenticator_sign_count=0 AND k.sign_count>0)
    OR (NEW.authenticator_sign_count>0 AND NEW.authenticator_sign_count<=k.sign_count)))
 THEN RAISE(ABORT,'shared authenticator counter did not increase') END);
END;
CREATE TRIGGER moderation_resolution_event_insert BEFORE INSERT ON moderation_resolution_events
BEGIN
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch() OR EXISTS(SELECT 1 FROM moderation_resolution_events WHERE event_id=NEW.event_id OR challenge_id=NEW.challenge_id)
  OR NOT EXISTS(SELECT 1 FROM moderation_resolution_current_challenges c JOIN moderation_resolution_consumptions consumed USING(challenge_id)
    WHERE c.challenge_id=NEW.challenge_id AND consumed.consumed_at=unixepoch())
 THEN RAISE(ABORT,'resolution event requires current signed scope') END);
END;
CREATE TRIGGER moderation_resolution_event_apply AFTER INSERT ON moderation_resolution_events
BEGIN
 INSERT INTO moderation_resolution_targets(event_id,moment_id,revision,space_id,key_epoch,ciphertext_sha256,committed_at,unreceived_expires_at)
 SELECT NEW.event_id,s.moment_id,c.expected_revision+1,s.space_id,s.key_epoch,s.ciphertext_sha256,s.committed_at,s.unreceived_expires_at
 FROM moderation_resolution_scopes s JOIN moderation_resolution_challenges c USING(challenge_id) WHERE c.challenge_id=NEW.challenge_id;
 INSERT INTO moment_changes(cursor,participant_id,change_type,moment_id,created_at,moderation_event_id)
 SELECT lower(hex(randomblob(16))),p.participant_id,'moment_committed',p.moment_id,unixepoch(),NEW.event_id
 FROM (SELECT m.sender_participant_id AS participant_id,m.id AS moment_id FROM moments m JOIN moderation_resolution_targets t ON t.moment_id=m.id WHERE t.event_id=NEW.event_id
  UNION SELECT d.recipient_participant_id,d.moment_id FROM moment_deliveries d JOIN moderation_resolution_targets t ON t.moment_id=d.moment_id WHERE t.event_id=NEW.event_id) p;
END;
CREATE TRIGGER moderation_resolution_target_insert BEFORE INSERT ON moderation_resolution_targets
BEGIN
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_resolution_targets WHERE event_id=NEW.event_id)
  OR NOT EXISTS(SELECT 1 FROM moderation_resolution_events e JOIN moderation_resolution_challenges c USING(challenge_id)
   JOIN moderation_resolution_scopes s USING(challenge_id) WHERE e.event_id=NEW.event_id AND e.recorded_at=unixepoch()
   AND NEW.moment_id=s.moment_id AND NEW.revision=c.expected_revision+1 AND NEW.space_id=s.space_id AND NEW.key_epoch=s.key_epoch
   AND NEW.ciphertext_sha256=s.ciphertext_sha256 AND NEW.committed_at=s.committed_at AND NEW.unreceived_expires_at=s.unreceived_expires_at)
 THEN RAISE(ABORT,'resolution target must match signed scope') END);
END;
-- Reply insertion additionally requires runtime verification of the full source
-- digest against the signed source (including for release). No old recipient is
-- retained/reconstituted when source content has expired or changed.
CREATE TRIGGER moderation_resolution_reply_insert BEFORE INSERT ON moderation_resolution_replies
BEGIN
 SELECT (CASE WHEN NEW.created_at<>unixepoch() OR EXISTS(SELECT 1 FROM moderation_resolution_replies WHERE event_id=NEW.event_id)
  OR NOT EXISTS(SELECT 1 FROM moderation_resolution_events e JOIN moderation_resolution_challenges c USING(challenge_id)
   JOIN moderation_resolution_targets target ON target.event_id=e.event_id
   JOIN moderation_operator_versioned_case_references ref ON ref.case_reference_hmac=c.case_reference_hmac
   JOIN moment_reports r ON r.id=ref.report_id JOIN moment_report_tombstones t ON t.report_id=r.id
   WHERE e.event_id=NEW.event_id AND e.recorded_at=unixepoch() AND r.id=NEW.report_id AND r.moment_id=target.moment_id
    AND r.reporter_participant_id=NEW.recipient_participant_id AND c.operation=NEW.template_code
    AND r.state='committed' AND r.closed_at IS NULL AND r.content_expires_at>unixepoch() AND t.content_deleted_at IS NULL
    AND NEW.expires_at=MIN(r.content_expires_at,unixepoch()+86400)
    AND NOT EXISTS(SELECT 1 FROM moment_object_deletions d WHERE d.object_key=r.object_key OR (d.object_type='report' AND d.owner_id=r.id)))
 THEN RAISE(ABORT,'resolution reply requires live reporter binding') END);
END;
CREATE TRIGGER moderation_resolution_reply_receipt_insert BEFORE INSERT ON moderation_resolution_reply_receipts
BEGIN
 SELECT (CASE WHEN NEW.acknowledged_at<>unixepoch() OR NOT EXISTS(SELECT 1 FROM moderation_resolution_replies WHERE event_id=NEW.event_id AND expires_at>unixepoch())
 THEN RAISE(ABORT,'resolution reply receipt expired') END);
END;
CREATE TRIGGER moderation_resolution_report_closed AFTER UPDATE ON moment_reports
WHEN NEW.state<>'committed' OR NEW.closed_at IS NOT NULL
 OR NEW.moment_id IS NOT OLD.moment_id OR NEW.reporter_participant_id IS NOT OLD.reporter_participant_id
 OR NEW.reason_code IS NOT OLD.reason_code OR NEW.moderation_key_id IS NOT OLD.moderation_key_id
 OR NEW.object_key IS NOT OLD.object_key OR NEW.ciphertext_size IS NOT OLD.ciphertext_size
 OR NEW.ciphertext_sha256 IS NOT OLD.ciphertext_sha256 OR NEW.committed_at IS NOT OLD.committed_at
 OR NEW.content_expires_at IS NOT OLD.content_expires_at OR NEW.space_id IS NOT OLD.space_id
BEGIN DELETE FROM moderation_resolution_replies WHERE report_id=NEW.id; END;
CREATE TRIGGER moderation_resolution_report_deleted AFTER UPDATE OF content_deleted_at ON moment_report_tombstones
WHEN NEW.content_deleted_at IS NOT NULL
BEGIN DELETE FROM moderation_resolution_replies WHERE report_id=NEW.report_id; END;
CREATE TRIGGER moderation_resolution_report_pending AFTER INSERT ON moment_object_deletions
BEGIN DELETE FROM moderation_resolution_replies WHERE report_id IN(SELECT id FROM moment_reports WHERE object_key=NEW.object_key OR (NEW.object_type='report' AND id=NEW.owner_id)); END;
CREATE TRIGGER moderation_resolution_old_no_action BEFORE INSERT ON moderation_owner_decisions
BEGIN
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_resolution_case_states WHERE case_reference_hmac=NEW.case_reference_hmac AND operation IN ('hide','no_action'))
 THEN RAISE(ABORT,'case already restricted or decided') END);
END;

CREATE TRIGGER resolution_shared_challenge_0 BEFORE INSERT ON moderation_operator_challenges
BEGIN
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_owner_challenges WHERE challenge_id=NEW.challenge_id OR challenge_value_sha256=NEW.challenge_value_sha256) OR EXISTS(SELECT 1 FROM moderation_resolution_challenges WHERE challenge_id=NEW.challenge_id OR challenge_value_sha256=NEW.challenge_value_sha256) THEN RAISE(ABORT,'cross-domain challenge replay') END);
 SELECT (CASE WHEN (SELECT COUNT(*) FROM moderation_operator_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)+(SELECT COUNT(*) FROM moderation_owner_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)+(SELECT COUNT(*) FROM moderation_resolution_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)>=12 OR (SELECT COUNT(*) FROM moderation_operator_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch() AND NOT EXISTS(SELECT 1 FROM moderation_operator_challenge_consumptions WHERE challenge_id=c.challenge_id))+(SELECT COUNT(*) FROM moderation_owner_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch() AND NOT EXISTS(SELECT 1 FROM moderation_owner_challenge_consumptions WHERE challenge_id=c.challenge_id))+(SELECT COUNT(*) FROM moderation_resolution_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch() AND NOT EXISTS(SELECT 1 FROM moderation_resolution_consumptions WHERE challenge_id=c.challenge_id))>=8 THEN RAISE(ABORT,'shared operator challenge quota exceeded') END);
END;
CREATE TRIGGER resolution_shared_attempt_0 BEFORE INSERT ON moderation_operator_assertion_attempts
BEGIN SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_resolution_attempts WHERE assertion_sha256=NEW.assertion_sha256)
 THEN RAISE(ABORT,'cross-domain assertion attempt replay') END); END;
CREATE TRIGGER resolution_shared_consumption_0 BEFORE INSERT ON moderation_operator_challenge_consumptions
BEGIN SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_resolution_consumptions WHERE verified_assertion_sha256=NEW.verified_assertion_sha256)
 THEN RAISE(ABORT,'cross-domain verified assertion replay') END); END;

CREATE TRIGGER resolution_shared_challenge_1 BEFORE INSERT ON moderation_owner_challenges
BEGIN
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_operator_challenges WHERE challenge_id=NEW.challenge_id OR challenge_value_sha256=NEW.challenge_value_sha256) OR EXISTS(SELECT 1 FROM moderation_resolution_challenges WHERE challenge_id=NEW.challenge_id OR challenge_value_sha256=NEW.challenge_value_sha256) THEN RAISE(ABORT,'cross-domain challenge replay') END);
 SELECT (CASE WHEN (SELECT COUNT(*) FROM moderation_operator_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)+(SELECT COUNT(*) FROM moderation_owner_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)+(SELECT COUNT(*) FROM moderation_resolution_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)>=12 OR (SELECT COUNT(*) FROM moderation_operator_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch() AND NOT EXISTS(SELECT 1 FROM moderation_operator_challenge_consumptions WHERE challenge_id=c.challenge_id))+(SELECT COUNT(*) FROM moderation_owner_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch() AND NOT EXISTS(SELECT 1 FROM moderation_owner_challenge_consumptions WHERE challenge_id=c.challenge_id))+(SELECT COUNT(*) FROM moderation_resolution_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch() AND NOT EXISTS(SELECT 1 FROM moderation_resolution_consumptions WHERE challenge_id=c.challenge_id))>=8 THEN RAISE(ABORT,'shared operator challenge quota exceeded') END);
END;
CREATE TRIGGER resolution_shared_attempt_1 BEFORE INSERT ON moderation_owner_assertion_attempts
BEGIN SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_resolution_attempts WHERE assertion_sha256=NEW.assertion_sha256)
 THEN RAISE(ABORT,'cross-domain assertion attempt replay') END); END;
CREATE TRIGGER resolution_shared_consumption_1 BEFORE INSERT ON moderation_owner_challenge_consumptions
BEGIN SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_resolution_consumptions WHERE verified_assertion_sha256=NEW.verified_assertion_sha256)
 THEN RAISE(ABORT,'cross-domain verified assertion replay') END); END;

CREATE TRIGGER resolution_shared_challenge_2 BEFORE INSERT ON moderation_resolution_challenges
BEGIN
 SELECT (CASE WHEN EXISTS(SELECT 1 FROM moderation_operator_challenges WHERE challenge_id=NEW.challenge_id OR challenge_value_sha256=NEW.challenge_value_sha256) OR EXISTS(SELECT 1 FROM moderation_owner_challenges WHERE challenge_id=NEW.challenge_id OR challenge_value_sha256=NEW.challenge_value_sha256) THEN RAISE(ABORT,'cross-domain challenge replay') END);
 SELECT (CASE WHEN (SELECT COUNT(*) FROM moderation_operator_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)+(SELECT COUNT(*) FROM moderation_owner_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)+(SELECT COUNT(*) FROM moderation_resolution_challenges WHERE operator_id=NEW.operator_id AND issued_at>unixepoch()-300)>=12 OR (SELECT COUNT(*) FROM moderation_operator_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch() AND NOT EXISTS(SELECT 1 FROM moderation_operator_challenge_consumptions WHERE challenge_id=c.challenge_id))+(SELECT COUNT(*) FROM moderation_owner_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch() AND NOT EXISTS(SELECT 1 FROM moderation_owner_challenge_consumptions WHERE challenge_id=c.challenge_id))+(SELECT COUNT(*) FROM moderation_resolution_challenges c WHERE operator_id=NEW.operator_id AND expires_at>=unixepoch() AND NOT EXISTS(SELECT 1 FROM moderation_resolution_consumptions WHERE challenge_id=c.challenge_id))>=8 THEN RAISE(ABORT,'shared operator challenge quota exceeded') END);
END;

CREATE TRIGGER resolution_challenge_insert BEFORE INSERT ON moderation_resolution_challenges
BEGIN
 SELECT (CASE WHEN NEW.issued_at<>unixepoch() OR NEW.challenge_value_sha256 GLOB '*[^0-9a-f]*'
 OR NEW.binding_sha256 GLOB '*[^0-9a-f]*' OR NEW.source_sha256 GLOB '*[^0-9a-f]*'
 OR EXISTS(SELECT 1 FROM moderation_resolution_challenges WHERE challenge_id=NEW.challenge_id OR challenge_value_sha256=NEW.challenge_value_sha256)
 THEN RAISE(ABORT,'resolution challenge replay or invalid scope') END);
END;
CREATE TRIGGER moderation_resolution_challenges_immutable BEFORE UPDATE ON moderation_resolution_challenges
BEGIN SELECT RAISE(ABORT,'resolution records are immutable'); END;
CREATE TRIGGER moderation_resolution_challenges_no_delete BEFORE DELETE ON moderation_resolution_challenges
BEGIN SELECT RAISE(ABORT,'resolution records cannot be deleted'); END;
CREATE TRIGGER moderation_resolution_attempts_immutable BEFORE UPDATE ON moderation_resolution_attempts
BEGIN SELECT RAISE(ABORT,'resolution records are immutable'); END;
CREATE TRIGGER moderation_resolution_attempts_no_delete BEFORE DELETE ON moderation_resolution_attempts
BEGIN SELECT RAISE(ABORT,'resolution records cannot be deleted'); END;
CREATE TRIGGER moderation_resolution_consumptions_immutable BEFORE UPDATE ON moderation_resolution_consumptions
BEGIN SELECT RAISE(ABORT,'resolution records are immutable'); END;
CREATE TRIGGER moderation_resolution_consumptions_no_delete BEFORE DELETE ON moderation_resolution_consumptions
BEGIN SELECT RAISE(ABORT,'resolution records cannot be deleted'); END;
CREATE TRIGGER moderation_resolution_events_immutable BEFORE UPDATE ON moderation_resolution_events
BEGIN SELECT RAISE(ABORT,'resolution records are immutable'); END;
CREATE TRIGGER moderation_resolution_events_no_delete BEFORE DELETE ON moderation_resolution_events
BEGIN SELECT RAISE(ABORT,'resolution records cannot be deleted'); END;
CREATE TRIGGER moderation_resolution_scopes_immutable BEFORE UPDATE ON moderation_resolution_scopes
BEGIN SELECT RAISE(ABORT,'resolution payload is immutable'); END;
CREATE TRIGGER moderation_resolution_targets_immutable BEFORE UPDATE ON moderation_resolution_targets
BEGIN SELECT RAISE(ABORT,'resolution payload is immutable'); END;
CREATE TRIGGER moderation_resolution_replies_immutable BEFORE UPDATE ON moderation_resolution_replies
BEGIN SELECT RAISE(ABORT,'resolution payload is immutable'); END;
CREATE TRIGGER moderation_resolution_reply_receipts_immutable BEFORE UPDATE ON moderation_resolution_reply_receipts
BEGIN SELECT RAISE(ABORT,'resolution payload is immutable'); END;
CREATE TRIGGER resolution_scope_no_reset BEFORE DELETE ON moderation_resolution_scopes
WHEN EXISTS(SELECT 1 FROM moderation_resolution_challenges c JOIN moments m ON m.id=OLD.moment_id
 WHERE c.challenge_id=OLD.challenge_id AND c.expires_at>unixepoch() AND (m.state='committed'
 OR EXISTS(SELECT 1 FROM family_record_moments link JOIN family_records record ON record.space_id=link.space_id AND record.id=link.photo_id
  WHERE link.moment_id=m.id AND link.space_id=m.space_id AND record.kind='photo' AND record.state='active' AND record.key_epoch=m.key_epoch)))
BEGIN SELECT RAISE(ABORT,'live resolution scope cannot reset'); END;
CREATE TRIGGER resolution_target_no_reset BEFORE DELETE ON moderation_resolution_targets
WHEN EXISTS(SELECT 1 FROM moments m WHERE m.id=OLD.moment_id AND ((m.state='committed' AND m.unreceived_expires_at>unixepoch())
 OR EXISTS(SELECT 1 FROM family_record_moments link JOIN family_records record ON record.space_id=link.space_id AND record.id=link.photo_id
  WHERE link.moment_id=m.id AND link.space_id=m.space_id AND record.kind='photo' AND record.state='active' AND record.key_epoch=m.key_epoch)))
BEGIN SELECT RAISE(ABORT,'live resolution target cannot reset'); END;
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
 AND NOT EXISTS (SELECT 1 FROM moderation_owner_decisions d WHERE d.case_reference_hmac=c.case_reference_hmac)
 AND NOT EXISTS (SELECT 1 FROM moderation_resolution_case_states x WHERE x.case_reference_hmac=c.case_reference_hmac AND x.operation='no_action');
DROP TRIGGER moderation_advisory_job_retention;
CREATE TRIGGER moderation_advisory_job_retention BEFORE DELETE ON moderation_advisory_jobs
WHEN OLD.expires_at>unixepoch() AND EXISTS (
 SELECT 1 FROM moment_reports WHERE id=OLD.report_id AND state='committed' AND closed_at IS NULL
) AND EXISTS (SELECT 1 FROM moment_report_tombstones WHERE report_id=OLD.report_id AND content_deleted_at IS NULL)
 AND NOT EXISTS (SELECT 1 FROM moderation_case_events WHERE report_id=OLD.report_id AND event_type='review_decided')
 AND NOT EXISTS (SELECT 1 FROM moderation_owner_decisions d
  JOIN moderation_operator_versioned_case_references r ON r.case_reference_hmac=d.case_reference_hmac WHERE r.report_id=OLD.report_id)
 AND NOT EXISTS (SELECT 1 FROM moderation_resolution_case_states x JOIN moderation_operator_versioned_case_references ref ON ref.case_reference_hmac=x.case_reference_hmac WHERE ref.report_id=OLD.report_id AND x.operation='no_action')
BEGIN SELECT RAISE(ABORT,'live advisory cannot be reset'); END;
