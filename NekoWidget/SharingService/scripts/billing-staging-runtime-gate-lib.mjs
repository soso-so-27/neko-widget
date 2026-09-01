import process from "node:process";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

import { runRuntimeGateCommand } from "./personal-staging-runtime-gate-lib.mjs";
import { validateStagingConfig } from "./staging-config-lib.mjs";
import { normalizePublicHttpsOrigin } from "./staging-runtime-check-lib.mjs";

export const billingRuntimeGateConfigName =
  "wrangler.billing-control-staging-on.jsonc";
export const billingRuntimeGateManifestName =
  "billing-staging-runtime-gate-manifest.json";

const databaseName = "neko-window-sharing-staging";
const workerName = "neko-window-sharing-staging";
const expectedOrigin =
  "https://neko-window-sharing-staging.nakanishisoya.workers.dev";
const wranglerVersion = "4.125.0";
const exactManifestKeys = Object.freeze([
  "accountId",
  "databaseId",
  "desiredState",
  "expectedGeneration",
  "expectedState",
  "origin",
  "schemaVersion",
  "workerName",
]);

const activationOrder = Object.freeze([
  "account_bootstrap_enabled",
  "transaction_ingestion_enabled",
  "apple_notification_ingestion_enabled",
  "subscription_reconciliation_enabled",
  "effective_entitlement_enabled",
  "window_sponsorship_enabled",
  "account_recovery_enabled",
  // Observed and forced OFF by every ordinary billing-control state. A
  // separate reviewed History drill is required before this bit may be ON.
  "apple_notification_history_recovery_enabled",
]);
const stateNames = Object.freeze([
  "all-off",
  "bootstrap-only",
  "transaction-on",
  "notification-on",
  "reconciliation-on",
  "entitlement-on",
  "sponsorship-on",
  "recovery-on",
]);

function makeState(enabledCount) {
  return Object.freeze(Object.fromEntries(
    activationOrder.map((key, index) => [key, index < enabledCount ? 1 : 0]),
  ));
}

export const billingRuntimeGateStates = Object.freeze(Object.fromEntries(
  stateNames.map((name, index) => [name, makeState(index)]),
));

const healthHeaders = Object.freeze({
  account_bootstrap_enabled: "neko-runtime-billing-account-bootstrap",
  transaction_ingestion_enabled: "neko-runtime-billing-transaction-ingestion",
  apple_notification_ingestion_enabled:
    "neko-runtime-billing-apple-notification-ingestion",
  subscription_reconciliation_enabled:
    "neko-runtime-billing-subscription-reconciliation",
  effective_entitlement_enabled: "neko-runtime-billing-effective-entitlement",
  window_sponsorship_enabled: "neko-runtime-billing-window-sponsorship",
  account_recovery_enabled: "neko-runtime-billing-account-recovery",
  apple_notification_history_recovery_enabled:
    "neko-runtime-billing-apple-notification-history-recovery",
});

const statusSQL = `SELECT generation,
       ${activationOrder.join(", ")}
  FROM billing_runtime_gate
 WHERE singleton = 1`;

function plain(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, keys) {
  return plain(value)
    && JSON.stringify(Object.keys(value).sort())
      === JSON.stringify([...keys].sort());
}

function exactState(row, expected) {
  return activationOrder.every((key) => row[key] === expected[key]);
}

function stateName(row) {
  return stateNames.find(
    (name) => exactState(row, billingRuntimeGateStates[name]),
  );
}

function validateAdjacentTransition(expectedState, desiredState) {
  const distance = Math.abs(stateNames.indexOf(expectedState)
    - stateNames.indexOf(desiredState));
  const emergencyAllOff = desiredState === "all-off" && distance > 1;
  if (distance !== 1 && !emergencyAllOff) {
    throw new Error(
      "billing runtime gate transition must be adjacent or emergency billing-all-off",
    );
  }
}

function isEmergencyAllOff(manifest) {
  return manifest.desiredState === "all-off"
    && stateNames.indexOf(manifest.expectedState) > 1;
}

