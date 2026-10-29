PRAGMA foreign_keys = ON;

CREATE TABLE family_notebook_handover_current (
  family_id TEXT PRIMARY KEY REFERENCES family_notebook_spaces(id),
  nomination_id TEXT NOT NULL UNIQUE,
  nominee_person_id TEXT NOT NULL REFERENCES group_people(id),
  nominated_generation INTEGER NOT NULL CHECK(nominated_generation>0)
) STRICT;

CREATE TABLE family_notebook_governance_events (
  actor_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  operation_id TEXT NOT NULL,
  actor_person_id TEXT NOT NULL REFERENCES group_people(id),
  family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
  request_hash TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('remove','dissolve','nominate','accept','cancel')),
  target_person_id TEXT REFERENCES group_people(id),
  nomination_id TEXT,
  expected_generation INTEGER NOT NULL CHECK(expected_generation>0),
  resulting_generation INTEGER NOT NULL CHECK(resulting_generation=expected_generation+1),
  store_environment TEXT CHECK(store_environment IN ('Production','Sandbox')),
  recorded_at INTEGER NOT NULL DEFAULT(unixepoch()),
  PRIMARY KEY(actor_device_id,operation_id),
  CHECK((action='dissolve' AND target_person_id IS NULL AND nomination_id IS NULL)
    OR (action='remove' AND target_person_id IS NOT NULL AND nomination_id IS NULL)
    OR (action IN ('nominate','accept','cancel') AND target_person_id IS NOT NULL AND nomination_id IS NOT NULL))
) STRICT;

CREATE INDEX family_notebook_governance_generation ON family_notebook_governance_events(family_id,expected_generation);
CREATE INDEX family_notebook_payer_generation ON family_notebook_payer_events(family_id,expected_generation);
CREATE INDEX family_notebook_admission_generation ON family_notebook_admission_events(family_id,expected_generation);
CREATE INDEX family_notebook_member_person_state ON family_notebook_members(person_id,state,family_id);

CREATE TRIGGER family_notebook_governance_validate BEFORE INSERT ON family_notebook_governance_events
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NEW.recorded_at<>unixepoch() THEN RAISE(ABORT,'family_notebook_invalid_time') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.actor_device_id AND d.person_id=NEW.actor_person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE m.family_id=NEW.family_id AND m.person_id=NEW.actor_person_id AND m.state='active' AND f.state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN (SELECT generation FROM family_notebook_spaces WHERE id=NEW.family_id)<>NEW.expected_generation
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.action IN ('remove','dissolve','nominate') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces WHERE id=NEW.family_id AND payer_person_id=NEW.actor_person_id)
    THEN RAISE(ABORT,'family_notebook_not_allowed') END);
  SELECT (CASE WHEN NEW.action IN ('remove','nominate') AND (NEW.target_person_id=NEW.actor_person_id OR NOT EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN group_people p ON p.id=m.person_id
    WHERE m.family_id=NEW.family_id AND m.person_id=NEW.target_person_id AND m.state='active'
      AND (NEW.action='remove' OR p.state='active')))
    THEN RAISE(ABORT,'family_notebook_not_allowed') END);
  SELECT (CASE WHEN NEW.action='nominate' AND (
    NEW.nomination_id<>NEW.operation_id OR EXISTS(SELECT 1 FROM family_notebook_handover_current WHERE family_id=NEW.family_id)
    OR (SELECT nominated_person_id FROM family_notebook_spaces WHERE id=NEW.family_id) IS NOT NULL)
    THEN RAISE(ABORT,'family_notebook_nomination_changed') END);
  SELECT (CASE WHEN NEW.action IN ('accept','cancel') AND NOT EXISTS(
    SELECT 1 FROM family_notebook_handover_current h JOIN family_notebook_spaces f ON f.id=h.family_id
      JOIN family_notebook_members m ON m.family_id=h.family_id AND m.person_id=h.nominee_person_id
    WHERE h.family_id=NEW.family_id AND h.nomination_id=NEW.nomination_id AND h.nominee_person_id=NEW.target_person_id
      AND f.nominated_person_id=h.nominee_person_id AND m.state='active'
      AND ((NEW.action='accept' AND h.nominee_person_id=NEW.actor_person_id)
        OR (NEW.action='cancel' AND (f.payer_person_id=NEW.actor_person_id OR h.nominee_person_id=NEW.actor_person_id))))
    THEN RAISE(ABORT,'family_notebook_nomination_changed') END);
  SELECT (CASE WHEN NEW.action='accept' AND NOT EXISTS(
    SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.actor_person_id AND environment=NEW.store_environment)
    THEN RAISE(ABORT,'family_notebook_plus_required') END);
