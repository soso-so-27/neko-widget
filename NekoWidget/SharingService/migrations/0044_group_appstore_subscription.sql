PRAGMA foreign_keys = ON;

-- 1020f supersedes the window-created +14 day allowance. Do not rewrite old
-- migration history or alter any room/photo/member/heart/billing record.
DROP VIEW group_window_owner_policy;
CREATE VIEW group_window_owner_policy AS
-- NULL keeps older Worker reads compatible during code rollback, while never
-- supplying the removed room-age allowance. New API omits this old field.
SELECT w.space_id,w.owner_person_id,NULL AS trial_ends_at,
    (SELECT participant_id FROM group_members m WHERE m.space_id=w.space_id AND m.role='owner') AS owner_participant_id
FROM group_windows w;

DROP TRIGGER group_creation_policy;
CREATE TRIGGER group_creation_policy BEFORE INSERT ON group_creation_policy_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_windows WHERE space_id=NEW.space_id AND owner_person_id=NEW.owner_person_id)
        THEN RAISE(ABORT,'group_billing_connection_invalid') END);
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_members WHERE person_id=NEW.owner_person_id AND role='owner' AND state='active')>5
        THEN RAISE(ABORT,'group_owned_window_limit') END);
    SELECT (CASE WHEN NOT EXISTS (SELECT 1 FROM group_verified_plus_people WHERE person_id=NEW.owner_person_id AND environment=NEW.store_environment)
        THEN RAISE(ABORT,'group_owner_plus_required') END);
END;

DROP TRIGGER group_delivery_policy;
CREATE TRIGGER group_delivery_policy BEFORE INSERT ON group_delivery_policy_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_window_owner_policy w JOIN group_verified_plus_people p ON p.person_id=w.owner_person_id
        WHERE w.space_id=NEW.space_id AND p.environment=NEW.store_environment)
        THEN RAISE(ABORT,'group_window_paused') END);
END;
