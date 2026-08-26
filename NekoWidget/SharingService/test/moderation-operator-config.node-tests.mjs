import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { validateDisabledModerationOperatorConfig } from "../scripts/moderation-operator-config-lib.mjs";

const testDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(testDirectory, "..");
const source = await readFile(
  join(projectDirectory, "wrangler.moderation-operator.disabled.jsonc"),
  "utf8",
);
const reviewedConfig = JSON.parse(source);

function copyConfig() {
  return structuredClone(reviewedConfig);
}

test("accepts only the tracked operator shell with no public route", () => {
  assert.doesNotThrow(() => validateDisabledModerationOperatorConfig(copyConfig()));
  assert.equal(reviewedConfig.workers_dev, false);
  assert.equal(reviewedConfig.preview_urls, false);
  assert.equal(reviewedConfig.vars.OPERATOR_RUNTIME_ENABLED, "NO");
});

test("rejects every direct or preview reachability mechanism", () => {
  for (const [field, value] of [
    ["workers_dev", true],
    ["preview_urls", true],
    ["routes", [{ pattern: "operator.example.com/*", zone_name: "example.com" }]],
    ["route", "operator.example.com/*"],
  ]) {
    const config = copyConfig();
    config[field] = value;
    assert.throws(
      () => validateDisabledModerationOperatorConfig(config),
      /must not|unreviewed field/u,
      field,
    );
  }
});

test("rejects runtime enabling and unreviewed variables", () => {
  for (const vars of [
    { OPERATOR_RUNTIME_ENABLED: "YES" },
    { OPERATOR_RUNTIME_ENABLED: "yes" },
    { OPERATOR_RUNTIME_ENABLED: "NO", OPERATOR_ACCESS_AUD: "secret" },
  ]) {
    const config = copyConfig();
    config.vars = vars;
    assert.throws(
      () => validateDisabledModerationOperatorConfig(config),
      /reviewed disabled policy/u,
    );
  }
});

test("rejects every resource, trigger, secret, and service binding", () => {
  const unsafeFields = {
    account_id: "00000000000000000000000000000000",
    d1_databases: [],
    r2_buckets: [],
    kv_namespaces: [],
    services: [],
    queues: {},
    triggers: { crons: ["* * * * *"] },
    ratelimits: [],
    durable_objects: { bindings: [] },
    dispatch_namespaces: [],
    assets: { directory: "public" },
    unsafe: {},
  };

  for (const [field, value] of Object.entries(unsafeFields)) {
    const config = copyConfig();
    config[field] = value;
    assert.throws(
      () => validateDisabledModerationOperatorConfig(config),
      /unreviewed field/u,
      field,
    );
  }
});

test("rejects entry-point or Worker identity drift", () => {
  const changedEntryPoint = copyConfig();
  changedEntryPoint.main = "src/index.ts";
  assert.throws(
    () => validateDisabledModerationOperatorConfig(changedEntryPoint),
    /entry point changed/u,
  );

  const changedName = copyConfig();
  changedName.name = "neko-window-sharing-staging";
  assert.throws(
    () => validateDisabledModerationOperatorConfig(changedName),
    /Worker name changed/u,
  );
});

test("keeps the public Worker and its tracked configs free of the operator namespace", async () => {
  const publicFiles = await Promise.all(
    ["src/index.ts", "wrangler.jsonc", "wrangler.staging.template.jsonc"].map(
      (path) => readFile(join(projectDirectory, path), "utf8"),
    ),
  );
  for (const content of publicFiles) {
    assert.doesNotMatch(content, /moderation-operator-worker|\/operator\/v1|OPERATOR_RUNTIME_ENABLED/u);
  }

  const operatorEntryPoint = await readFile(
    join(projectDirectory, "src/moderation-operator-worker.ts"),
    "utf8",
  );
  assert.doesNotMatch(operatorEntryPoint, /from\s+["']\.\/index["']|\/v[123]\/moments|\/health/u);
});
