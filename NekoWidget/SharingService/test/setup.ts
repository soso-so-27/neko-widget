import { env } from "cloudflare:workers";
import { applyD1Migrations, type D1Migration } from "cloudflare:test";

interface TestEnv {
  DB: D1Database;
  TEST_MIGRATIONS: D1Migration[];
}

const testEnv = env as unknown as TestEnv;
await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);

// Production migration state is closed. The integration-test baseline opens
// all three personal-staging lower gates so existing feature tests continue to exercise their
// reviewed Wrangler-var upper bounds; gate-specific tests close them by CAS.
const opened = await testEnv.DB.prepare(
  `UPDATE personal_staging_runtime_gate
      SET generation = generation + 1,
          media_enabled = 1,
          apns_enabled = 1,
          report_ingestion_enabled = 1,
          updated_at = unixepoch()
    WHERE singleton = 1 AND generation = 0`,
).run();
if (opened.meta.changes !== 1) {
  throw new Error("integration runtime gate baseline could not be opened");
}
