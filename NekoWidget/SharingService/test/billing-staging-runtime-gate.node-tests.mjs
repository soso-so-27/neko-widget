import { createHash } from "node:crypto";
import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import {
  billingRuntimeGateCommand,
  billingRuntimeGateConfigName,
  billingRuntimeGateManifestName,
  privateBillingRuntimeGateConfigName,
  billingRuntimeGateStates,
  billingRuntimeGateStatusCommand,
  billingRuntimeGateUpdateSQL,
  parseBillingRuntimeGateArguments,
  parseBillingRuntimeGateStatus,
  parseBillingRuntimeGateUpdate,
  runBillingRuntimeGateControl,
  validateBillingRuntimeGateManifest,
  verifyBillingRuntimeGateOrigin,
} from "../scripts/billing-staging-runtime-gate-lib.mjs";
import { renderStagingConfig } from "../scripts/staging-config-lib.mjs";
import { renderLiveConfigs } from "../gateway/render-live-config.mjs";
import { billingControlEnabledFlags } from "../scripts/billing-control-staging-config-lib.mjs";

const ownerAdmission = JSON.stringify({ version: 1, bootstrapClientRequestId: '5f30c0de-0000-4000-8000-000000000001', initialPublicKeySHA256: 'a'.repeat(64), startsAtMs: Date.now() - 1000, expiresAtMs: Date.now() + 3600000 });
const ownerPolicyHash = createHash('sha256').update(ownerAdmission).digest('hex');
const projectDirectory = join(import.meta.dirname, "..");
const template = await readFile(
  join(projectDirectory, "wrangler.staging.template.jsonc"),
  "utf8",
);
const environment = Object.freeze({
  NEKO_STAGING_D1_DATABASE_ID: "11111111-1111-4111-8111-111111111111",
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
  NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID: "700004",
  NEKO_STAGING_BILLING_APPLE_NOTIFICATION_RATE_LIMIT_NAMESPACE_ID: "700005",
});
const config = renderStagingConfig(template, environment, {
  expectedMomentRuntime: "YES",
  expectedAPNSRuntime: "YES",
  expectedReportIngestionRuntime: "YES",
  expectedBillingRuntimeProfile: "billing-control-on",
});
const manifest = Object.freeze({
  schemaVersion: 1,
  accountId: "0123456789abcdef0123456789abcdef",
  databaseId: environment.NEKO_STAGING_D1_DATABASE_ID,
  workerName: "neko-window-sharing-staging",
  origin: "https://neko-window-sharing-staging.nakanishisoya.workers.dev",
  expectedGeneration: 0,
  expectedState: "all-off",
  desiredState: "bootstrap-only",
});
const stateNames = Object.freeze(Object.keys(billingRuntimeGateStates));
const gateKeys = Object.freeze(Object.keys(billingRuntimeGateStates["all-off"]));

async function database() {
  const value = new DatabaseSync(":memory:");
  const directory = join(projectDirectory, "migrations");
  const files = (await readdir(directory))
    .filter((name) => /^00(?:0[1-9]|1[0-9]|2[0-5])_.*\.sql$/u.test(name))
    .sort();
  assert.equal(files.length, 25);
  for (const file of files) value.exec(await readFile(join(directory, file), "utf8"));
  return value;
}

function rowFor(state, generation) {
  return { generation, ...billingRuntimeGateStates[state] };
}

function updateOutput(input) {
  return JSON.stringify([{
    success: true,
    results: [{
      ...rowFor(input.desiredState, input.expectedGeneration + 1),
      updated_at: 1234,
    }],
    meta: { changes: 1 },
  }]);
}

function statusOutput(state, generation) {
  return JSON.stringify([{
    success: true,
    results: [rowFor(state, generation)],
    meta: { changes: 0 },
  }]);
}

