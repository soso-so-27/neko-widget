import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { validateDisabledModerationOperatorConfig } from "./moderation-operator-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");
const configPath = join(
  projectDirectory,
  "wrangler.moderation-operator.disabled.jsonc",
);

const config = JSON.parse(await readFile(configPath, "utf8"));
validateDisabledModerationOperatorConfig(config);
console.log("Disabled moderation operator configuration is valid; no public route or resource binding is configured.");
