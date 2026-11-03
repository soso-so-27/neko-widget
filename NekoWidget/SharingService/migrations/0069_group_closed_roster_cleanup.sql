-- Signed roster bytes are never rewritten. Keep them while relay metadata
-- references them; normal photo/object/receipt deadlines remain unchanged.
CREATE VIEW group_closed_roster_cleanup_due AS
 SELECT w.space_id FROM group_windows w
 WHERE w.mode='closed'
 AND NOT EXISTS(SELECT 1 FROM group_moments m WHERE m.space_id=w.space_id)
 AND EXISTS(SELECT 1 FROM group_rosters r WHERE r.space_id=w.space_id);
