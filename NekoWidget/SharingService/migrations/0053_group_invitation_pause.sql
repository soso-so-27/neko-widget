-- Local operator control; migration alone keeps invitations open.
-- State is derived from append-only authenticated events, not a mutable flag.
CREATE TABLE group_invitation_challenges (
 id TEXT PRIMARY KEY,operator_id TEXT NOT NULL,credential_id_sha256 TEXT NOT NULL,
 enrollment_admission_id TEXT NOT NULL,access_session_sha256 TEXT NOT NULL,policy_revision INTEGER NOT NULL,
 value_sha256 TEXT NOT NULL,action TEXT NOT NULL CHECK(action IN('status','pause','resume')),
 state_revision INTEGER NOT NULL CHECK(state_revision>=0),
 created_at INTEGER NOT NULL DEFAULT(unixepoch()),expires_at INTEGER NOT NULL CHECK(expires_at>created_at)
) STRICT;
CREATE TABLE group_invitation_attempts (
 challenge_id TEXT PRIMARY KEY REFERENCES group_invitation_challenges(id),assertion_sha256 TEXT NOT NULL,
 created_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE group_invitation_consumptions (
 challenge_id TEXT PRIMARY KEY REFERENCES group_invitation_attempts(challenge_id),assertion_sha256 TEXT NOT NULL,
 authenticator_sign_count INTEGER NOT NULL CHECK(authenticator_sign_count>=0),created_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE group_invitation_events (
 revision INTEGER PRIMARY KEY CHECK(revision>0),challenge_id TEXT NOT NULL UNIQUE REFERENCES group_invitation_consumptions(challenge_id),
 paused INTEGER NOT NULL CHECK(paused IN(0,1)),created_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE VIEW group_invitation_state AS
 SELECT e.revision,e.paused,c.operator_id,e.created_at AS changed_at FROM group_invitation_events e
 JOIN group_invitation_challenges c ON c.id=e.challenge_id WHERE e.revision=(SELECT MAX(revision) FROM group_invitation_events)
 UNION ALL SELECT 0,0,NULL,NULL WHERE NOT EXISTS(SELECT 1 FROM group_invitation_events);
CREATE TRIGGER group_invitation_issue_guard BEFORE INSERT ON group_invitations
 WHEN (SELECT paused FROM group_invitation_state)=1 BEGIN SELECT RAISE(ABORT,'group_invitation_paused'); END;
-- The membership write and all roster/key/nonce/mutation writes share one D1
-- batch. Existing active members adding a device do not hit either guard.
CREATE TRIGGER group_invitation_member_insert_guard BEFORE INSERT ON group_members
 WHEN NEW.role='member' AND NEW.state='active' AND (SELECT paused FROM group_invitation_state)=1
 BEGIN SELECT RAISE(ABORT,'group_invitation_paused'); END;
CREATE TRIGGER group_invitation_member_rejoin_guard BEFORE UPDATE OF state ON group_members
 WHEN OLD.state<>'active' AND NEW.state='active' AND (SELECT paused FROM group_invitation_state)=1
 BEGIN SELECT RAISE(ABORT,'group_invitation_paused'); END;
CREATE TRIGGER group_invitation_event_guard BEFORE INSERT ON group_invitation_events BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM group_invitation_challenges c JOIN group_invitation_state s ON s.revision=c.state_revision
 WHERE c.id=NEW.challenge_id AND c.expires_at>unixepoch() AND NEW.revision=s.revision+1 AND NEW.paused<>s.paused
 AND ((c.action='pause' AND NEW.paused=1) OR (c.action='resume' AND NEW.paused=0)))
 THEN RAISE(ABORT,'group_invitation_state_changed') END);
END;
CREATE TRIGGER group_invitation_challenge_quota BEFORE INSERT ON group_invitation_challenges BEGIN
 SELECT (CASE WHEN (SELECT COUNT(*) FROM group_invitation_challenges WHERE operator_id=NEW.operator_id AND created_at>unixepoch()-300)>=40
 THEN RAISE(ABORT,'group_invitation_quota') END);
END;
CREATE TRIGGER group_invitation_consumption_guard BEFORE INSERT ON group_invitation_consumptions BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM group_invitation_challenges c JOIN group_invitation_attempts a ON a.challenge_id=c.id
 JOIN moderation_operator_credential_counters counter ON counter.credential_id_sha256=c.credential_id_sha256
 WHERE c.id=NEW.challenge_id AND a.assertion_sha256=NEW.assertion_sha256 AND c.expires_at>unixepoch()
 AND ((counter.sign_count=0 AND NEW.authenticator_sign_count=0) OR NEW.authenticator_sign_count>counter.sign_count))
 THEN RAISE(ABORT,'group_invitation_proof_not_current') END);
END;
CREATE TRIGGER group_invitation_challenges_no_update BEFORE UPDATE ON group_invitation_challenges BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_invitation_challenges_no_delete BEFORE DELETE ON group_invitation_challenges BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_invitation_attempts_no_update BEFORE UPDATE ON group_invitation_attempts BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_invitation_attempts_no_delete BEFORE DELETE ON group_invitation_attempts BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_invitation_consumptions_no_update BEFORE UPDATE ON group_invitation_consumptions BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_invitation_consumptions_no_delete BEFORE DELETE ON group_invitation_consumptions BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_invitation_events_no_update BEFORE UPDATE ON group_invitation_events BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER group_invitation_events_no_delete BEFORE DELETE ON group_invitation_events BEGIN SELECT RAISE(ABORT,'append_only'); END;
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
) GROUP BY credential_id_sha256;