const healthHeader = Object.freeze({
  account_bootstrap_enabled: "Neko-Runtime-Billing-Account-Bootstrap",
  transaction_ingestion_enabled: "Neko-Runtime-Billing-Transaction-Ingestion",
  apple_notification_ingestion_enabled:
    "Neko-Runtime-Billing-Apple-Notification-Ingestion",
  subscription_reconciliation_enabled:
    "Neko-Runtime-Billing-Subscription-Reconciliation",
  effective_entitlement_enabled: "Neko-Runtime-Billing-Effective-Entitlement",
  window_sponsorship_enabled: "Neko-Runtime-Billing-Window-Sponsorship",
  account_recovery_enabled: "Neko-Runtime-Billing-Account-Recovery",
  apple_notification_history_recovery_enabled:
    "Neko-Runtime-Billing-Apple-Notification-History-Recovery",
});

function healthResponse(state, generation) {
  const headers = new Headers({
    "neko-runtime-billing-owner-admission": "READY",
    "neko-runtime-billing-owner-policy-sha256": ownerPolicyHash,
    "Content-Type": "application/json",
    "Neko-Runtime-Billing-Gate-Generation": String(generation),
  });
  for (const key of gateKeys) {
    headers.set(
      healthHeader[key],
      billingRuntimeGateStates[state][key] === 1 ? "ON" : "OFF",
    );
  }
  headers.set("Neko-Runtime-Billing-Apple-Notification-Rate-Limiter", "READY");
  return new Response(JSON.stringify({ status: "ok", protocolVersion: 1 }), {
    headers,
  });
}

function readerFor(input) {
  return async (path) => {
    if (path.endsWith(billingRuntimeGateManifestName)) {
      return JSON.stringify(input);
    }
    if (path.endsWith(billingRuntimeGateConfigName)) return config;
    throw new Error("unexpected file");
  };
}

function privateFixture() {
  const { gateway } = renderLiveConfigs({
    metadata: { script: { id: "neko-window-sharing-staging" } }, routes: [], domains: [],
    subdomain: { enabled: true, previews_enabled: false },
    deployments: { deployments: [{ versions: [{ percentage: 100 }] }] },
    schedules: { schedules: [] },
    settings: { compatibility_date: "2026-08-17", compatibility_flags: ["nodejs_compat"], bindings: [
      { type: "d1", name: "DB", id: "cb3b2386-3a6f-4253-b918-8aafed9ff735" },
      { type: "plain_text", name: "ENVIRONMENT", text: "staging" },
      { type: "plain_text", name: "APNS_RUNTIME_ENABLED", text: "YES" },
    ] },
  }, "/safe/project");
  gateway.vars.BILLING_SANDBOX_OWNER_ADMISSION = ownerAdmission;
  for (const flag of billingControlEnabledFlags) gateway.vars[flag] = "YES";
  const input = { ...manifest, accountId: gateway.account_id, databaseId: gateway.d1_databases[0].database_id };
  return { gateway, input, reader: async path => {
    if (path.endsWith(billingRuntimeGateManifestName)) return JSON.stringify(input);
    if (path.endsWith(privateBillingRuntimeGateConfigName)) return JSON.stringify(gateway);
    throw new Error("unexpected private control file");
  } };
}

