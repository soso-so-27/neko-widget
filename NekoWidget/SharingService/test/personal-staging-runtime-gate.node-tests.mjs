import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import {
  parseRuntimeGateStatus,
  parseRuntimeGateUpdate,
  runRuntimeGateControl,
  runtimeGateCommand,
  runtimeGateConfigName,
  runtimeGateManifestName,
  runtimeGateStatusCommand,
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
  origin: "https://neko-window-sharing-staging.nakanishisoya.workers.dev",
  expectedGeneration: 0,
  desiredState: "build70-media-apns-on",
});
const config = renderStagingConfig(template, {
  NEKO_STAGING_D1_DATABASE_ID: manifest.databaseId,
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
  NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID: "700004",
  NEKO_STAGING_BILLING_APPLE_NOTIFICATION_RATE_LIMIT_NAMESPACE_ID: "700005",
}, {
  expectedMomentRuntime: "YES",
  expectedAPNSRuntime: "YES",
  expectedReportIngestionRuntime: "YES",
});

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
  const state = {
    "build70-media-apns-on": { media: 1, apns: 1, report: 0 },
    "broad-off": { media: 0, apns: 0, report: 0 },
  }[input.desiredState];
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

function statusOutput({
  generation = 0,
  media = 0,
  apns = 0,
  report = 0,
} = {}) {
  return JSON.stringify([{
    success: true,
    results: [{
      generation,
      media_enabled: media,
      apns_enabled: apns,
      report_ingestion_enabled: report,
    }],
    meta: { changes: 0 },
  }]);
}

function healthResponse({ generation, media, apns, report = 0 }) {
  return new Response(JSON.stringify({ status: "ok", protocolVersion: 1 }), {
    headers: {
      "Content-Type": "application/json",
      "Neko-Runtime-Gate-Generation": String(generation),
      "Neko-Runtime-Media": media ? "ON" : "OFF",
      "Neko-Runtime-Apns": apns ? "ON" : "OFF",
      "Neko-Runtime-Report-Ingestion": report ? "ON" : "OFF",
    },
  });
}

