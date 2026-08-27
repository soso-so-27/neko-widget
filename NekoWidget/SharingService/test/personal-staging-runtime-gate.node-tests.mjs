import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import {
  parseRuntimeGateUpdate,
  runRuntimeGateControl,
  runtimeGateCommand,
  runtimeGateConfigName,
  runtimeGateManifestName,
  runtimeGateUpdateSQL,
  validateRuntimeGateManifest,
  verifyRuntimeGateOrigin,
} from "../scripts/personal-staging-runtime-gate-lib.mjs";
import { renderStagingConfig } from "../scripts/staging-config-lib.mjs";

const projectDirectory = join(import.meta.dirname, "..");
const migration = await readFile(join(projectDirectory, "migrations", "0011_apns_route_schema.sql"), "utf8");
const template = await readFile(join(projectDirectory, "wrangler.staging.template.jsonc"), "utf8");
const manifest = Object.freeze({
  schemaVersion: 1,
  accountId: "0123456789abcdef0123456789abcdef",
  databaseId: "11111111-1111-4111-8111-111111111111",
  workerName: "neko-window-sharing-staging",
  origin: "https://neko-window-sharing-staging.example.workers.dev",
  expectedGeneration: 0,
  desiredState: "build70-media-apns-on",
});
const config = renderStagingConfig(template, {
  NEKO_STAGING_D1_DATABASE_ID: manifest.databaseId,
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
}, { expectedMomentRuntime: "YES", expectedAPNSRuntime: "YES" });

function database() {
  const value = new DatabaseSync(":memory:");
  value.exec(`CREATE TABLE apns_subscriptions (
    device_id TEXT PRIMARY KEY, participant_id TEXT, environment TEXT,
    token_ciphertext TEXT, token_nonce TEXT, token_digest TEXT,
    encryption_key_id TEXT, updated_at INTEGER, expires_at INTEGER
  ) STRICT;`);
  value.exec(migration);
  return value;
}

function updateOutput(input = manifest) {
  const state = input.desiredState === "broad-off"
    ? { media: 0, apns: 0, report: 0 }
    : { media: 1, apns: 1, report: 0 };
  return JSON.stringify([{
    success: true,
    results: [{
      generation: input.expectedGeneration + 1,
      media_enabled: state.media,
      apns_enabled: state.apns,
      report_ingestion_enabled: state.report,
      updated_at: 1234,
    }],
    meta: { changes: 1 },
  }]);
}

test("0011 installs one strict, closed generation gate and CAS cannot replay", () => {
  const value = database();
  assert.deepEqual({ ...value.prepare(
    `SELECT singleton, generation, media_enabled, apns_enabled,
            report_ingestion_enabled
       FROM personal_staging_runtime_gate`,
  ).get() }, {
    singleton: 1, generation: 0, media_enabled: 0,
    apns_enabled: 0, report_ingestion_enabled: 0,
  });
  assert.deepEqual({ ...value.prepare(runtimeGateUpdateSQL(manifest)).get() }, {
    generation: 1, media_enabled: 1, apns_enabled: 1,
    report_ingestion_enabled: 0,
    updated_at: value.prepare(
      "SELECT updated_at FROM personal_staging_runtime_gate WHERE singleton = 1",
    ).get().updated_at,
  });
  assert.equal(value.prepare(runtimeGateUpdateSQL(manifest)).get(), undefined);
  assert.throws(
    () => value.exec("INSERT INTO personal_staging_runtime_gate VALUES (2, 0, 0, 0, 0, 0)"),
    /CHECK constraint failed/u,
  );
  assert.throws(
    () => value.exec(
      "UPDATE personal_staging_runtime_gate SET media_enabled = 0, apns_enabled = 1",
    ),
    /CHECK constraint failed/u,
  );
  assert.throws(
    () => value.exec("UPDATE personal_staging_runtime_gate SET generation = -1"),
    /CHECK constraint failed/u,
  );
});

test("manifest is exact, secret-free, and supports only the two reviewed states", () => {
  assert.deepEqual(validateRuntimeGateManifest(manifest), manifest);
  assert.equal(validateRuntimeGateManifest({ ...manifest, desiredState: "broad-off" }).desiredState, "broad-off");
  for (const invalid of [
    { ...manifest, desiredState: "report-on" },
    { ...manifest, expectedGeneration: -1 },
    { ...manifest, origin: `${manifest.origin}/path` },
    { ...manifest, token: "secret" },
  ]) assert.throws(() => validateRuntimeGateManifest(invalid), /manifest|origin/u);
});

