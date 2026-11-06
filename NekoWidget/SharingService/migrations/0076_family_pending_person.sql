-- Reject a second live application atomically, including another device/link.
-- Historical requests and their encrypted names remain unchanged.
CREATE TRIGGER family_notebook_one_pending_person
BEFORE INSERT ON family_notebook_admission_events
WHEN NEW.operation='join'
BEGIN
  SELECT (CASE WHEN EXISTS (
    SELECT 1 FROM family_notebook_join_requests j
    JOIN family_notebook_spaces f ON f.id=j.family_id AND f.state='active'
    WHERE j.family_id=NEW.family_id AND j.person_id=NEW.actor_person_id AND j.state='pending' AND j.expires_at>unixepoch()
  ) THEN RAISE(ABORT,'family_notebook_request_already_pending') END);
END;