export function validateBillingRuntimeGateManifest(input) {
  if (!exactKeys(input, exactManifestKeys)
      || input.schemaVersion !== 1
      || typeof input.accountId !== "string"
      || !/^[0-9a-f]{32}$/u.test(input.accountId)
      || typeof input.databaseId !== "string"
      || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/u
        .test(input.databaseId)
      || input.workerName !== workerName
      || !Object.hasOwn(billingRuntimeGateStates, input.expectedState)
      || !Object.hasOwn(billingRuntimeGateStates, input.desiredState)
      || !Number.isSafeInteger(input.expectedGeneration)
      || input.expectedGeneration < 0
      || input.expectedGeneration > 2_147_483_646) {
    throw new Error(
      "billing staging runtime gate manifest is unavailable or invalid",
    );
  }
  validateAdjacentTransition(input.expectedState, input.desiredState);
  const origin = normalizePublicHttpsOrigin(input.origin);
  if (origin !== expectedOrigin) {
    throw new Error(
      "billing staging runtime gate manifest is unavailable or invalid",
    );
  }
  return Object.freeze({
    schemaVersion: 1,
    accountId: input.accountId,
    databaseId: input.databaseId,
    workerName,
    origin,
    expectedGeneration: input.expectedGeneration,
    expectedState: input.expectedState,
    desiredState: input.desiredState,
  });
}

function validateFixedConfig(config, manifest) {
  validateStagingConfig(config, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
    expectedBillingRuntimeProfile: "billing-control-on",
  });
  const binding = config.d1_databases[0];
  if (config.name !== workerName
      || binding?.database_name !== databaseName
      || binding?.database_id !== manifest.databaseId) {
    throw new Error(
      "billing staging runtime gate target does not match the fixed config",
    );
  }
}

export function billingRuntimeGateUpdateSQL(manifestInput) {
  const manifest = validateBillingRuntimeGateManifest(manifestInput);
  const expected = billingRuntimeGateStates[manifest.expectedState];
  const desired = billingRuntimeGateStates[manifest.desiredState];
  const assignments = activationOrder
    .map((key) => `    ${key} = ${desired[key]}`)
    .join(",\n");
  const expectedPredicates = activationOrder
    .map((key) => `  AND ${key} = ${expected[key]}`)
    .join("\n");
  return `UPDATE billing_runtime_gate
SET generation = generation + 1,
${assignments},
    updated_at = unixepoch()
WHERE singleton = 1 AND generation = ${manifest.expectedGeneration}
${expectedPredicates}
RETURNING generation, ${activationOrder.join(", ")}, updated_at`;
}

function wranglerEntry(projectDirectory) {
  return join(projectDirectory, "node_modules", "wrangler", "bin", "wrangler.js");
}

function d1Command(projectDirectory, manifest, sql) {
  return Object.freeze({
    executable: process.execPath,
    args: Object.freeze([
      wranglerEntry(projectDirectory),
      "d1",
      "execute",
      databaseName,
      "--remote",
      "--json",
      "--config",
      join(projectDirectory, billingRuntimeGateConfigName),
      "--experimental-provision=false",
      "--experimental-auto-create=false",
      "--command",
      sql,
    ]),
    cwd: projectDirectory,
    accountId: manifest.accountId,
  });
}

export function billingRuntimeGateCommand(projectDirectory, manifestInput) {
  const manifest = validateBillingRuntimeGateManifest(manifestInput);
  return d1Command(
    projectDirectory,
    manifest,
    billingRuntimeGateUpdateSQL(manifest),
  );
}

export function billingRuntimeGateStatusCommand(
  projectDirectory,
  manifestInput,
) {
  const manifest = validateBillingRuntimeGateManifest(manifestInput);
  return d1Command(projectDirectory, manifest, statusSQL);
}

function expectedResult(manifest) {
  return Object.freeze({
    generation: manifest.expectedGeneration + 1,
    ...billingRuntimeGateStates[manifest.desiredState],
  });
}

function parseWranglerOutput(output, label) {
  let parsed;
  try {
    parsed = JSON.parse(output);
  } catch {
    throw new Error(`${label} returned invalid JSON`);
  }
  if (!Array.isArray(parsed) || parsed.length !== 1 || !plain(parsed[0])) {
    throw new Error(`${label} returned an unexpected envelope`);
  }
  return parsed[0];
}

