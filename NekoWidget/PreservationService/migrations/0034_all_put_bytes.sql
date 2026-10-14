-- All admitted general PUT input, including edits and failed attempts. This is
-- not physical S3/R2 inventory or a monetary cap. Existing new-record counters
-- retain their meaning. Explicit byte review is required before general writes.
ALTER TABLE pa_intake_control ADD COLUMN monthly_mutation_bytes_limit INTEGER NOT NULL DEFAULT 0
  CHECK(monthly_mutation_bytes_limit BETWEEN 0 AND 1099511627776);
ALTER TABLE pa_intake_control ADD COLUMN monthly_mutation_bytes INTEGER NOT NULL DEFAULT 0
  CHECK(monthly_mutation_bytes>=0);
