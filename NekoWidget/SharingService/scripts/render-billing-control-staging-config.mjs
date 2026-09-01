import { open, readFile, unlink } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  renderBillingControlStagingPair,
} from "./billing-control-staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");
const templatePath = join(projectDirectory, "wrangler.staging.template.jsonc");
const offPath = join(
  projectDirectory,
  "wrangler.billing-control-staging-off.jsonc",
);
const onPath = join(
  projectDirectory,
  "wrangler.billing-control-staging-on.jsonc",
);

let offHandle;
let onHandle;
let createdOff = false;
let createdOn = false;
try {
  const template = await readFile(templatePath, "utf8");
  const rendered = renderBillingControlStagingPair(template, process.env);
  offHandle = await open(offPath, "wx", 0o600);
  createdOff = true;
  onHandle = await open(onPath, "wx", 0o600);
  createdOn = true;
  await Promise.all([
    offHandle.writeFile(rendered.off, { encoding: "utf8" }),
    onHandle.writeFile(rendered.on, { encoding: "utf8" }),
  ]);
  console.log("Created ignored billing-control staging OFF/ON configs.");
  console.log("The ON config enables all seven billing upper gates; both configs preserve existing media, APNs, and report upper gates.");
  console.log("No deployment, D1 update, purchase, recovery, or secret output occurred.");
} catch (error) {
  await Promise.allSettled([offHandle?.close(), onHandle?.close()]);
  if (createdOff) await unlink(offPath).catch(() => {});
  if (createdOn) await unlink(onPath).catch(() => {});
  console.error(
    `billing control staging config render: FAIL: ${
      error instanceof Error ? error.message : "unknown error"
    }`,
  );
  process.exitCode = 1;
} finally {
  await Promise.allSettled([offHandle?.close(), onHandle?.close()]);
}
