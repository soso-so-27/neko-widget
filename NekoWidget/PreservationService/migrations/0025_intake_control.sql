-- Operational intake limits, NOT a monetary billing cap. Existing records,
-- read/export/edit/delete and recovery are independent of this singleton.
CREATE TABLE pa_intake_control (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
  reviewed_at INTEGER NOT NULL DEFAULT 0 CHECK(reviewed_at>=0),
  valid_until INTEGER NOT NULL DEFAULT 0 CHECK(valid_until>=reviewed_at),
  daily_attempt_limit INTEGER NOT NULL DEFAULT 0 CHECK(daily_attempt_limit BETWEEN 0 AND 1000000),
  monthly_attempt_limit INTEGER NOT NULL DEFAULT 0 CHECK(monthly_attempt_limit BETWEEN 0 AND 1000000),
  monthly_bytes_limit INTEGER NOT NULL DEFAULT 0 CHECK(monthly_bytes_limit BETWEEN 0 AND 1099511627776),
  day TEXT NOT NULL DEFAULT '1970-01-01',
  month TEXT NOT NULL DEFAULT '1970-01',
  daily_attempts INTEGER NOT NULL DEFAULT 0 CHECK(daily_attempts>=0),
  monthly_attempts INTEGER NOT NULL DEFAULT 0 CHECK(monthly_attempts>=0),
  monthly_bytes INTEGER NOT NULL DEFAULT 0 CHECK(monthly_bytes>=0)
);
INSERT INTO pa_intake_control(singleton) VALUES(1);
