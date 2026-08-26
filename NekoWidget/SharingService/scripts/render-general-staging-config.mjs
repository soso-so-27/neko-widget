import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { renderStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");
const templatePath = join(projectDirectory, "wrangler.staging.template.jsonc");
const outputPath = join(projectDirectory, "wrangler.general-staging-on.jsonc");

try {
  const template = await readFile(templatePath, "utf8");
  const rendered = renderStagingConfig(template, process.env, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
  });
  await writeFile(outputPath, rendered, { encoding: "utf8", flag: "wx", mode: 0o600 });
  console.log("Created ignored general staging config with media, APNs, and report ingestion ON.");
  console.log("APNs secrets remain separate; legacy sharing remains OFF; no deployment was performed.");
  console.log("No Cloudflare resource identifier or secret was printed.");
} catch (error) {
  console.error(
    `general staging config render: FAIL: ${error instanceof Error ? error.message : "unknown error"}`,
  );
  process.exitCode = 1;
}