export function parseBillingRuntimeGateUpdate(output, manifestInput) {
  const manifest = validateBillingRuntimeGateManifest(manifestInput);
  const result = parseWranglerOutput(output, "billing runtime gate D1 update");
  if (result.success !== true
      || result.meta?.changes !== 1
      || !Array.isArray(result.results)
      || result.results.length !== 1) {
    throw new Error("billing runtime gate CAS did not change exactly one row");
  }
  const row = result.results[0];
  if (!exactKeys(row, ["generation", ...activationOrder, "updated_at"])
      || !Number.isSafeInteger(row.updated_at)
      || row.updated_at < 0) {
    throw new Error("billing runtime gate CAS returned an unexpected row");
  }
  const expected = expectedResult(manifest);
  if (row.generation !== expected.generation || !exactState(row, expected)) {
    throw new Error("billing runtime gate CAS returned an unexpected row");
  }
  return Object.freeze({ ...expected, updated_at: row.updated_at });
}

export function parseBillingRuntimeGateStatus(output) {
  const result = parseWranglerOutput(output, "billing runtime gate D1 status");
  if (result.success !== true
      || result.meta?.changes !== 0
      || !Array.isArray(result.results)
      || result.results.length !== 1) {
    throw new Error(
      "billing runtime gate D1 status did not return exactly one read-only row",
    );
  }
  const row = result.results[0];
  if (!exactKeys(row, ["generation", ...activationOrder])
      || !Number.isSafeInteger(row.generation)
      || row.generation < 0
      || !activationOrder.every((key) => row[key] === 0 || row[key] === 1)
      || stateName(row) === undefined) {
    throw new Error("billing runtime gate D1 status returned an unexpected row");
  }
  return Object.freeze({
    generation: row.generation,
    ...Object.fromEntries(activationOrder.map((key) => [key, row[key]])),
  });
}

async function verifyOriginState(
  manifest,
  expected,
  fetchImpl,
  timeoutMilliseconds,
) {
  if (!Number.isSafeInteger(timeoutMilliseconds)
      || timeoutMilliseconds < 1
      || timeoutMilliseconds > 30_000) {
    throw new Error("billing runtime gate verification timeout is invalid");
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMilliseconds);
  let response;
  try {
    response = await fetchImpl(`${manifest.origin}/health`, {
      headers: { Accept: "application/json" },
      cache: "no-store",
      redirect: "manual",
      signal: controller.signal,
    });
  } catch {
    throw new Error(
      "billing same-origin verification failed; the D1 generation change may already be applied",
    );
  } finally {
    clearTimeout(timer);
  }
  if (response.status !== 200
      || response.headers.get("content-type")?.toLowerCase()
        .startsWith("application/json") !== true
      || response.headers.get("neko-runtime-billing-gate-generation")
        !== String(expected.generation)) {
    throw new Error("billing same-origin runtime gate verification failed");
  }
  if (response.headers.get("neko-runtime-billing-apple-notification-rate-limiter")
      !== "READY") {
    throw new Error("billing same-origin runtime gate verification failed");
  }
  for (const key of activationOrder) {
    if (response.headers.get(healthHeaders[key])
        !== (expected[key] === 1 ? "ON" : "OFF")) {
      throw new Error("billing same-origin runtime gate verification failed");
    }
  }
  let body;
  try {
    body = await response.json();
  } catch {
    throw new Error("billing same-origin runtime gate verification failed");
  }
  if (!exactKeys(body, ["protocolVersion", "status"])
      || body.status !== "ok"
      || body.protocolVersion !== 1) {
    throw new Error("billing same-origin runtime gate verification failed");
  }
}

export async function verifyBillingRuntimeGateOrigin(
  manifestInput,
  fetchImpl = fetch,
  { timeoutMilliseconds = 15_000 } = {},
) {
  const manifest = validateBillingRuntimeGateManifest(manifestInput);
  await verifyOriginState(
    manifest,
    expectedResult(manifest),
    fetchImpl,
    timeoutMilliseconds,
  );
}

