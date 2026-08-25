import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { renderStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");
const templatePath = join(projectDirectory, "wrangler.staging.template.jsonc");
const outputPath = join(projectDirectory, "wrangler.staging.jsonc");

try {
  const template = await readFile(templatePath, "utf8");
  const rendered = renderStagingConfig(template, process.env);
  await writeFile(outputPath, rendered, { encoding: "utf8", flag: "wx", mode: 0o600 });
  console.log("Created ignored wrangler.staging.jsonc with moment, reaction, window-name, and legacy runtimes locked OFF.");
  console.log("No Cloudflare resource identifier was printed.");
} catch (error) {
  console.error(`staging config render: FAIL: ${error instanceof Error ? error.message : "unknown error"}`);
  process.exitCode = 1;
}
