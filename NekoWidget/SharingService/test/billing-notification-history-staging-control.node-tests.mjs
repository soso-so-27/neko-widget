import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  historyBillingGateKeys,
  historyEmergencyOffCommand,
  historyEmergencyOffSQL,
  historyStagingControlConfigName,
  historyStagingControlManifestName,
  historyStagingStatusCommand,
  parseHistoryEmergencyOff,
  parseHistoryStagingControlArguments,
  parseHistoryStagingStatus,
  runHistoryStagingControl,
  validateHistoryStagingControlManifest,
} from "../scripts/billing-notification-history-staging-control-lib.mjs";
import {
  parseBillingRuntimeGateStatus,
} from "../scripts/billing-staging-runtime-gate-lib.mjs";
import {
  renderBillingControlStagingPair,
} from "../scripts/billing-control-staging-config-lib.mjs";

const projectDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const template = await readFile(
  join(projectDirectory, "wrangler.staging.template.jsonc"),
  "utf8",
);
const configEnvironment = Object.freeze({
  NEKO_STAGING_D1_DATABASE_ID: "00000000-0000-0000-0000-000000000000",
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
  NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID: "700004",
  NEKO_STAGING_BILLING_APPLE_NOTIFICATION_RATE_LIMIT_NAMESPACE_ID: "700005",
});
const config = renderBillingControlStagingPair(
  template,
  configEnvironment,
).on;
const expectedGates = Object.freeze(Object.fromEntries(
  historyBillingGateKeys.map((key) => [key, 1]),
));
const manifest = Object.freeze({
  schemaVersion: 1,
  accountId: "0".repeat(32),
  databaseId: "00000000-0000-0000-0000-000000000000",
  workerName: "neko-window-sharing-staging",
  origin: "https://neko-window-sharing-staging.nakanishisoya.workers.dev",
  expectedGeneration: 7,
  expectedStoreEnvironment: "Sandbox",
  expectedBundleId: "jp.nekowidget.app",
  expectedGates,
});

function wranglerOutput(row, changes) {
  return JSON.stringify([{
    success: true,
    results: [row],
    meta: { changes },
  }]);
}

function statusRow(input = manifest) {
  return {
    billing_gate_generation: input.expectedGeneration,
    ...input.expectedGates,
    history_recovery_generation: 3,
    history_recovery_state: "retry_wait",
    store_environment: "Sandbox",
    bundle_id: "jp.nekowidget.app",
    frozen_start_date_ms: 1_788_000_000_000,
    frozen_end_date_ms: 1_788_086_400_000,
    committed_page_count: 2,
    committed_record_count: 8,
    cursor_reset_count: 1,
    attempts: 2,
    not_before: 1_788_086_430,
    last_error_code: "apple_notification_history_unavailable",
  };
}

function emergencyOffRow() {
  return {
    billing_gate_generation: manifest.expectedGeneration + 1,
    ...manifest.expectedGates,
    apple_notification_history_recovery_enabled: 0,
  };
}

function healthResponse(generation, effectiveHistory = "OFF") {
  const headers = new Headers({
    "Content-Type": "application/json; charset=utf-8",
    "Neko-Runtime-Billing-Gate-Generation": String(generation),
    "Neko-Runtime-Billing-Account-Bootstrap": "ON",
    "Neko-Runtime-Billing-Transaction-Ingestion": "ON",
    "Neko-Runtime-Billing-Apple-Notification-Ingestion": "ON",
    "Neko-Runtime-Billing-Subscription-Reconciliation": "ON",
    "Neko-Runtime-Billing-Effective-Entitlement": "ON",
    "Neko-Runtime-Billing-Window-Sponsorship": "ON",
    "Neko-Runtime-Billing-Account-Recovery": "ON",
    "Neko-Runtime-Billing-Apple-Notification-History-Recovery":
      effectiveHistory,
  });
  return new Response(JSON.stringify({ status: "ok", protocolVersion: 1 }), {
    status: 200,
    headers,
  });
}

function readerFor(input) {
  return async (path) => path.endsWith(historyStagingControlManifestName)
    ? JSON.stringify(input)
    : path.endsWith(historyStagingControlConfigName)
      ? config
      : Promise.reject(new Error("unexpected file"));
}