function readerFor(input) {
  return async (path) => {
    if (path.endsWith(runtimeGateManifestName)) return JSON.stringify(input);
    if (path.endsWith(runtimeGateConfigName)) return config;
    throw new Error("unexpected file");
  };
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

test("manifest is exact, secret-free, and supports only reviewed runtime states", () => {
  assert.deepEqual(validateRuntimeGateManifest(manifest), manifest);
  for (const desiredState of [
    "build70-media-apns-on",
    "broad-off",
  ]) {
    assert.equal(validateRuntimeGateManifest({ ...manifest, desiredState }).desiredState, desiredState);
  }
  for (const invalid of [
    { ...manifest, origin: "https://another-worker.example.workers.dev" },
    { ...manifest, desiredState: "report-on" },
    { ...manifest, desiredState: "external-beta-all-on" },
    { ...manifest, desiredState: "media-off-report-on" },
    { ...manifest, desiredState: "__proto__" },
    { ...manifest, desiredState: "constructor" },
    { ...manifest, desiredState: "toString" },
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
  assert.match(command.args.join(" "), /wrangler\.general-staging-on\.jsonc/u);
  assert.doesNotMatch(command.args.join(" "), /token|secret|email/u);
});

test("status command is a fixed read-only query and rejects malformed state", () => {
  const command = runtimeGateStatusCommand("C:\\safe\\sharing", manifest);
  assert.equal(command.executable, process.execPath);
  assert.equal(command.args.includes("--remote"), true);
  assert.equal(command.args.includes("--command"), true);
  assert.match(command.args.at(-1), /^SELECT generation, media_enabled, apns_enabled,/u);
  assert.doesNotMatch(command.args.at(-1), /UPDATE|INSERT|DELETE/iu);
  assert.deepEqual(parseRuntimeGateStatus(statusOutput({
    generation: 7, media: 1, apns: 1,
  })), {
    generation: 7,
    media_enabled: 1,
    apns_enabled: 1,
    report_ingestion_enabled: 0,
  });
  for (const output of [
    JSON.stringify([{ success: true, results: [], meta: { changes: 0 } }]),
    statusOutput({ generation: 7, media: 0, apns: 1 }),
    statusOutput({ generation: 7, media: 1, apns: 1, report: 1 }),
    JSON.stringify([{
      success: true,
      results: [{
        generation: 7, media_enabled: 1, apns_enabled: 1,
        report_ingestion_enabled: 0, secret: "unexpected",
      }],
      meta: { changes: 0 },
    }]),
  ]) assert.throws(() => parseRuntimeGateStatus(output), /read-only row|unexpected/u);
});

test("D1 result must prove exactly one expected change", () => {
  assert.equal(parseRuntimeGateUpdate(updateOutput(), manifest).generation, 1);
  for (const output of [
    JSON.stringify([{ success: true, results: [], meta: { changes: 0 } }]),
    JSON.stringify([{ success: true, results: [{}, {}], meta: { changes: 2 } }]),
    updateOutput({ ...manifest, desiredState: "broad-off" }),
  ]) assert.throws(() => parseRuntimeGateUpdate(output, manifest), /exactly one|unexpected/u);
});

test("SQLite executes the reviewed ON to broad-OFF to recovery CAS sequence", () => {
  const value = database();
  const open = manifest;
  const off = Object.freeze({
    ...manifest,
    expectedGeneration: 1,
    desiredState: "broad-off",
  });
  const recover = Object.freeze({
    ...manifest,
    expectedGeneration: 2,
    desiredState: "build70-media-apns-on",
  });
  const rows = [open, off, recover].map((input) => ({
    ...value.prepare(runtimeGateUpdateSQL(input)).get(),
  }));
  assert.deepEqual(rows.map((row) => ({
    generation: row.generation,
    media_enabled: row.media_enabled,
    apns_enabled: row.apns_enabled,
    report_ingestion_enabled: row.report_ingestion_enabled,
  })), [
    { generation: 1, media_enabled: 1, apns_enabled: 1, report_ingestion_enabled: 0 },
    { generation: 2, media_enabled: 0, apns_enabled: 0, report_ingestion_enabled: 0 },
    { generation: 3, media_enabled: 1, apns_enabled: 1, report_ingestion_enabled: 0 },
  ]);
  assert.equal(value.prepare(runtimeGateUpdateSQL(off)).get(), undefined);
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
  const reader = readerFor(manifest);
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
    fetchImpl: async () => healthResponse({ generation: 1, media: 1, apns: 1 }),
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

test("inherited object keys cannot bypass explicit runtime confirmation", async () => {
  for (const argument of ["__proto__", "constructor", "toString"]) {
    let reads = 0;
    let runs = 0;
    let fetches = 0;
    await assert.rejects(
      runRuntimeGateControl([argument], {
        projectDirectory: "/safe/project",
        readFileImpl: async () => { reads += 1; throw new Error("must not read"); },
        runCommand: async () => { runs += 1; throw new Error("must not run"); },
        fetchImpl: async () => { fetches += 1; throw new Error("must not fetch"); },
      }),
      /use exactly/u,
    );
    assert.equal(reads, 0);
    assert.equal(runs, 0);
    assert.equal(fetches, 0);
  }
});

test("read-only status reconciles D1 and the same origin without mutation", async () => {
  const statusManifest = Object.freeze({
    ...manifest,
    expectedGeneration: 7,
    desiredState: "broad-off",
  });
  const commands = [];
  const result = await runRuntimeGateControl(["--status"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(statusManifest),
    runCommand: async (command) => {
      commands.push(command);
      return command.args.at(-1) === "--version"
        ? "wrangler 4.125.0"
        : statusOutput({ generation: 7, media: 1, apns: 1 });
    },
    fetchImpl: async () => healthResponse({ generation: 7, media: 1, apns: 1 }),
  });
  assert.equal(commands.length, 2);
  assert.match(result, /generation 7 media=ON apns=ON report=OFF/u);
  assert.doesNotMatch(result, /account|database|origin|token|secret/u);

  await assert.rejects(runRuntimeGateControl(["--status"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor({ ...statusManifest, expectedGeneration: 6 }),
    runCommand: async (command) => command.args.at(-1) === "--version"
      ? "wrangler 4.125.0"
      : statusOutput({ generation: 7, media: 1, apns: 1 }),
    fetchImpl: async () => healthResponse({ generation: 7, media: 1, apns: 1 }),
  }), /manifest generation is stale; live generation is 7/u);

  await assert.rejects(runRuntimeGateControl(["--status"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(statusManifest),
    runCommand: async (command) => command.args.at(-1) === "--version"
      ? "wrangler 4.125.0"
      : statusOutput({ generation: 7, media: 1, apns: 1, report: 0 }),
    fetchImpl: async () => healthResponse({
      generation: 7, media: 1, apns: 1, report: 1,
    }),
  }), /same-origin runtime gate verification failed/u);

  let fetchedReportOnState = false;
  await assert.rejects(runRuntimeGateControl(["--status"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(statusManifest),
    runCommand: async (command) => command.args.at(-1) === "--version"
      ? "wrangler 4.125.0"
      : statusOutput({ generation: 7, media: 1, apns: 1, report: 1 }),
    fetchImpl: async () => {
      fetchedReportOnState = true;
      return healthResponse({ generation: 7, media: 1, apns: 1, report: 1 });
    },
  }), /runtime gate D1 status returned an unexpected row/u);
  assert.equal(fetchedReportOnState, false);
});

test("each confirmed reviewed state performs one CAS and exact origin verification", async () => {
  const offManifest = Object.freeze({
    ...manifest,
    expectedGeneration: 1,
    desiredState: "broad-off",
  });
  const recoveryManifest = Object.freeze({
    ...manifest,
    expectedGeneration: 2,
    desiredState: "build70-media-apns-on",
  });
  for (const fixture of [
    {
      argument: "--confirm-broad-off",
      manifest: offManifest,
      expected: { generation: 2, media: 0, apns: 0, report: 0 },
    },
    {
      argument: "--confirm-build70-media-apns-on",
      manifest: recoveryManifest,
      expected: { generation: 3, media: 1, apns: 1, report: 0 },
    },
  ]) {
    const commands = [];
    const result = await runRuntimeGateControl([fixture.argument], {
      projectDirectory: "/safe/project",
      readFileImpl: readerFor(fixture.manifest),
      runCommand: async (command) => {
        commands.push(command);
        return command.args.at(-1) === "--version"
          ? "wrangler 4.125.0"
          : updateOutput(fixture.manifest);
      },
      fetchImpl: async () => healthResponse(fixture.expected),
    });
    assert.equal(commands.length, 2);
    assert.match(result, new RegExp(`generation ${fixture.expected.generation} verified`, "u"));
  }
});

test("the fixed control manifest and all-upper-bounds config are git-ignored", async () => {
  const ignore = await readFile(join(projectDirectory, ".gitignore"), "utf8");
  assert.match(ignore, /^personal-staging-runtime-gate-manifest\.json$/mu);
  assert.match(ignore, /^wrangler\.general-staging-on\.jsonc$/mu);
});