test("private plan accepts only the closed Sandbox gateway and never runs commands or fetch", async () => {
  const { gateway, input } = privateFixture();
  const runPlan = (config = gateway, chosen = input) => runBillingRuntimeGateControl(["--plan"], {
    projectDirectory: "/safe/project", profile: "private-gateway",
    readFileImpl: async path => JSON.stringify(path.endsWith(billingRuntimeGateManifestName) ? chosen : config),
    runCommand: async () => assert.fail("plan performed command"),
    fetchImpl: async () => assert.fail("plan performed fetch"),
  });
  assert.match(await runPlan(), /no D1 update or network request/u);
  for (const mutate of [c => { c.workers_dev = true; }, c => { c.preview_urls = true; },
    c => { c.vars.BILLING_STORE_ENVIRONMENT = "Production"; },
    c => { c.vars.BILLING_APPLE_NOTIFICATION_HISTORY_RECOVERY_RUNTIME_ENABLED = "YES"; },
    c => { c.vars.ENVIRONMENT = "production"; }, c => { c.name = "neko-window-sharing-staging"; },
    c => { c.services[0].service = "other-verifier"; }, c => { c.d1_databases[0].database_id = manifest.databaseId; },
    c => { c.ratelimits[0].simple.limit = 1000; }, c => { c.vars.SECRET = "do-not-accept"; }, c => { delete c.vars.BILLING_SANDBOX_OWNER_ADMISSION; }, c => { c.vars.BILLING_SANDBOX_OWNER_ADMISSION = "{}"; }]) {
    const bad = structuredClone(gateway); mutate(bad);
    await assert.rejects(runPlan(bad), /reviewed Sandbox target/u);
  }
  await assert.rejects(runPlan({ ...gateway, account_id: manifest.accountId }, { ...input, accountId: manifest.accountId }),
    /reviewed Sandbox target/u);
});

test("private confirmation checks fresh lower state and caller health before a single CAS", async () => {
  const { input, reader } = privateFixture();
  const commands = [], urls = [];
  const output = await runBillingRuntimeGateControl(["--confirm-bootstrap-only"], {
    projectDirectory: "/safe/project", profile: "private-gateway", readFileImpl: reader,
    runCommand: async command => {
      commands.push(command);
      if (command.args.at(-1) === "--version") return "wrangler 4.125.0";
      assert.ok(command.args.includes(join("/safe/project", privateBillingRuntimeGateConfigName)));
      return command.args.at(-1).startsWith("SELECT") ? statusOutput("all-off", 0) : updateOutput(input);
    },
    fetchImpl: async url => {
      urls.push(url); return healthResponse(urls.length === 1 ? "all-off" : "bootstrap-only", urls.length - 1);
    },
  });
  assert.match(output, /generation 1 verified/u);
  assert.equal(commands.filter(c => c.args.at(-1).startsWith("UPDATE")).length, 1);
  assert.deepEqual(urls, [input.origin + "/v1/billing/health", input.origin + "/v1/billing/health"]);
  assert.ok(commands.every(c => !c.args.includes("deploy")));
});

test("private stale state or failed preflight causes no write; failed postflight is never retried", async () => {
  const { input, reader } = privateFixture();
  for (const failure of ["state", "preflight", "postflight"]) {
    let writes = 0, fetches = 0;
    await assert.rejects(runBillingRuntimeGateControl(["--confirm-bootstrap-only"], {
      projectDirectory: "/safe/project", profile: "private-gateway", readFileImpl: reader,
      runCommand: async command => {
        if (command.args.at(-1) === "--version") return "wrangler 4.125.0";
        if (command.args.at(-1).startsWith("SELECT")) return statusOutput("all-off", failure === "state" ? 1 : 0);
        writes += 1; return updateOutput(input);
      },
      fetchImpl: async () => {
        fetches += 1;
        if (failure === "preflight" || (failure === "postflight" && fetches === 2)) return new Response("unavailable", { status: 503 });
        return healthResponse("all-off", failure === "state" ? 1 : 0);
      },
    }), failure === "state" ? /live generation and state/u : /verification failed/u);
    assert.equal(writes, failure === "postflight" ? 1 : 0);
    assert.equal(fetches, failure === "postflight" ? 2 : 1);
  }
});

test("defines eight cumulative states with one-bit adjacent transitions", () => {
  assert.deepEqual(stateNames, [
    "all-off", "bootstrap-only", "transaction-on", "notification-on",
    "reconciliation-on", "entitlement-on", "sponsorship-on", "recovery-on",
  ]);
  for (let index = 1; index < stateNames.length; index += 1) {
    const before = billingRuntimeGateStates[stateNames[index - 1]];
    const after = billingRuntimeGateStates[stateNames[index]];
    assert.equal(gateKeys.filter((key) => before[key] !== after[key]).length, 1);
  }
});