test("accepts only an exact fixed manifest and exposes no ON command", () => {
  assert.deepEqual(validateHistoryStagingControlManifest(manifest), manifest);
  for (const invalid of [
    { ...manifest, extra: true },
    { ...manifest, origin: "https://another.example" },
    { ...manifest, expectedGeneration: -1 },
    { ...manifest, expectedStoreEnvironment: null },
    {
      ...manifest,
      expectedGates: { ...manifest.expectedGates, unknown_gate: 0 },
    },
    {
      ...manifest,
      expectedGates: {
        ...manifest.expectedGates,
        apple_notification_history_recovery_enabled: 2,
      },
    },
  ]) {
    assert.throws(
      () => validateHistoryStagingControlManifest(invalid),
      /manifest/u,
    );
  }
  assert.deepEqual(parseHistoryStagingControlArguments(["--plan"]), {
    action: "plan",
  });
  assert.deepEqual(parseHistoryStagingControlArguments(["--status"]), {
    action: "status",
  });
  assert.deepEqual(
    parseHistoryStagingControlArguments(["--confirm-history-emergency-off"]),
    { action: "emergency-off" },
  );
  assert.throws(
    () => parseHistoryStagingControlArguments(["--confirm-history-on"]),
    /use exactly/u,
  );
});

test("emergency SQL changes only History with exact generation and eight-gate CAS", () => {
  const sql = historyEmergencyOffSQL(manifest);
  assert.match(sql, /SET generation = generation \+ 1,/u);
  assert.match(sql, /apple_notification_history_recovery_enabled = 0,/u);
  for (const key of historyBillingGateKeys) {
    assert.match(sql, new RegExp(`AND ${key} = 1`, "u"));
  }
  for (const key of historyBillingGateKeys.filter((key) => (
    key !== "apple_notification_history_recovery_enabled"
  ))) {
    assert.doesNotMatch(sql, new RegExp(`SET[\\s\\S]*${key} = 0`, "u"));
  }
  const alreadyOff = {
    ...manifest,
    expectedGates: {
      ...manifest.expectedGates,
      apple_notification_history_recovery_enabled: 0,
    },
  };
  assert.throws(
    () => historyEmergencyOffSQL(alreadyOff),
    /requires a reviewed lower gate that is ON/u,
  );

  const isolated = {
    ...manifest,
    expectedGates: Object.fromEntries(historyBillingGateKeys.map((key) => [
      key,
      key === "apple_notification_history_recovery_enabled" ? 1 : 0,
    ])),
  };
  const isolatedSQL = historyEmergencyOffSQL(isolated);
  for (const key of historyBillingGateKeys.filter((key) => (
    key !== "apple_notification_history_recovery_enabled"
  ))) {
    assert.match(isolatedSQL, new RegExp(`AND ${key} = 0`, "u"));
  }
});

test("commands bind one fixed remote D1 and disable auto-provision", () => {
  for (const command of [
    historyStagingStatusCommand("/safe/project", manifest),
    historyEmergencyOffCommand("/safe/project", manifest),
  ]) {
    assert.equal(command.accountId, manifest.accountId);
    assert.ok(command.args.includes("--remote"));
    assert.ok(command.args.includes("--experimental-provision=false"));
    assert.ok(command.args.includes("--experimental-auto-create=false"));
    assert.ok(command.args.some((value) => (
      value.endsWith(historyStagingControlConfigName)
    )));
  }
  const statusSQL = historyStagingStatusCommand(
    "/safe/project",
    manifest,
  ).args.at(-1);
  assert.doesNotMatch(
    statusSQL,
    /pagination_cursor|lease_token|notification_uuid|payload_hash|raw_jws|signed_payload/iu,
  );
});

test("status and emergency parsers require exact safe rows", () => {
  assert.equal(
    parseHistoryStagingStatus(wranglerOutput(statusRow(), 0), manifest)
      .history_recovery_state,
    "retry_wait",
  );
  assert.equal(
    parseHistoryEmergencyOff(
      wranglerOutput(emergencyOffRow(), 1),
      manifest,
    ).apple_notification_history_recovery_enabled,
    0,
  );
  const leaked = { ...statusRow(), pagination_cursor: "must-not-appear" };
  assert.throws(
    () => parseHistoryStagingStatus(wranglerOutput(leaked, 0), manifest),
    /does not match/u,
  );
  const wrongIdentity = {
    ...statusRow(),
    store_environment: "Production",
  };
  assert.throws(
    () => parseHistoryStagingStatus(
      wranglerOutput(wrongIdentity, 0),
      manifest,
    ),
    /does not match/u,
  );
  assert.throws(
    () => parseHistoryEmergencyOff(wranglerOutput([], 0), manifest),
    /exactly one row/u,
  );
});

