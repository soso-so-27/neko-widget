import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { runBillingSponsorshipLocalDrill } from "../scripts/billing-sponsorship-local-drill.mjs";

const serviceDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const scriptPath = join(
  serviceDirectory,
  "scripts",
  "billing-sponsorship-local-drill.mjs",
);

test("applies every migration and completes the isolated gate drill", () => {
  assert.deepEqual(runBillingSponsorshipLocalDrill(), {
    migrationsApplied: 25,
    checksPassed: 12,
    identifiersEmitted: 0,
  });
});

test("CLI emits aggregate PASS evidence without synthetic identifiers", () => {
  const execution = spawnSync(process.execPath, ["--no-warnings", scriptPath], {
    cwd: serviceDirectory,
    encoding: "utf8",
    env: {},
  });
  assert.equal(execution.status, 0, execution.stderr);
  assert.equal(execution.stderr, "");
  assert.equal(
    execution.stdout,
    "billing sponsorship local drill: PASS (migrations=25, checks=12, identifiers=0)\n",
  );
  assert.doesNotMatch(execution.stdout, /[0-9a-f]{8}-[0-9a-f-]{27}/iu);
  assert.doesNotMatch(
    execution.stdout,
    /local-drill|billingAccount|lineage|participant/iu,
  );
});

test("drill JavaScript boundary is local-only and has no dynamic capability loading", () => {
  const source = readFileSync(scriptPath, "utf8");
  const importedModules = [
    ...[...source.matchAll(/\bfrom\s+(["'])([^"']+)\1/gu)]
      .map((match) => match[2]),
    ...[...source.matchAll(/^\s*import\s+(["'])([^"']+)\1\s*;/gmu)]
      .map((match) => match[2]),
  ].sort();
  assert.deepEqual(importedModules, [
    "node:fs",
    "node:os",
    "node:path",
    "node:sqlite",
    "node:url",
  ]);
  assert.doesNotMatch(
    source,
    /\b(?:fetch|WebSocket|EventSource|XMLHttpRequest)\s*\(|https?:\/\/|node:(?:http|https|http2|net|tls|dns|dgram|child_process|worker_threads)|\bundici\b/iu,
  );
  assert.doesNotMatch(
    source,
    /\b(?:import|require)\s*\(|process\.(?:env|binding|dlopen)|\beval\s*\(|\bFunction\s*\(/u,
  );
  assert.doesNotMatch(
    source,
    /\bwrangler\s+(?:d1|deploy)|--remote|secret|production/iu,
  );
  assert.match(source, /node:sqlite/u);
  assert.match(source, /mkdtempSync/u);
  assert.doesNotMatch(source, /realpathSync\(temporaryDirectory\)/u);
  assert.match(source, /lstatSync\(temporaryDirectory\)/u);
  assert.match(source, /rmSync\(temporaryDirectory/u);
});
