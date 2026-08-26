import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { validateSelectiveOffConfigs } from "./selective-staging-off-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");

async function readConfig(name) {
  return JSON.parse(await readFile(join(projectDirectory, name), "utf8"));
}

try {
  const general = await readConfig("wrangler.general-staging-on.jsonc");
  const apnsOff = await readConfig("wrangler.general-staging-apns-off.jsonc");
  const reportOff = await readConfig("wrangler.notification-staging-on.jsonc");
  const mediaOff = await readConfig("wrangler.report-ingestion-staging-on.jsonc");
  validateSelectiveOffConfigs("apns", general, apnsOff);
  validateSelectiveOffConfigs("report-ingestion", general, reportOff);
  validateSelectiveOffConfigs("media", general, mediaOff);
  console.log("selective staging OFF config preflight: PASS (three exact reviewed transitions)");
  console.log("No deployment, migration, secret change, or Cloudflare write was performed");
} catch (error) {
  console.error(
    `selective staging OFF config preflight: FAIL: ${error instanceof Error ? error.message : "unknown error"}`,
  );
  process.exitCode = 1;
}