test("requires exact manifest keys, adjacent state, or emergency all-off", () => {
  assert.deepEqual(validateBillingRuntimeGateManifest(manifest), manifest);
  assert.deepEqual(validateBillingRuntimeGateManifest({
    ...manifest,
    expectedState: "recovery-on",
    desiredState: "all-off",
  }), {
    ...manifest,
    expectedState: "recovery-on",
    desiredState: "all-off",
  });
  for (const invalid of [
    { ...manifest, extra: true },
    { ...manifest, origin: "https://another-worker.example.workers.dev" },
    { ...manifest, expectedState: "all-off", desiredState: "entitlement-on" },
    { ...manifest, expectedState: "bootstrap-only", desiredState: "bootstrap-only" },
    { ...manifest, expectedGeneration: -1 },
  ]) {
    assert.throws(
      () => validateBillingRuntimeGateManifest(invalid),
      /manifest|adjacent or emergency/u,
    );
  }
});

test("emergency billing-all-off is one exact CAS from every reviewed on state", async () => {
  for (let stateIndex = 1; stateIndex < stateNames.length; stateIndex += 1) {
    const value = await database();
    let generation = 0;
    let currentState = "all-off";
    for (const desiredState of stateNames.slice(1, stateIndex + 1)) {
      const seeded = value.prepare(billingRuntimeGateUpdateSQL({
        ...manifest,
        expectedGeneration: generation,
        expectedState: currentState,
        desiredState,
      })).get();
      assert.equal(seeded.generation, generation + 1);
      generation += 1;
      currentState = desiredState;
    }
    const input = {
      ...manifest,
      expectedGeneration: generation,
      expectedState: currentState,
      desiredState: "all-off",
    };
    const statement = value.prepare(billingRuntimeGateUpdateSQL(input));
    const result = statement.get();
    assert.deepEqual({ ...result }, {
      ...rowFor("all-off", generation + 1),
      updated_at: value.prepare(
        "SELECT updated_at FROM billing_runtime_gate WHERE singleton=1",
      ).get().updated_at,
    });
    assert.equal(statement.get(), undefined);
  }
});

test("migration defaults closed and every up/down transition is exact CAS", async () => {
  const value = await database();
  assert.deepEqual({ ...value.prepare(
    `SELECT generation, ${gateKeys.join(", ")} FROM billing_runtime_gate`,
  ).get() }, rowFor("all-off", 0));
  let generation = 0;
  for (const direction of [stateNames.slice(1), [...stateNames].reverse().slice(1)]) {
    let expectedState = direction[0] === "bootstrap-only"
      ? "all-off"
      : "recovery-on";
    for (const desiredState of direction) {
      const input = { ...manifest, expectedGeneration: generation, expectedState, desiredState };
      const statement = value.prepare(billingRuntimeGateUpdateSQL(input));
      assert.deepEqual({ ...statement.get() }, {
        ...rowFor(desiredState, generation + 1),
        updated_at: value.prepare(
          "SELECT updated_at FROM billing_runtime_gate WHERE singleton=1",
        ).get().updated_at,
      });
      assert.equal(statement.get(), undefined);
      generation += 1;
      expectedState = desiredState;
    }
  }
  assert.deepEqual({ ...value.prepare(
    `SELECT generation, ${gateKeys.join(", ")} FROM billing_runtime_gate`,
  ).get() }, rowFor("all-off", 14));
});

