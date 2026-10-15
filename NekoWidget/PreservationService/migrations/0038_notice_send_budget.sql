-- Account-wide operational control, not an owner record or deletion permission.
CREATE TABLE pa_notice_send_budget (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  day_utc INTEGER NOT NULL CHECK (day_utc >= 0),
  reserved_sends INTEGER NOT NULL CHECK (reserved_sends BETWEEN 0 AND 50),
  month_utc INTEGER NOT NULL CHECK (month_utc >= 0),
  month_reserved_sends INTEGER NOT NULL CHECK (month_reserved_sends BETWEEN 0 AND 1500),
  last_attempt_at INTEGER NOT NULL CHECK (last_attempt_at >= 0),
  last_run_started_at INTEGER NOT NULL DEFAULT 0 CHECK (last_run_started_at >= 0),
  last_run_finished_at INTEGER NOT NULL DEFAULT 0 CHECK (last_run_finished_at >= 0),
  last_run_error_code TEXT CHECK (last_run_error_code IS NULL OR length(last_run_error_code) BETWEEN 1 AND 64)
);
INSERT INTO pa_notice_send_budget(singleton,day_utc,reserved_sends,month_utc,month_reserved_sends,last_attempt_at)
  VALUES(1,0,0,0,0,0);