END;

CREATE TRIGGER family_notebook_governance_apply AFTER INSERT ON family_notebook_governance_events
BEGIN
  UPDATE family_notebook_members SET state='removed',left_generation=NEW.resulting_generation
    WHERE family_id=NEW.family_id AND state='active'
      AND (NEW.action='dissolve' OR (NEW.action='remove' AND person_id=NEW.target_person_id));
  UPDATE family_notebook_spaces SET generation=NEW.resulting_generation,updated_at=NEW.recorded_at,
    state=(CASE WHEN NEW.action='dissolve' THEN 'closed' ELSE state END),
    payer_person_id=(CASE WHEN NEW.action='dissolve' THEN NULL WHEN NEW.action='accept' THEN NEW.actor_person_id ELSE payer_person_id END),
    payer_absent_since_generation=(CASE WHEN NEW.action='dissolve' THEN NEW.resulting_generation WHEN NEW.action='accept' THEN NULL ELSE payer_absent_since_generation END),
    nominated_person_id=(CASE WHEN NEW.action='nominate' THEN NEW.target_person_id
      WHEN NEW.action IN ('accept','cancel','dissolve') OR (NEW.action='remove' AND nominated_person_id=NEW.target_person_id) THEN NULL ELSE nominated_person_id END)
    WHERE id=NEW.family_id;
  INSERT INTO family_notebook_handover_current
    SELECT NEW.family_id,NEW.nomination_id,NEW.target_person_id,NEW.resulting_generation WHERE NEW.action='nominate';
  DELETE FROM family_notebook_handover_current WHERE family_id=NEW.family_id
    AND (NEW.action IN ('accept','cancel','dissolve') OR (NEW.action='remove' AND nominee_person_id=NEW.target_person_id));
  UPDATE family_notebook_invitations SET state='revoked' WHERE family_id=NEW.family_id
    AND (NEW.action='dissolve' OR (NEW.action='remove' AND creator_person_id=NEW.target_person_id));
  UPDATE family_notebook_join_requests SET state='cancelled' WHERE family_id=NEW.family_id AND state='pending'
    AND (NEW.action='dissolve' OR (NEW.action='remove' AND (person_id=NEW.target_person_id OR invitation_id IN (
      SELECT id FROM family_notebook_invitations WHERE family_id=NEW.family_id AND creator_person_id=NEW.target_person_id))));
END;

-- Keep nominations when the PAYER leaves. Invalidate only a nomination whose
-- RECIPIENT leaves, so an absent recipient cannot block the vacant-payer path.
DROP TRIGGER family_notebook_payer_event_apply;
CREATE TRIGGER family_notebook_payer_event_apply AFTER INSERT ON family_notebook_payer_events
BEGIN
  UPDATE family_notebook_members SET state='left',left_generation=NEW.resulting_generation
    WHERE NEW.operation='leave' AND family_id=NEW.family_id AND person_id=NEW.actor_person_id;
  UPDATE family_notebook_spaces SET generation=NEW.resulting_generation,
    payer_person_id=(CASE WHEN NEW.operation='claim' THEN NEW.actor_person_id WHEN payer_person_id=NEW.actor_person_id THEN NULL ELSE payer_person_id END),
    payer_absent_since_generation=(CASE WHEN NEW.operation='claim' THEN NULL WHEN payer_person_id=NEW.actor_person_id THEN NEW.resulting_generation ELSE payer_absent_since_generation END),
    nominated_person_id=(CASE WHEN NEW.operation='leave' AND nominated_person_id=NEW.actor_person_id THEN NULL ELSE nominated_person_id END),
    updated_at=NEW.recorded_at WHERE id=NEW.family_id;
  DELETE FROM family_notebook_handover_current WHERE NEW.operation='leave' AND family_id=NEW.family_id AND nominee_person_id=NEW.actor_person_id;
END;

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
BEGIN SELECT RAISE(ABORT,'family_notebook_payer_audit_required'); END;

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
BEGIN SELECT RAISE(ABORT,'family_notebook_membership_audit_required'); END;

CREATE TRIGGER family_notebook_governance_immutable BEFORE UPDATE ON family_notebook_governance_events
BEGIN SELECT RAISE(ABORT,'family_notebook_event_immutable'); END;
CREATE TRIGGER family_notebook_governance_retained BEFORE DELETE ON family_notebook_governance_events
BEGIN SELECT RAISE(ABORT,'family_notebook_event_retained'); END;
