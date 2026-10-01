-- Preparation only: no review renewal, intake activation, or pilot change.
-- An absent forecast or stop point keeps explicit general admission closed.
ALTER TABLE pa_intake_control ADD COLUMN forecast_yen INTEGER
  CHECK(forecast_yen IS NULL OR forecast_yen BETWEEN 0 AND 1000000000);
ALTER TABLE pa_intake_control ADD COLUMN pause_forecast_yen INTEGER NOT NULL DEFAULT 0
  CHECK(pause_forecast_yen BETWEEN 0 AND 1000000000);
