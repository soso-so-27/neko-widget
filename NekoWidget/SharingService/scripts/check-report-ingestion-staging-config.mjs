import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { validateStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");
const offPath = join(projectDirectory, "wrangler.staging.jsonc");
const reportPath = join(projectDirectory, "wrangler.report-ingestion-staging-on.jsonc");

try {
  const offConfig = JSON.parse(await readFile(offPath, "utf8"));
  const reportConfig = JSON.parse(await readFile(reportPath, "utf8"));
  validateStagingConfig(offConfig);
  validateStagingConfig(reportConfig, {
    expectedReportIngestionRuntime: "YES",
  });

  const normalizedReport = structuredClone(reportConfig);
  normalizedReport.vars.REPORT_INGESTION_RUNTIME_ENABLED = "NO";
  if (JSON.stringify(normalizedReport) !== JSON.stringify(offConfig)) {
    throw new Error("Report-ingestion ON/OFF configs may differ only by its reviewed runtime flag.");
  }
  console.log("report-ingestion staging config preflight: PASS (one exact ON/OFF flag difference)");
  console.log("private media, APNs, and legacy sharing remain OFF; no deployment was performed");
} catch (error) {
  console.error(
    `report-ingestion staging config preflight: FAIL: ${error instanceof Error ? error.message : "unknown error"}`,
  );
  process.exitCode = 1;
}
