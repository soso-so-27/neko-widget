import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  validateBillingControlStagingPair,
} from "./billing-control-staging-config-lib.mjs";

const projectDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const offPath = join(
  projectDirectory,
  "wrangler.billing-control-staging-off.jsonc",
);
const onPath = join(
  projectDirectory,
  "wrangler.billing-control-staging-on.jsonc",
);

try {
  const offConfig = JSON.parse(await readFile(offPath, "utf8"));
  const onConfig = JSON.parse(await readFile(onPath, "utf8"));
  validateBillingControlStagingPair(offConfig, onConfig);
  console.log("billing control staging config: PASS (seven exact OFF/ON differences)");
  console.log("No secret was inspected or printed; no deployment was performed.");
} catch (error) {
  console.error(
    `billing control staging config: FAIL: ${
      error instanceof Error ? error.message : "unknown error"
    }`,
  );
  process.exitCode = 1;
}
