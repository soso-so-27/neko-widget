PRAGMA foreign_keys = ON;

-- Family notebooks are independent from photo-window ownership and signed
-- rosters. No existing member, payer, entitlement, key or content is changed.
-- There is deliberately no production admission writer or public route yet.
-- Only authenticated admission may eventually create these family/member rows;
-- the current integration fixture is synthetic and is not an admission API.
CREATE TABLE family_notebook_runtime_gate (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
  generation INTEGER NOT NULL DEFAULT 0 CHECK(generation>=0)
) STRICT;
INSERT INTO family_notebook_runtime_gate(singleton) VALUES(1);

CREATE TABLE family_notebook_spaces (
  id TEXT PRIMARY KEY,
  generation INTEGER NOT NULL CHECK(generation>0),
  state TEXT NOT NULL CHECK(state IN ('active','closed')),
  payer_person_id TEXT REFERENCES group_people(id),
  payer_absent_since_generation INTEGER CHECK(payer_absent_since_generation>0),
  -- Reserved for the separate explicit nomination path. This batch neither
  -- creates, clears nor accepts nominations, including when the payer leaves.
  nominated_person_id TEXT REFERENCES group_people(id),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK((payer_person_id IS NULL AND payer_absent_since_generation IS NOT NULL)
     OR (payer_person_id IS NOT NULL AND payer_absent_since_generation IS NULL))
) STRICT;
CREATE TABLE family_notebook_members (
  family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
  person_id TEXT NOT NULL REFERENCES group_people(id),
  state TEXT NOT NULL CHECK(state IN ('active','left','removed')),
  admitted_generation INTEGER NOT NULL CHECK(admitted_generation>0),
  left_generation INTEGER CHECK(left_generation>0),
  PRIMARY KEY(family_id,person_id),
  CHECK((state='active' AND left_generation IS NULL)
     OR (state<>'active' AND left_generation IS NOT NULL))
) STRICT;

CREATE TABLE family_notebook_payer_events (
  actor_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  operation_id TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  actor_person_id TEXT NOT NULL REFERENCES group_people(id),
  family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
  operation TEXT NOT NULL CHECK(operation IN ('leave','claim')),
  expected_generation INTEGER NOT NULL CHECK(expected_generation>0),
  resulting_generation INTEGER NOT NULL CHECK(resulting_generation=expected_generation+1),
  store_environment TEXT CHECK(store_environment IN ('Production','Sandbox')),
  recorded_at INTEGER NOT NULL DEFAULT(unixepoch()),
  PRIMARY KEY(actor_device_id,operation_id)
) STRICT;

CREATE TRIGGER family_notebook_payer_event_validate BEFORE INSERT ON family_notebook_payer_events
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NEW.recorded_at<>unixepoch()
    THEN RAISE(ABORT,'family_notebook_invalid_time') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.actor_device_id AND d.person_id=NEW.actor_person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE f.id=NEW.family_id AND f.state='active' AND m.person_id=NEW.actor_person_id AND m.state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN (SELECT generation FROM family_notebook_spaces WHERE id=NEW.family_id)<>NEW.expected_generation
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.operation='claim' AND NOT EXISTS(
    SELECT 1 FROM family_notebook_spaces f JOIN family_notebook_members m ON m.family_id=f.id
    WHERE f.id=NEW.family_id AND f.payer_person_id IS NULL AND f.nominated_person_id IS NULL
      AND m.person_id=NEW.actor_person_id AND m.state='active'
      AND m.admitted_generation<=f.payer_absent_since_generation)
    THEN RAISE(ABORT,'family_notebook_claim_unavailable') END);
  -- The verified authority view rechecks revocation, expiry, grace, current
  -- environment and lower billing gate at COMMIT time. Neither a local Plus
  -- boolean nor a billing connection alone is evidence of paid membership.
  SELECT (CASE WHEN NEW.operation='claim' AND NOT EXISTS(
    SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.actor_person_id AND environment=NEW.store_environment)
    THEN RAISE(ABORT,'family_notebook_plus_required') END);
END;

