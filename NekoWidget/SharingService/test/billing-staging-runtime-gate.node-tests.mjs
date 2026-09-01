import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import {
  billingRuntimeGateCommand,
  billingRuntimeGateConfigName,
  billingRuntimeGateManifestName,
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
    .filter((name) => /^00(?:0[1-9]|1[0-9]|2[0-4])_.*\.sql$/u.test(name))
    .sort();
  assert.equal(files.length, 24);
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
});

function healthResponse(state, generation) {
  const headers = new Headers({
    "Content-Type": "application/json",
    "Neko-Runtime-Billing-Gate-Generation": String(generation),
  });
  for (const key of gateKeys) {
    headers.set(
      healthHeader[key],
      billingRuntimeGateStates[state][key] === 1 ? "ON" : "OFF",
    );
  }
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

test("same-origin health requires generation and all seven effective headers", async () => {
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
