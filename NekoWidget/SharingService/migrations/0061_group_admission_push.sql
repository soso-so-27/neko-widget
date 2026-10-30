PRAGMA foreign_keys=ON;
CREATE TABLE group_join_admission_proofs (request_id TEXT PRIMARY KEY REFERENCES group_join_requests(id) ON DELETE CASCADE, proof_json TEXT NOT NULL) STRICT;
CREATE TABLE group_join_push_subscriptions (
 space_id TEXT NOT NULL REFERENCES group_windows(space_id), device_id TEXT NOT NULL REFERENCES group_person_devices(id),
 token_ciphertext TEXT NOT NULL, token_nonce TEXT NOT NULL, token_digest TEXT NOT NULL, encryption_key_id TEXT NOT NULL,
 environment TEXT NOT NULL CHECK(environment IN ('development','production')), generation INTEGER NOT NULL, expires_at INTEGER NOT NULL,
 PRIMARY KEY(space_id,device_id)
) STRICT;
CREATE INDEX group_join_push_digest ON group_join_push_subscriptions(token_digest);
CREATE TABLE group_admission_deliveries (
 event_id TEXT NOT NULL, device_id TEXT NOT NULL REFERENCES group_person_devices(id), token_digest TEXT NOT NULL,
 subscription_generation INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','leased','accepted','invalid','skipped')),
 attempts INTEGER NOT NULL DEFAULT 0, available_at INTEGER NOT NULL, lease_id TEXT, lease_expires_at INTEGER,
 PRIMARY KEY(event_id,device_id)
) STRICT;
CREATE INDEX group_admission_queue ON group_admission_deliveries(state,available_at);
-- Derived from committed requests: a lost enqueue, late registration or Worker restart cannot lose an event.
-- No photos, names, private keys or pre-admission media permissions are granted by these views.
CREATE VIEW group_admission_recipients AS
SELECT j.id||'-requested' AS event_id,j.id AS request_id,j.space_id,'join_requested' AS kind,
 s.device_id,s.token_digest,s.generation AS subscription_generation,s.token_ciphertext,s.token_nonce,s.encryption_key_id,s.environment,j.expires_at
FROM group_join_requests j JOIN group_invitations i ON i.id=j.invitation_id
JOIN group_windows w ON w.space_id=j.space_id
JOIN group_members m ON m.space_id=w.space_id AND m.person_id=w.owner_person_id AND m.role='owner' AND m.state='active'
JOIN group_window_devices wd ON wd.space_id=w.space_id AND wd.participant_id=m.participant_id AND wd.state='active'
JOIN group_push_subscriptions s ON s.space_id=wd.space_id AND s.device_id=wd.device_id
JOIN group_person_devices d ON d.id=s.device_id AND d.state='active'
JOIN group_people p ON p.id=d.person_id AND p.state='active'
JOIN group_person_devices applicant ON applicant.id=j.candidate_device_id AND applicant.person_id=j.person_id AND applicant.state='active'
JOIN group_people ap ON ap.id=j.person_id AND ap.state='active'
WHERE j.state='pending' AND w.mode='active' AND i.revoked_at IS NULL AND i.expires_at>unixepoch()
 AND j.expires_at>unixepoch() AND s.expires_at>unixepoch()
UNION ALL
SELECT j.id||'-approved',j.id,j.space_id,'join_approved',s.device_id,s.token_digest,s.generation,
 s.token_ciphertext,s.token_nonce,s.encryption_key_id,s.environment,j.expires_at
FROM group_join_requests j JOIN group_windows w ON w.space_id=j.space_id
JOIN group_join_push_subscriptions s ON s.space_id=j.space_id AND s.device_id=j.candidate_device_id
JOIN group_window_devices wd ON wd.space_id=j.space_id AND wd.device_id=j.candidate_device_id AND wd.state='active'
JOIN group_members m ON m.space_id=j.space_id AND m.participant_id=wd.participant_id AND m.person_id=j.person_id AND m.state='active'
JOIN group_person_devices d ON d.id=s.device_id AND d.person_id=m.person_id AND d.state='active'
JOIN group_people p ON p.id=d.person_id AND p.state='active'
WHERE j.state='approved' AND w.mode='active' AND j.expires_at>unixepoch() AND s.expires_at>unixepoch()
 AND wd.added_revision=j.result_revision;
CREATE VIEW group_live_admission_deliveries AS
SELECT v.* FROM group_admission_recipients v JOIN group_admission_deliveries q
 ON q.event_id=v.event_id AND q.device_id=v.device_id AND q.token_digest=v.token_digest AND q.subscription_generation=v.subscription_generation;
