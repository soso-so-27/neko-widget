-- No admission changes. Operator activation and cron are separate approvals.
CREATE TABLE pa_intake_renewal (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN(0,1)),
 generation INTEGER NOT NULL DEFAULT 0 CHECK(generation>=0),
 approved_until INTEGER NOT NULL DEFAULT 0 CHECK(approved_until>=0),
 last_slot INTEGER NOT NULL DEFAULT -1,
 claim_id TEXT NOT NULL DEFAULT '',
 lease_until INTEGER NOT NULL DEFAULT 0,
 last_result TEXT NOT NULL DEFAULT 'disabled',
 checked_at INTEGER NOT NULL DEFAULT 0,
 forecast_yen INTEGER,
 warning INTEGER NOT NULL DEFAULT 0 CHECK(warning IN(0,1))
);
INSERT INTO pa_intake_renewal(singleton) VALUES(1);
