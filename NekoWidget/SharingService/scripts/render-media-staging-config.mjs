import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { renderStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");
const templatePath = join(projectDirectory, "wrangler.staging.template.jsonc");
const outputPath = join(projectDirectory, "wrangler.media-staging-on.jsonc");

try {
  const template = await readFile(templatePath, "utf8");
  const rendered = renderStagingConfig(template, process.env, {
    expectedMomentRuntime: "YES",
  });
  await writeFile(outputPath, rendered, { encoding: "utf8", flag: "wx", mode: 0o600 });
  console.log("Created ignored wrangler.media-staging-on.jsonc with moment, reaction, and window-name runtimes ON.");
  console.log("The legacy sharing runtime remains locked OFF; no deployment was performed.");
  console.log("No Cloudflare resource identifier was printed.");
} catch (error) {
  console.error(
    `media staging config render: FAIL: ${error instanceof Error ? error.message : "unknown error"}`,
  );
  process.exitCode = 1;
}