test("command fixes config, database and exact CAS SQL without shell execution", () => {
  const command = runtimeGateCommand("C:\\safe\\sharing", manifest);
  assert.equal(command.executable, process.execPath);
  assert.equal(command.args.includes("--remote"), true);
  assert.equal(command.args.includes("neko-window-sharing-staging"), true);
  assert.equal(command.args.includes("--command"), true);
  assert.match(command.args.at(-1), /WHERE singleton = 1 AND generation = 0/u);
  assert.doesNotMatch(command.args.join(" "), /token|secret|email/u);
});

test("D1 result must prove exactly one expected change", () => {
  assert.equal(parseRuntimeGateUpdate(updateOutput(), manifest).generation, 1);
  for (const output of [
    JSON.stringify([{ success: true, results: [], meta: { changes: 0 } }]),
    JSON.stringify([{ success: true, results: [{}, {}], meta: { changes: 2 } }]),
    updateOutput({ ...manifest, desiredState: "broad-off" }),
  ]) assert.throws(() => parseRuntimeGateUpdate(output, manifest), /exactly one|unexpected/u);
});

test("same-origin verification requires exact health body, generation and state headers", async () => {
  await verifyRuntimeGateOrigin(manifest, async (url, init) => {
    assert.equal(url, `${manifest.origin}/health`);
    assert.equal(init.cache, "no-store");
    assert.equal(init.redirect, "manual");
    return new Response(JSON.stringify({ status: "ok", protocolVersion: 1 }), {
      headers: {
        "Content-Type": "application/json",
        "Neko-Runtime-Gate-Generation": "1",
        "Neko-Runtime-Media": "ON",
        "Neko-Runtime-Apns": "ON",
        "Neko-Runtime-Report-Ingestion": "OFF",
      },
    });
  });
  await assert.rejects(
    verifyRuntimeGateOrigin(manifest, async () => new Response(
      JSON.stringify({ status: "ok", protocolVersion: 1 }),
      { headers: { "Content-Type": "application/json" } },
    )),
    /same-origin/u,
  );
  await assert.rejects(
    verifyRuntimeGateOrigin(manifest, async (_url, init) => new Promise((resolve, reject) => {
      assert.ok(init.signal instanceof AbortSignal);
      init.signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
      void resolve;
    }), { timeoutMilliseconds: 1 }),
    /may already be applied/u,
  );
});

test("plan is local-only and confirmed control performs one CAS then verifies", async () => {
  const reader = async (path) => {
    if (path.endsWith(runtimeGateManifestName)) return JSON.stringify(manifest);
    if (path.endsWith(runtimeGateConfigName)) return config;
    throw new Error("unexpected file");
  };
  let calls = 0;
  assert.match(await runRuntimeGateControl(["--plan"], {
    projectDirectory: "/safe/project",
    readFileImpl: reader,
    runCommand: async () => { calls += 1; throw new Error("must not run"); },
    fetchImpl: async () => { calls += 1; throw new Error("must not fetch"); },
  }), /no D1 update or network/u);
  assert.equal(calls, 0);

  const commands = [];
  const result = await runRuntimeGateControl(["--confirm-build70-media-apns-on"], {
    projectDirectory: "/safe/project",
    readFileImpl: reader,
    runCommand: async (command) => {
      commands.push(command);
      return command.args.at(-1) === "--version" ? "wrangler 4.125.0" : updateOutput();
    },
    fetchImpl: async () => new Response(JSON.stringify({ status: "ok", protocolVersion: 1 }), {
      headers: {
        "Content-Type": "application/json",
        "Neko-Runtime-Gate-Generation": "1",
        "Neko-Runtime-Media": "ON",
        "Neko-Runtime-Apns": "ON",
        "Neko-Runtime-Report-Ingestion": "OFF",
      },
    }),
  });
  assert.equal(commands.length, 2);
  assert.equal(commands[1].args.filter((value) => value === "--command").length, 1);
  assert.match(result, /generation 1 verified/u);
  assert.doesNotMatch(result, /account|database|origin|token|secret/u);

  await assert.rejects(runRuntimeGateControl(["--confirm-broad-off"], {
    projectDirectory: "/safe/project",
    readFileImpl: reader,
    runCommand: async () => { throw new Error("must not run"); },
  }), /confirmation does not match/u);
});

test("the fixed control manifest is git-ignored", async () => {
  const ignore = await readFile(join(projectDirectory, ".gitignore"), "utf8");
  assert.match(ignore, /^personal-staging-runtime-gate-manifest\.json$/mu);
});