CREATE TRIGGER family_notebook_payer_event_apply AFTER INSERT ON family_notebook_payer_events
BEGIN
  UPDATE family_notebook_members SET state='left',left_generation=NEW.resulting_generation
    WHERE NEW.operation='leave' AND family_id=NEW.family_id AND person_id=NEW.actor_person_id;
  UPDATE family_notebook_spaces SET generation=NEW.resulting_generation,
    payer_person_id=(CASE WHEN NEW.operation='claim' THEN NEW.actor_person_id
      WHEN payer_person_id=NEW.actor_person_id THEN NULL ELSE payer_person_id END),
    payer_absent_since_generation=(CASE WHEN NEW.operation='claim' THEN NULL
      WHEN payer_person_id=NEW.actor_person_id THEN NEW.resulting_generation ELSE payer_absent_since_generation END),
    updated_at=NEW.recorded_at
    WHERE id=NEW.family_id;
END;

-- Current payer state cannot be overwritten without the exact successful CAS
-- event. Future admission/nomination needs its own audited transition; it must
-- not mutate this state through an unauthenticated shortcut.
CREATE TRIGGER family_notebook_payer_state_guard BEFORE UPDATE ON family_notebook_spaces
WHEN NOT EXISTS(
  SELECT 1 FROM family_notebook_payer_events e
  WHERE e.family_id=OLD.id AND e.expected_generation=OLD.generation AND e.resulting_generation=NEW.generation
    AND NEW.id=OLD.id AND NEW.state=OLD.state AND NEW.created_at=OLD.created_at
    AND NEW.nominated_person_id IS OLD.nominated_person_id AND NEW.updated_at=e.recorded_at
    AND NEW.payer_person_id IS (CASE WHEN e.operation='claim' THEN e.actor_person_id
      WHEN OLD.payer_person_id=e.actor_person_id THEN NULL ELSE OLD.payer_person_id END)
    AND NEW.payer_absent_since_generation IS (CASE WHEN e.operation='claim' THEN NULL
      WHEN OLD.payer_person_id=e.actor_person_id THEN e.resulting_generation ELSE OLD.payer_absent_since_generation END)
)
BEGIN SELECT RAISE(ABORT,'family_notebook_payer_audit_required'); END;
CREATE TRIGGER family_notebook_member_exit_guard BEFORE UPDATE ON family_notebook_members
WHEN NOT EXISTS(
  SELECT 1 FROM family_notebook_payer_events e WHERE e.family_id=OLD.family_id AND e.actor_person_id=OLD.person_id
    AND e.operation='leave' AND OLD.state='active' AND NEW.state='left'
    AND NEW.family_id=OLD.family_id AND NEW.person_id=OLD.person_id
    AND NEW.admitted_generation=OLD.admitted_generation AND NEW.left_generation=e.resulting_generation
    AND e.expected_generation=(SELECT generation FROM family_notebook_spaces WHERE id=OLD.family_id)
)
BEGIN SELECT RAISE(ABORT,'family_notebook_membership_audit_required'); END;
CREATE TRIGGER family_notebook_events_immutable BEFORE UPDATE ON family_notebook_payer_events
BEGIN SELECT RAISE(ABORT,'family_notebook_event_immutable'); END;
CREATE TRIGGER family_notebook_events_retained BEFORE DELETE ON family_notebook_payer_events
BEGIN SELECT RAISE(ABORT,'family_notebook_event_retained'); END;
CREATE TRIGGER family_notebook_spaces_retained BEFORE DELETE ON family_notebook_spaces
BEGIN SELECT RAISE(ABORT,'family_notebook_records_retained'); END;
CREATE TRIGGER family_notebook_members_retained BEFORE DELETE ON family_notebook_members
BEGIN SELECT RAISE(ABORT,'family_notebook_members_retained'); END;

CREATE TABLE family_notebook_access_checks (
  id TEXT PRIMARY KEY,family_id TEXT NOT NULL,person_id TEXT NOT NULL,device_id TEXT NOT NULL,
  expected_generation INTEGER NOT NULL
) STRICT;
CREATE TRIGGER family_notebook_access_check BEFORE INSERT ON family_notebook_access_checks
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NOT EXISTS(
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    JOIN group_people p ON p.id=m.person_id JOIN group_person_devices d ON d.person_id=p.id
    WHERE f.id=NEW.family_id AND f.state='active' AND m.person_id=NEW.person_id AND m.state='active'
      AND p.state='active' AND d.id=NEW.device_id AND d.state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN (SELECT generation FROM family_notebook_spaces WHERE id=NEW.family_id)<>NEW.expected_generation
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
END;
