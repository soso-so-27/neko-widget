import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { validateStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");
const offPath = join(projectDirectory, "wrangler.staging.jsonc");
const onPath = join(projectDirectory, "wrangler.media-staging-on.jsonc");

try {
  const offConfig = JSON.parse(await readFile(offPath, "utf8"));
  const onConfig = JSON.parse(await readFile(onPath, "utf8"));
  validateStagingConfig(offConfig);
  validateStagingConfig(onConfig, { expectedMomentRuntime: "YES" });

  const normalizedOn = structuredClone(onConfig);
  normalizedOn.vars.MOMENT_RUNTIME_ENABLED = "NO";
  normalizedOn.vars.REACTION_RUNTIME_ENABLED = "NO";
  normalizedOn.vars.WINDOW_NAME_RUNTIME_ENABLED = "NO";
  if (JSON.stringify(normalizedOn) !== JSON.stringify(offConfig)) {
    throw new Error(
      "The reviewed ON and OFF configs must differ only by the three private media runtime flags.",
    );
  }

  console.log("media staging config preflight: PASS (three exact ON/OFF flag differences)");
  console.log("legacy sharing remains OFF; no Cloudflare deployment was performed");
} catch (error) {
  console.error(
    `media staging config preflight: FAIL: ${error instanceof Error ? error.message : "unknown error"}`,
  );
  process.exitCode = 1;
}