export function parseBillingRuntimeGateArguments(argv) {
  const message = "use exactly --plan, --status, --confirm-<reviewed-state>, or --confirm-billing-all-off";
  if (!Array.isArray(argv) || argv.length !== 1) throw new Error(message);
  if (argv[0] === "--plan") {
    return Object.freeze({ action: "plan", confirmation: null });
  }
  if (argv[0] === "--status") {
    return Object.freeze({ action: "status", confirmation: null });
  }
  const prefix = "--confirm-";
  if (!argv[0].startsWith(prefix)) throw new Error(message);
  const confirmation = argv[0].slice(prefix.length);
  if (confirmation !== "billing-all-off"
      && !Object.hasOwn(billingRuntimeGateStates, confirmation)) {
    throw new Error(message);
  }
  return Object.freeze({ action: "confirm", confirmation });
}

function versionCommand(projectDirectory, manifest) {
  return Object.freeze({
    executable: process.execPath,
    args: Object.freeze([wranglerEntry(projectDirectory), "--version"]),
    cwd: projectDirectory,
    accountId: manifest.accountId,
  });
}

export async function runBillingRuntimeGateControl(argv, {
  projectDirectory,
  readFileImpl = readFile,
  runCommand = runRuntimeGateCommand,
  fetchImpl = fetch,
} = {}) {
  const mode = parseBillingRuntimeGateArguments(argv);
  let manifest;
  let config;
  try {
    manifest = validateBillingRuntimeGateManifest(JSON.parse(
      await readFileImpl(
        join(projectDirectory, billingRuntimeGateManifestName),
        "utf8",
      ),
    ));
    config = JSON.parse(await readFileImpl(
      join(projectDirectory, billingRuntimeGateConfigName),
      "utf8",
    ));
  } catch (error) {
    if (error instanceof Error && error.message.includes("manifest")) {
      throw error;
    }
    throw new Error(
      "billing staging runtime gate files are unavailable or invalid",
    );
  }
  validateFixedConfig(config, manifest);
  if (mode.action === "plan") {
    const transition = isEmergencyAllOff(manifest)
      ? "emergency billing-all-off"
      : "adjacent";
    return `PASS billing runtime gate ${transition} plan validated; no D1 update or network request was performed.`;
  }
  if (mode.action === "confirm") {
    const requiredConfirmation = isEmergencyAllOff(manifest)
      ? "billing-all-off"
      : manifest.desiredState;
    if (mode.confirmation !== requiredConfirmation) {
      throw new Error(
        "billing runtime gate confirmation does not match the reviewed manifest",
      );
    }
  }
  if (!new RegExp(`\\b${wranglerVersion.replaceAll(".", "\\.")}\\b`, "u")
    .test(await runCommand(versionCommand(projectDirectory, manifest)))) {
    throw new Error(`reviewed Wrangler ${wranglerVersion} is required`);
  }
  if (mode.action === "status") {
    const snapshot = parseBillingRuntimeGateStatus(
      await runCommand(
        billingRuntimeGateStatusCommand(projectDirectory, manifest),
      ),
    );
    await verifyOriginState(manifest, snapshot, fetchImpl, 15_000);
    if (snapshot.generation !== manifest.expectedGeneration
        || !exactState(
          snapshot,
          billingRuntimeGateStates[manifest.expectedState],
        )) {
      throw new Error(
        "billing runtime gate manifest does not match the live generation and state",
      );
    }
    return `PASS billing runtime gate status generation ${snapshot.generation} ${manifest.expectedState}; manifest reconciled for adjacent ${manifest.desiredState}.`;
  }
  const output = await runCommand(
    billingRuntimeGateCommand(projectDirectory, manifest),
  );
  parseBillingRuntimeGateUpdate(output, manifest);
  await verifyBillingRuntimeGateOrigin(manifest, fetchImpl);
  const transition = isEmergencyAllOff(manifest)
    ? "emergency billing-all-off"
    : `${manifest.expectedState} -> ${manifest.desiredState}`;
  return `PASS billing runtime gate ${transition} generation ${manifest.expectedGeneration + 1} verified.`;
}
