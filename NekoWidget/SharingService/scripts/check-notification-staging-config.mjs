import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { validateStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");
const offPath = join(projectDirectory, "wrangler.staging.jsonc");
const onPath = join(projectDirectory, "wrangler.notification-staging-on.jsonc");

try {
  const offConfig = JSON.parse(await readFile(offPath, "utf8"));
  const onConfig = JSON.parse(await readFile(onPath, "utf8"));
  validateStagingConfig(offConfig);
  validateStagingConfig(onConfig, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
  });

  const normalizedOn = structuredClone(onConfig);
  normalizedOn.vars.MOMENT_RUNTIME_ENABLED = "NO";
  normalizedOn.vars.REACTION_RUNTIME_ENABLED = "NO";
  normalizedOn.vars.WINDOW_NAME_RUNTIME_ENABLED = "NO";
  normalizedOn.vars.APNS_RUNTIME_ENABLED = "NO";
  if (JSON.stringify(normalizedOn) !== JSON.stringify(offConfig)) {
    throw new Error("Notification ON/OFF configs may differ only by four reviewed runtime flags.");
  }
  console.log("notification staging config preflight: PASS (four exact ON/OFF flag differences)");
  console.log("APNs secrets are intentionally not inspected or printed; no deployment was performed");
} catch (error) {
  console.error(
    `notification staging config preflight: FAIL: ${error instanceof Error ? error.message : "unknown error"}`,
  );
  process.exitCode = 1;
}
