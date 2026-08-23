import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { validateStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");
const configPath = join(projectDirectory, "wrangler.staging.jsonc");

try {
  const config = JSON.parse(await readFile(configPath, "utf8"));
  validateStagingConfig(config);
  console.log("staging config preflight: PASS (isolated workers.dev resources; moment/window-name/legacy runtimes OFF)");
} catch (error) {
  console.error(`staging config preflight: FAIL: ${error instanceof Error ? error.message : "unknown error"}`);
  process.exitCode = 1;
}
