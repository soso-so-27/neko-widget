-- The public deletion route is not installed by this migration. Only the
-- executor which has matched the independent fence creates this command. It
-- exists inside one transaction and never stores keys, receipts or names.
CREATE TABLE group_identity_erasure_commands (
 person_id TEXT PRIMARY KEY REFERENCES group_people(id),
 request_id TEXT NOT NULL UNIQUE,
 accepted_at INTEGER NOT NULL CHECK(accepted_at>0)
) STRICT;

DROP TRIGGER group_devices_immutable_identity;
CREATE TRIGGER group_devices_immutable_identity BEFORE UPDATE ON group_person_devices
BEGIN
 SELECT (CASE WHEN NEW.id<>OLD.id OR NEW.person_id<>OLD.person_id OR (OLD.state='revoked' AND NEW.state<>'revoked')
  OR (OLD.signing_public_key='deleted:'||OLD.id AND NEW.authorization<>'')
  OR ((NEW.signing_public_key<>OLD.signing_public_key OR NEW.hpke_public_key<>OLD.hpke_public_key)
   AND NOT EXISTS(SELECT 1 FROM group_identity_erasure_commands c WHERE c.person_id=OLD.person_id
    AND NEW.signing_public_key='deleted:'||OLD.id AND NEW.hpke_public_key='deleted:'||OLD.id
    AND NEW.state='revoked' AND NEW.authorization='' AND NEW.created_at=OLD.created_at
    AND NEW.revoked_at=COALESCE(OLD.revoked_at,c.accepted_at)))
  THEN RAISE(ABORT,'group_device_identity_immutable') END);
END;
CREATE TRIGGER group_identity_erasure_person_key BEFORE UPDATE ON group_people
WHEN (NEW.identity_public_key<>OLD.identity_public_key AND NOT EXISTS(
 SELECT 1 FROM group_identity_erasure_commands c WHERE c.person_id=OLD.id AND NEW.id=OLD.id AND NEW.state='revoked'
 AND NEW.identity_public_key='deleted:'||OLD.id AND NEW.created_at=OLD.created_at))
 OR (OLD.identity_public_key='deleted:'||OLD.id AND (NEW.id<>OLD.id OR NEW.state<>'revoked'))
BEGIN SELECT RAISE(ABORT,'group_person_identity_immutable'); END;

-- A later membership/window close may run a normal 24-hour report-only grant
-- trigger. Preserve normal revocations while preventing grants to erased keys.
CREATE TRIGGER group_erased_device_no_report_grant BEFORE INSERT ON group_report_access
WHEN EXISTS(SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
 WHERE d.id=NEW.device_id AND (p.identity_public_key='deleted:'||p.id OR d.signing_public_key='deleted:'||d.id))
BEGIN SELECT RAISE(IGNORE); END;

-- Preserve only the already-authorized dissolution deadline when a deletion
-- removes its actor's audit receipt. This never invents a new dissolution.
CREATE TABLE group_erased_family_dissolutions (
 family_id TEXT PRIMARY KEY REFERENCES family_notebook_spaces(id),
 generation INTEGER NOT NULL CHECK(generation>0), closed_at INTEGER NOT NULL CHECK(closed_at>0)
) STRICT;
CREATE TRIGGER group_erased_family_dissolution_guard BEFORE INSERT ON group_erased_family_dissolutions BEGIN
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_governance_events e
  JOIN family_notebook_spaces f ON f.id=e.family_id JOIN group_identity_erasure_commands c ON c.person_id=e.actor_person_id
  WHERE e.family_id=NEW.family_id AND e.action='dissolve' AND f.state='closed' AND f.generation=NEW.generation
   AND e.resulting_generation=NEW.generation AND e.recorded_at=NEW.closed_at)
  THEN RAISE(ABORT,'family_erasure_deadline_invalid') END);
END;
CREATE TRIGGER group_erased_family_dissolution_immutable BEFORE UPDATE ON group_erased_family_dissolutions
BEGIN SELECT RAISE(ABORT,'family_erasure_deadline_immutable'); END;
CREATE TRIGGER group_erased_family_dissolution_retained BEFORE DELETE ON group_erased_family_dissolutions
WHEN EXISTS(SELECT 1 FROM family_notebook_crypto_rosters WHERE family_id=OLD.family_id)
 OR EXISTS(SELECT 1 FROM family_notebook_crypto_devices WHERE family_id=OLD.family_id)
BEGIN SELECT RAISE(ABORT,'family_erasure_deadline_retained'); END;