test("plan is local-only and status performs reads without a D1 update", async () => {
  let commands = 0;
  let fetches = 0;
  assert.match(await runHistoryStagingControl(["--plan"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(manifest),
    runCommand: async () => { commands += 1; throw new Error("unexpected"); },
    fetchImpl: async () => { fetches += 1; throw new Error("unexpected"); },
  }), /no D1 update, deployment, or network request/u);
  assert.equal(commands, 0);
  assert.equal(fetches, 0);

  const invokedSQL = [];
  const result = await runHistoryStagingControl(["--status"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(manifest),
    runCommand: async (command) => {
      if (command.args.at(-1) === "--version") return "4.125.0";
      invokedSQL.push(command.args.at(-1));
      return wranglerOutput(statusRow(), 0);
    },
    fetchImpl: async () => healthResponse(manifest.expectedGeneration),
  });
  assert.match(result, /read-only D1 and health checks only/u);
  assert.equal(invokedSQL.length, 1);
  assert.match(invokedSQL[0], /^SELECT/u);

  await assert.rejects(runHistoryStagingControl(["--status"], {
    projectDirectory: "/safe/project",
    readFileImpl: readerFor(manifest),
    runCommand: async (command) => command.args.at(-1) === "--version"
      ? "4.125.0"
      : wranglerOutput(statusRow(), 0),
    fetchImpl: async () => {
      const response = healthResponse(manifest.expectedGeneration);
      response.headers.set(
        "Neko-Runtime-Billing-Effective-Entitlement",
        "OFF",
      );
      return response;
    },
  }), /same-origin health verification failed/u);
});

test("emergency OFF performs one exact CAS and verifies effective OFF", async () => {
  const invokedSQL = [];
  const result = await runHistoryStagingControl(
    ["--confirm-history-emergency-off"],
    {
      projectDirectory: "/safe/project",
      readFileImpl: readerFor(manifest),
      runCommand: async (command) => {
        if (command.args.at(-1) === "--version") return "4.125.0";
        invokedSQL.push(command.args.at(-1));
        return wranglerOutput(emergencyOffRow(), 1);
      },
      fetchImpl: async () => healthResponse(manifest.expectedGeneration + 1),
    },
  );
  assert.match(result, /lower gate emergency OFF/u);
  assert.match(result, /No deploy or ON operation/u);
  assert.equal(invokedSQL.length, 1);
  assert.match(invokedSQL[0], /^UPDATE billing_runtime_gate/u);

  await assert.rejects(runHistoryStagingControl(
    ["--confirm-history-emergency-off"],
    {
      projectDirectory: "/safe/project",
      readFileImpl: readerFor(manifest),
      runCommand: async (command) => command.args.at(-1) === "--version"
        ? "4.125.0"
        : wranglerOutput(emergencyOffRow(), 1),
      fetchImpl: async () => { throw new Error("health unavailable"); },
    },
  ), /CAS succeeded.*do not repeat/u);

  const identityDriftManifest = {
    ...manifest,
    expectedStoreEnvironment: "Production",
  };
  assert.match(await runHistoryStagingControl(
    ["--confirm-history-emergency-off"],
    {
      projectDirectory: "/safe/project",
      readFileImpl: readerFor(identityDriftManifest),
      runCommand: async (command) => command.args.at(-1) === "--version"
        ? "4.125.0"
        : wranglerOutput(emergencyOffRow(), 1),
      fetchImpl: async () => healthResponse(manifest.expectedGeneration + 1),
    },
  ), /lower gate emergency OFF/u);
});

test("ordinary billing controller continues to reject a History-ON state", () => {
  const ordinaryHistoryOn = {
    generation: 8,
    ...manifest.expectedGates,
  };
  assert.throws(
    () => parseBillingRuntimeGateStatus(
      wranglerOutput(ordinaryHistoryOn, 0),
    ),
    /unexpected row/u,
  );
});

test("keeps the dedicated manifest ignored", async () => {
  const ignore = await readFile(join(projectDirectory, ".gitignore"), "utf8");
  assert.match(
    ignore,
    /^billing-notification-history-staging-manifest\.json$/mu,
  );
});

test("package scripts expose only plan, status, and emergency OFF", async () => {
  const packageJSON = JSON.parse(await readFile(
    join(projectDirectory, "package.json"),
    "utf8",
  ));
  const scripts = Object.entries(packageJSON.scripts).filter(([name]) => (
    name.startsWith("billing-notification-history-staging:")
  ));
  assert.deepEqual(scripts.map(([name]) => name).sort(), [
    "billing-notification-history-staging:emergency-off",
    "billing-notification-history-staging:plan",
    "billing-notification-history-staging:status",
  ]);
  assert.doesNotMatch(JSON.stringify(scripts), /deploy|confirm-history-on/iu);
});