test("commands bind one remote database/config and keep auto-provision disabled", () => {
  for (const command of [
    billingRuntimeGateCommand("/safe/project", manifest),
    billingRuntimeGateStatusCommand("/safe/project", manifest),
  ]) {
    assert.equal(command.accountId, manifest.accountId);
    assert.ok(command.args.includes("--remote"));
    assert.ok(command.args.includes("--experimental-provision=false"));
    assert.ok(command.args.includes("--experimental-auto-create=false"));
    assert.ok(command.args.includes("neko-window-sharing-staging"));
    assert.ok(command.args.some((value) => value.endsWith(billingRuntimeGateConfigName)));
  }
});

test("parsers reject stale CAS, partial states, and unknown response fields", () => {
  assert.deepEqual(parseBillingRuntimeGateUpdate(updateOutput(manifest), manifest), {
    ...rowFor("bootstrap-only", 1),
    updated_at: 1234,
  });
  assert.deepEqual(parseBillingRuntimeGateStatus(statusOutput("all-off", 0)), {
    ...rowFor("all-off", 0),
  });
  const partial = rowFor("bootstrap-only", 1);
  partial.effective_entitlement_enabled = 1;
  assert.throws(
    () => parseBillingRuntimeGateStatus(JSON.stringify([{
      success: true, results: [partial], meta: { changes: 0 },
    }])),
    /unexpected row/u,
  );
  assert.throws(
    () => parseBillingRuntimeGateUpdate(JSON.stringify([{
      success: true, results: [], meta: { changes: 0 },
    }]), manifest),
    /exactly one row/u,
  );
});

test("same-origin health requires generation, all eight gates, and the notification limiter", async () => {
  await verifyBillingRuntimeGateOrigin(
    manifest,
    async (url) => {
      assert.equal(url, `${manifest.origin}/health`);
      return healthResponse("bootstrap-only", 1);
    },
  );
  const missingHeader = healthResponse("bootstrap-only", 1);
  missingHeader.headers.delete("Neko-Runtime-Billing-Account-Recovery");
  await assert.rejects(
    verifyBillingRuntimeGateOrigin(manifest, async () => missingHeader),
    /same-origin runtime gate verification failed/u,
  );
  const missingLimiter = healthResponse("bootstrap-only", 1);
  missingLimiter.headers.set(
    "Neko-Runtime-Billing-Apple-Notification-Rate-Limiter",
    "MISSING",
  );
  await assert.rejects(
    verifyBillingRuntimeGateOrigin(manifest, async () => missingLimiter),
    /same-origin runtime gate verification failed/u,
  );
});

test("plan is side-effect free and status reconciles exact state plus health", async () => {
  let commands = 0;
  let fetches = 0;
  assert.match(await runBillingRuntimeGateControl(["--plan"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(manifest),
    runCommand: async () => { commands += 1; throw new Error("unexpected"); },
    fetchImpl: async () => { fetches += 1; throw new Error("unexpected"); },
  }), /no D1 update or network request/u);
  assert.equal(commands, 0);
  assert.equal(fetches, 0);

  assert.match(await runBillingRuntimeGateControl(["--status"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(manifest),
    runCommand: async (command) => command.args.at(-1) === "--version"
      ? "wrangler 4.125.0"
      : statusOutput("all-off", 0),
    fetchImpl: async () => healthResponse("all-off", 0),
  }), /generation 0 all-off/u);
});

test("confirmation repeats the reviewed desired state before one CAS", async () => {
  assert.deepEqual(
    parseBillingRuntimeGateArguments(["--confirm-bootstrap-only"]),
    { action: "confirm", confirmation: "bootstrap-only" },
  );
  await assert.rejects(runBillingRuntimeGateControl(["--confirm-transaction-on"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(manifest),
  }), /does not match/u);

  const commands = [];
  assert.match(await runBillingRuntimeGateControl(["--confirm-bootstrap-only"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(manifest),
    runCommand: async (command) => {
      commands.push(command);
      return command.args.at(-1) === "--version"
        ? "wrangler 4.125.0"
        : updateOutput(manifest);
    },
    fetchImpl: async () => healthResponse("bootstrap-only", 1),
  }), /all-off -> bootstrap-only generation 1 verified/u);
  assert.equal(commands.length, 2);
});