DROP TRIGGER family_notebook_member_exit_guard;
CREATE TRIGGER family_notebook_member_exit_guard BEFORE UPDATE ON family_notebook_members
WHEN NOT EXISTS(
  SELECT 1 FROM family_notebook_payer_events e WHERE e.family_id=OLD.family_id AND e.actor_person_id=OLD.person_id
    AND e.operation='leave' AND OLD.state='active' AND NEW.state='left'
    AND NEW.family_id=OLD.family_id AND NEW.person_id=OLD.person_id
    AND NEW.admitted_generation=OLD.admitted_generation AND NEW.left_generation=e.resulting_generation
    AND e.expected_generation=(SELECT generation FROM family_notebook_spaces WHERE id=OLD.family_id)
) AND NOT EXISTS(
  SELECT 1 FROM family_notebook_admission_events e JOIN family_notebook_join_requests j ON j.id=e.join_id
  WHERE e.family_id=OLD.family_id AND e.operation='approve' AND j.person_id=OLD.person_id AND j.state='pending'
    AND OLD.state<>'active' AND NEW.state='active' AND NEW.left_generation IS NULL
    AND NEW.family_id=OLD.family_id AND NEW.person_id=OLD.person_id AND NEW.admitted_generation=e.resulting_generation
    AND e.expected_generation=(SELECT generation FROM family_notebook_spaces WHERE id=OLD.family_id)
) AND NOT EXISTS(
  SELECT 1 FROM family_notebook_governance_events e WHERE e.family_id=OLD.family_id
    AND (e.action='dissolve' OR (e.action='remove' AND e.target_person_id=OLD.person_id))
    AND OLD.state='active' AND NEW.state='removed' AND NEW.family_id=OLD.family_id AND NEW.person_id=OLD.person_id
    AND NEW.admitted_generation=OLD.admitted_generation AND NEW.left_generation=e.resulting_generation
    AND e.expected_generation=(SELECT generation FROM family_notebook_spaces WHERE id=OLD.family_id)
)
AND NOT EXISTS(SELECT 1 FROM group_identity_erasure_commands c JOIN family_notebook_spaces f ON f.id=OLD.family_id
 WHERE c.person_id=OLD.person_id AND f.state='active' AND OLD.state='active' AND NEW.state='left'
 AND NEW.family_id=OLD.family_id AND NEW.person_id=OLD.person_id AND NEW.admitted_generation=OLD.admitted_generation
 AND NEW.left_generation=f.generation+1)
BEGIN SELECT RAISE(ABORT,'family_notebook_membership_audit_required'); END;

DROP TRIGGER family_notebook_payer_state_guard;
CREATE TRIGGER family_notebook_payer_state_guard BEFORE UPDATE ON family_notebook_spaces
WHEN NOT EXISTS(
  SELECT 1 FROM family_notebook_payer_events e
  WHERE e.family_id=OLD.id AND e.expected_generation=OLD.generation AND e.resulting_generation=NEW.generation
    AND NEW.id=OLD.id AND NEW.state=OLD.state AND NEW.created_at=OLD.created_at AND NEW.updated_at=e.recorded_at
    AND NEW.nominated_person_id IS (CASE WHEN e.operation='leave' AND OLD.nominated_person_id=e.actor_person_id THEN NULL ELSE OLD.nominated_person_id END)
    AND NEW.payer_person_id IS (CASE WHEN e.operation='claim' THEN e.actor_person_id WHEN OLD.payer_person_id=e.actor_person_id THEN NULL ELSE OLD.payer_person_id END)
    AND NEW.payer_absent_since_generation IS (CASE WHEN e.operation='claim' THEN NULL WHEN OLD.payer_person_id=e.actor_person_id THEN e.resulting_generation ELSE OLD.payer_absent_since_generation END)
) AND NOT EXISTS(
  SELECT 1 FROM family_notebook_admission_events e WHERE e.family_id=OLD.id AND e.operation='approve'
    AND e.expected_generation=OLD.generation AND e.resulting_generation=NEW.generation AND NEW.updated_at=e.recorded_at
    AND NEW.id=OLD.id AND NEW.state=OLD.state AND NEW.created_at=OLD.created_at
    AND NEW.nominated_person_id IS OLD.nominated_person_id AND NEW.payer_person_id IS OLD.payer_person_id
    AND NEW.payer_absent_since_generation IS OLD.payer_absent_since_generation
) AND NOT EXISTS(
  SELECT 1 FROM family_notebook_governance_events e WHERE e.family_id=OLD.id
    AND e.expected_generation=OLD.generation AND e.resulting_generation=NEW.generation AND NEW.updated_at=e.recorded_at
    AND NEW.id=OLD.id AND NEW.created_at=OLD.created_at
    AND NEW.state=(CASE WHEN e.action='dissolve' THEN 'closed' ELSE OLD.state END)
    AND NEW.payer_person_id IS (CASE WHEN e.action='dissolve' THEN NULL WHEN e.action='accept' THEN e.actor_person_id ELSE OLD.payer_person_id END)
    AND NEW.payer_absent_since_generation IS (CASE WHEN e.action='dissolve' THEN e.resulting_generation WHEN e.action='accept' THEN NULL ELSE OLD.payer_absent_since_generation END)
    AND NEW.nominated_person_id IS (CASE WHEN e.action='nominate' THEN e.target_person_id
      WHEN e.action IN ('accept','cancel','dissolve') OR (e.action='remove' AND OLD.nominated_person_id=e.target_person_id) THEN NULL ELSE OLD.nominated_person_id END)
)
AND NOT EXISTS(SELECT 1 FROM group_identity_erasure_commands c JOIN family_notebook_members m ON m.person_id=c.person_id
 WHERE m.family_id=OLD.id AND m.state='left' AND m.left_generation=OLD.generation+1 AND OLD.state='active'
 AND NEW.state=OLD.state AND NEW.id=OLD.id AND NEW.created_at=OLD.created_at AND NEW.generation=OLD.generation+1
 AND NEW.updated_at=MAX(OLD.updated_at,c.accepted_at)
 AND NEW.payer_person_id IS (CASE WHEN OLD.payer_person_id=c.person_id THEN NULL ELSE OLD.payer_person_id END)
 AND NEW.payer_absent_since_generation IS (CASE WHEN OLD.payer_person_id=c.person_id THEN NEW.generation ELSE OLD.payer_absent_since_generation END)
 AND NEW.nominated_person_id IS (CASE WHEN OLD.nominated_person_id=c.person_id THEN NULL ELSE OLD.nominated_person_id END))
