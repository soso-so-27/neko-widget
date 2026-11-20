CREATE TABLE report_deadline_heartbeat (
 kind TEXT PRIMARY KEY CHECK(kind IN ('group','family')),
 completed_at INTEGER NOT NULL CHECK(completed_at>=0)
) STRICT;
