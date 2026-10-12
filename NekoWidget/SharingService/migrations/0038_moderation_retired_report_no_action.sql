-- Complete a retained report after sharing ends; hide/release remain live-target only.
DROP VIEW moderation_resolution_current_challenges;
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
  AND ((c.operation='no_action' AND m.state IN ('deleted','expired') AND m.closed_at IS NOT NULL AND m.closed_at<=unixepoch())
   OR (m.state='committed' AND m.closed_at IS NULL AND m.unreceived_expires_at>unixepoch()
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

-- Do not announce a retired photo as newly available when only its report closes.
DROP TRIGGER moderation_resolution_event_apply;
CREATE TRIGGER moderation_resolution_event_apply AFTER INSERT ON moderation_resolution_events
BEGIN
 INSERT INTO moderation_resolution_targets(event_id,moment_id,revision,space_id,key_epoch,ciphertext_sha256,committed_at,unreceived_expires_at)
 SELECT NEW.event_id,s.moment_id,c.expected_revision+1,s.space_id,s.key_epoch,s.ciphertext_sha256,s.committed_at,s.unreceived_expires_at
 FROM moderation_resolution_scopes s JOIN moderation_resolution_challenges c USING(challenge_id) WHERE c.challenge_id=NEW.challenge_id;
 INSERT INTO moment_changes(cursor,participant_id,change_type,moment_id,created_at,moderation_event_id)
 SELECT lower(hex(randomblob(16))),p.participant_id,'moment_committed',p.moment_id,unixepoch(),NEW.event_id
 FROM (SELECT m.sender_participant_id AS participant_id,m.id AS moment_id FROM moments m JOIN moderation_resolution_targets t ON t.moment_id=m.id WHERE t.event_id=NEW.event_id
  UNION SELECT d.recipient_participant_id,d.moment_id FROM moment_deliveries d JOIN moderation_resolution_targets t ON t.moment_id=d.moment_id WHERE t.event_id=NEW.event_id) p
 WHERE EXISTS(SELECT 1 FROM moderation_resolution_challenges c WHERE c.challenge_id=NEW.challenge_id AND c.operation<>'no_action')
  OR EXISTS(SELECT 1 FROM moments m JOIN moderation_resolution_scopes s ON s.moment_id=m.id WHERE s.challenge_id=NEW.challenge_id AND ((m.state='committed' AND m.closed_at IS NULL AND m.unreceived_expires_at>unixepoch() AND NOT EXISTS(SELECT 1 FROM moment_object_deletions d WHERE d.object_key=m.object_key OR (d.object_type='moment' AND d.owner_id=m.id))) OR EXISTS(SELECT 1 FROM family_record_moments link JOIN family_records record ON record.space_id=link.space_id AND record.id=link.photo_id WHERE link.moment_id=m.id AND link.space_id=m.space_id AND record.kind='photo' AND record.state='active' AND record.key_epoch=m.key_epoch)));
END;
