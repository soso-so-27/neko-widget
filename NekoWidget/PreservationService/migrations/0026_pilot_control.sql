-- Private seven-day pilot only. No identities, photo content or credentials.
CREATE TABLE pa_pilot_control (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
  starts_at INTEGER NOT NULL DEFAULT 0 CHECK(starts_at>=0),
  ends_at INTEGER NOT NULL DEFAULT 0 CHECK(ends_at>=starts_at AND ends_at<=starts_at+604800000),
  reviewed_at INTEGER NOT NULL DEFAULT 0 CHECK(reviewed_at>=0),
  valid_until INTEGER NOT NULL DEFAULT 0 CHECK(valid_until>=reviewed_at AND valid_until<=reviewed_at+86400000),
  forecast_yen INTEGER NOT NULL DEFAULT 3000 CHECK(forecast_yen>=0),
  day TEXT NOT NULL DEFAULT '1970-01-01',
  month TEXT NOT NULL DEFAULT '1970-01',
  daily_mutations INTEGER NOT NULL DEFAULT 0 CHECK(daily_mutations>=0),
  monthly_mutations INTEGER NOT NULL DEFAULT 0 CHECK(monthly_mutations>=0)
);
INSERT INTO pa_pilot_control(singleton) VALUES(1);