test("non-adjacent emergency stop requires billing-all-off confirmation", async () => {
  const emergency = {
    ...manifest,
    expectedGeneration: 9,
    expectedState: "recovery-on",
    desiredState: "all-off",
  };
  assert.deepEqual(
    parseBillingRuntimeGateArguments(["--confirm-billing-all-off"]),
    { action: "confirm", confirmation: "billing-all-off" },
  );
  await assert.rejects(runBillingRuntimeGateControl(["--confirm-all-off"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(emergency),
  }), /does not match/u);

  const commands = [];
  assert.match(await runBillingRuntimeGateControl(
    ["--confirm-billing-all-off"],
    {
      projectDirectory: "/safe/project",
      readFileImpl: readerFor(emergency),
      runCommand: async (command) => {
        commands.push(command);
        return command.args.at(-1) === "--version"
          ? "wrangler 4.125.0"
          : updateOutput(emergency);
      },
      fetchImpl: async () => healthResponse("all-off", 10),
    },
  ), /emergency billing-all-off generation 10 verified/u);
  assert.equal(commands.length, 2);
});

test('private owner admission mismatch refuses before CAS; rollback does not require active admission', async () => {
  const { input, reader, gateway } = privateFixture();
  for (const mismatch of ['CLOSED', 'different-hash', 'missing-hash']) {
    let writes = 0;
    await assert.rejects(runBillingRuntimeGateControl(['--confirm-bootstrap-only'], {
      projectDirectory: '/safe/project', profile: 'private-gateway', readFileImpl: reader,
      runCommand: async command => {
        if (command.args.at(-1) === '--version') return 'wrangler 4.125.0';
        if (command.args.at(-1).startsWith('UPDATE')) writes += 1;
        return statusOutput('all-off', 0);
      },
      fetchImpl: async () => {
        const response = healthResponse('all-off', 0);
        if (mismatch === 'CLOSED') response.headers.set('neko-runtime-billing-owner-admission', 'CLOSED');
        if (mismatch === 'different-hash') response.headers.set('neko-runtime-billing-owner-policy-sha256', 'b'.repeat(64));
        if (mismatch === 'missing-hash') response.headers.delete('neko-runtime-billing-owner-policy-sha256');
        return response;
      },
    }), /owner admission verification failed/u);
    assert.equal(writes, 0);
  }
  const rollback = { ...input, expectedState: 'recovery-on', desiredState: 'all-off', expectedGeneration: 7 };
  gateway.vars.BILLING_SANDBOX_OWNER_ADMISSION = JSON.stringify({ ...JSON.parse(ownerAdmission), startsAtMs: 0, expiresAtMs: 1000 });
  let fetches = 0, writes = 0;
  await runBillingRuntimeGateControl(['--confirm-billing-all-off'], {
    projectDirectory: '/safe/project', profile: 'private-gateway',
    readFileImpl: async path => JSON.stringify(path.endsWith(billingRuntimeGateManifestName) ? rollback : gateway),
    runCommand: async command => {
      if (command.args.at(-1) === '--version') return 'wrangler 4.125.0';
      if (command.args.at(-1).startsWith('SELECT')) return statusOutput('recovery-on', 7);
      writes += 1; return updateOutput(rollback);
    },
    fetchImpl: async () => {
      fetches += 1;
      // An expired policy masks the live lower gates OFF; emergency rollback must
      // still reconcile exact D1 state without demanding intake READY.
      const response = healthResponse('all-off', fetches === 1 ? 7 : 8);
      response.headers.set('neko-runtime-billing-owner-admission', 'CLOSED');
      response.headers.delete('neko-runtime-billing-owner-policy-sha256');
      return response;
    },
  });
  assert.equal(writes, 1);
});
