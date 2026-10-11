-- Preserve every existing assertion floor when adding transferred owner scope.
-- 0035 is already installed, so restore the missing pre-admission possession
-- source with a new migration without rewriting historical records.
DROP VIEW moderation_operator_credential_counters;
CREATE VIEW moderation_operator_credential_counters AS
SELECT credential_id_sha256, MAX(sign_count) AS sign_count FROM (
 SELECT credential_id_sha256, sign_count FROM (
 SELECT credential_id_sha256, registration_sign_count AS sign_count FROM moderation_operator_credentials
 UNION ALL SELECT credential_id_sha256, authenticator_sign_count FROM moderation_operator_challenge_consumptions
 UNION ALL SELECT c.credential_id_sha256, r.authenticator_sign_count FROM moderation_owner_challenge_consumptions r JOIN moderation_owner_challenges c USING(challenge_id)
 UNION ALL SELECT c.credential_id_sha256, r.authenticator_sign_count FROM moderation_resolution_consumptions r JOIN moderation_resolution_challenges c USING(challenge_id)
 UNION ALL SELECT credential_id_sha256, authenticator_sign_count FROM moderation_operator_enrollment_ceremony_possessions
 )
 UNION ALL SELECT q.target_credential_id_sha256, s.counter_floor FROM moderation_owner_scope_adoptions s JOIN moderation_operator_enrollment_requests q USING(enrollment_request_id)
) GROUP BY credential_id_sha256;
