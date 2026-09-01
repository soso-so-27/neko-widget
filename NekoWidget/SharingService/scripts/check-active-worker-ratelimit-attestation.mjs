import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import {
  activeWorkerRateLimitManifestName,
  attestActiveWorkerRateLimits,
  parseActiveWorkerRateLimitManifest,
} from "./active-worker-ratelimit-attestation-lib.mjs";

const serviceDirectory = join(import.meta.dirname, "..");

export async function runActiveWorkerRateLimitAttestationCLI({
  argv = process.argv.slice(2),
  environment = process.env,
  readFileImpl = readFile,
  fetchImpl = fetch,
  stdout = process.stdout,
} = {}) {
  let passed = false;
  try {
    if (!Array.isArray(argv) || argv.length !== 0) throw new Error("invalid arguments");
    const manifest = parseActiveWorkerRateLimitManifest(await readFileImpl(
      join(serviceDirectory, activeWorkerRateLimitManifestName),
      "utf8",
    ));
    passed = await attestActiveWorkerRateLimits({
      manifest,
      token: environment.CLOUDFLARE_API_TOKEN,
      fetchImpl,
    });
  } catch {
    passed = false;
  }
  stdout.write(`${passed}\n`);
  return passed ? 0 : 1;
}

if (process.argv[1] !== undefined
    && pathToFileURL(process.argv[1]).href === import.meta.url) {
  process.exitCode = await runActiveWorkerRateLimitAttestationCLI();
}
