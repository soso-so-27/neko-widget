-- General service admission is separate from the finite internal pilot.
-- Zero defaults keep new registration and PUTs closed until an operator sets
-- explicit limits using current usage/cost evidence. Reads/exports are unchanged.
ALTER TABLE pa_intake_control ADD COLUMN maximum_owners INTEGER NOT NULL DEFAULT 0 CHECK(maximum_owners>=0);
ALTER TABLE pa_intake_control ADD COLUMN daily_registration_limit INTEGER NOT NULL DEFAULT 0 CHECK(daily_registration_limit>=0);
ALTER TABLE pa_intake_control ADD COLUMN registration_day TEXT NOT NULL DEFAULT '1970-01-01';
ALTER TABLE pa_intake_control ADD COLUMN daily_registrations INTEGER NOT NULL DEFAULT 0 CHECK(daily_registrations>=0);
ALTER TABLE pa_intake_control ADD COLUMN daily_mutation_limit INTEGER NOT NULL DEFAULT 0 CHECK(daily_mutation_limit>=0);
ALTER TABLE pa_intake_control ADD COLUMN monthly_mutation_limit INTEGER NOT NULL DEFAULT 0 CHECK(monthly_mutation_limit>=0);
ALTER TABLE pa_intake_control ADD COLUMN mutation_day TEXT NOT NULL DEFAULT '1970-01-01';
ALTER TABLE pa_intake_control ADD COLUMN mutation_month TEXT NOT NULL DEFAULT '1970-01';
ALTER TABLE pa_intake_control ADD COLUMN daily_mutations INTEGER NOT NULL DEFAULT 0 CHECK(daily_mutations>=0);
ALTER TABLE pa_intake_control ADD COLUMN monthly_mutations INTEGER NOT NULL DEFAULT 0 CHECK(monthly_mutations>=0);