BEGIN SELECT RAISE(ABORT,'family_notebook_payer_audit_required'); END;

DROP TRIGGER family_notebook_members_retained;
CREATE TRIGGER family_notebook_members_retained BEFORE DELETE ON family_notebook_members
WHEN NOT EXISTS(SELECT 1 FROM group_identity_erasure_commands c WHERE c.person_id=OLD.person_id AND OLD.state<>'active')
BEGIN SELECT RAISE(ABORT,'family_notebook_members_retained'); END;

DROP TRIGGER family_notebook_events_retained;
CREATE TRIGGER family_notebook_events_retained BEFORE DELETE ON family_notebook_payer_events
WHEN NOT EXISTS(SELECT 1 FROM group_identity_erasure_commands c WHERE c.person_id=OLD.actor_person_id)
BEGIN SELECT RAISE(ABORT,'family_notebook_event_retained'); END;

DROP TRIGGER family_notebook_admission_events_retained;
CREATE TRIGGER family_notebook_admission_events_retained BEFORE DELETE ON family_notebook_admission_events
WHEN NOT EXISTS(SELECT 1 FROM group_identity_erasure_commands c WHERE c.person_id=OLD.actor_person_id)
BEGIN SELECT RAISE(ABORT,'family_notebook_event_retained'); END;

DROP TRIGGER family_notebook_governance_retained;
CREATE TRIGGER family_notebook_governance_retained BEFORE DELETE ON family_notebook_governance_events
WHEN NOT EXISTS(SELECT 1 FROM group_identity_erasure_commands c WHERE c.person_id=OLD.actor_person_id AND (OLD.action<>'dissolve' OR EXISTS(SELECT 1 FROM group_erased_family_dissolutions x WHERE x.family_id=OLD.family_id AND x.generation=OLD.resulting_generation AND x.closed_at=OLD.recorded_at)))
BEGIN SELECT RAISE(ABORT,'family_notebook_event_retained'); END;
-- An anonymized invitation can outlive its creator only while another
-- person's join row still needs its FK. Remove it with the last such row.
CREATE TRIGGER group_erased_invitation_unref AFTER DELETE ON group_join_requests
BEGIN
 DELETE FROM group_invitations WHERE id=OLD.invitation_id AND revoked_at IS NOT NULL AND proof_public_key='deleted:'||id
  AND NOT EXISTS(SELECT 1 FROM group_join_requests WHERE invitation_id=OLD.invitation_id)
  AND NOT EXISTS(SELECT 1 FROM group_challenges WHERE invitation_id=OLD.invitation_id);
END;
CREATE TRIGGER family_erased_invitation_unref AFTER DELETE ON family_notebook_join_requests
BEGIN
 DELETE FROM family_notebook_invitations WHERE id=OLD.invitation_id AND state='revoked' AND proof_public_key='deleted:'||id
  AND NOT EXISTS(SELECT 1 FROM family_notebook_join_requests WHERE invitation_id=OLD.invitation_id);
END;
