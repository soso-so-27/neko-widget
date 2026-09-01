import process from "node:process";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

import { runRuntimeGateCommand } from "./personal-staging-runtime-gate-lib.mjs";
import { validateStagingConfig } from "./staging-config-lib.mjs";
import { normalizePublicHttpsOrigin } from "./staging-runtime-check-lib.mjs";

export const historyStagingControlConfigName =
  "wrangler.billing-control-staging-on.jsonc";
export const historyStagingControlManifestName =
  "billing-notification-history-staging-manifest.json";

const databaseName = "neko-window-sharing-staging";
const workerName = "neko-window-sharing-staging";
const expectedOrigin =
  "https://neko-window-sharing-staging.nakanishisoya.workers.dev";
const wranglerVersion = "4.125.0";

export const historyBillingGateKeys = Object.freeze([
  "account_bootstrap_enabled",
  "transaction_ingestion_enabled",
  "apple_notification_ingestion_enabled",
  "subscription_reconciliation_enabled",
  "effective_entitlement_enabled",
  "window_sponsorship_enabled",
  "account_recovery_enabled",
  "apple_notification_history_recovery_enabled",
]);

const historyGateKey = "apple_notification_history_recovery_enabled";
const exactManifestKeys = Object.freeze([
  "accountId",
  "databaseId",
  "expectedBundleId",
  "expectedGates",
  "expectedGeneration",
  "expectedStoreEnvironment",
  "origin",
  "schemaVersion",
  "workerName",
]);
const recoveryStates = new Set([
  "idle",
  "ready",
  "leased",
  "retry_wait",
  "completed",
  "blocked",
]);
const safeErrorCodePattern = /^[a-z0-9_]{1,64}$/u;
const bundleIdPattern = /^(?=.{3,255}$)(?=.*\.)[A-Za-z0-9.-]+$/u;
const healthHeaders = Object.freeze({
  account_bootstrap_enabled: "neko-runtime-billing-account-bootstrap",
  transaction_ingestion_enabled: "neko-runtime-billing-transaction-ingestion",
  apple_notification_ingestion_enabled:
    "neko-runtime-billing-apple-notification-ingestion",
  subscription_reconciliation_enabled:
    "neko-runtime-billing-subscription-reconciliation",
  effective_entitlement_enabled:
    "neko-runtime-billing-effective-entitlement",
  window_sponsorship_enabled: "neko-runtime-billing-window-sponsorship",
  account_recovery_enabled: "neko-runtime-billing-account-recovery",
  apple_notification_history_recovery_enabled:
    "neko-runtime-billing-apple-notification-history-recovery",
});

function plain(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, keys) {
  return plain(value)
    && JSON.stringify(Object.keys(value).sort())
      === JSON.stringify([...keys].sort());
}

function exactGateState(row, expectedGates) {
  return historyBillingGateKeys.every(
    (key) => row[key] === expectedGates[key],
  );
}

function validExpectedGates(value) {
  return exactKeys(value, historyBillingGateKeys)
    && historyBillingGateKeys.every((key) => [0, 1].includes(value[key]));
}

export function validateHistoryStagingControlManifest(input) {
  const identityValid = (input.expectedStoreEnvironment === null
      && input.expectedBundleId === null)
    || (["Sandbox", "Production"].includes(input.expectedStoreEnvironment)
      && typeof input.expectedBundleId === "string"
      && bundleIdPattern.test(input.expectedBundleId));
  if (!exactKeys(input, exactManifestKeys)
      || input.schemaVersion !== 1
      || typeof input.accountId !== "string"
      || !/^[0-9a-f]{32}$/u.test(input.accountId)
      || typeof input.databaseId !== "string"
      || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/u
        .test(input.databaseId)
      || input.workerName !== workerName
      || !Number.isSafeInteger(input.expectedGeneration)
      || input.expectedGeneration < 0
      || input.expectedGeneration > 2_147_483_646
      || !validExpectedGates(input.expectedGates)
      || !identityValid) {
    throw new Error(
      "notification history staging control manifest is unavailable or invalid",
    );
  }
  const origin = normalizePublicHttpsOrigin(input.origin);
  if (origin !== expectedOrigin) {
    throw new Error(
      "notification history staging control manifest is unavailable or invalid",
    );
  }
  return Object.freeze({
    schemaVersion: 1,
    accountId: input.accountId,
    databaseId: input.databaseId,
    workerName,
    origin,
    expectedGeneration: input.expectedGeneration,
    expectedStoreEnvironment: input.expectedStoreEnvironment,
    expectedBundleId: input.expectedBundleId,
    expectedGates: Object.freeze({ ...input.expectedGates }),
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
      "notification history staging control target does not match the fixed config",
    );
  }
}

const safeStatusFields = Object.freeze([
  "billing_gate_generation",
  ...historyBillingGateKeys,
  "history_recovery_generation",
  "history_recovery_state",
  "store_environment",
  "bundle_id",
  "frozen_start_date_ms",
  "frozen_end_date_ms",
  "committed_page_count",
  "committed_record_count",
  "cursor_reset_count",
  "attempts",
  "not_before",
  "last_error_code",
]);

const safeStatusSQL = `SELECT gate.generation AS billing_gate_generation,
       ${historyBillingGateKeys.map((key) => `gate.${key}`).join(",\n       ")},
       recovery.generation AS history_recovery_generation,
       recovery.state AS history_recovery_state,
       recovery.store_environment,
       recovery.bundle_id,
       recovery.frozen_start_date_ms,
       recovery.frozen_end_date_ms,
       recovery.committed_page_count,
       recovery.committed_record_count,
       recovery.cursor_reset_count,
       recovery.attempts,
       recovery.not_before,
       recovery.last_error_code
  FROM billing_runtime_gate AS gate
 CROSS JOIN billing_apple_notification_history_recovery AS recovery
 WHERE gate.singleton = 1 AND recovery.singleton = 1`;

export function historyEmergencyOffSQL(manifestInput) {
  const manifest = validateHistoryStagingControlManifest(manifestInput);
  if (manifest.expectedGates[historyGateKey] !== 1) {
    throw new Error(
      "notification history emergency OFF requires a reviewed lower gate that is ON",
    );
  }
  const predicates = historyBillingGateKeys
    .map((key) => `  AND ${key} = ${manifest.expectedGates[key]}`)
    .join("\n");
  return `UPDATE billing_runtime_gate
SET generation = generation + 1,
    ${historyGateKey} = 0,
    updated_at = unixepoch()
WHERE singleton = 1 AND generation = ${manifest.expectedGeneration}
${predicates}
RETURNING generation AS billing_gate_generation,
          ${historyBillingGateKeys.join(", ")}`;
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
      join(projectDirectory, historyStagingControlConfigName),
      "--experimental-provision=false",
      "--experimental-auto-create=false",
      "--command",
      sql,
    ]),
    cwd: projectDirectory,
    accountId: manifest.accountId,
  });
}

export function historyStagingStatusCommand(projectDirectory, manifestInput) {
  const manifest = validateHistoryStagingControlManifest(manifestInput);
  return d1Command(projectDirectory, manifest, safeStatusSQL);
}

export function historyEmergencyOffCommand(projectDirectory, manifestInput) {
  const manifest = validateHistoryStagingControlManifest(manifestInput);
  return d1Command(
    projectDirectory,
    manifest,
    historyEmergencyOffSQL(manifest),
  );
}

function parseWranglerOutput(output, label) {
  let parsed;
  try {
    parsed = JSON.parse(output);
  } catch {
    throw new Error(`${label} returned invalid JSON`);
  }
  if (!Array.isArray(parsed) || parsed.length !== 1 || !plain(parsed[0])
      || parsed[0].success !== true || !plain(parsed[0].meta)
      || !Array.isArray(parsed[0].results)) {
    throw new Error(`${label} returned an invalid envelope`);
  }
  return parsed[0];
}

function validNullablePositiveInteger(value) {
  return value === null || (Number.isSafeInteger(value) && value > 0);
}

function validRecoveryStatusRow(row) {
  const start = row.frozen_start_date_ms;
  const end = row.frozen_end_date_ms;
  const intervalValid = (start === null && end === null)
    || (Number.isSafeInteger(start) && start > 0
      && Number.isSafeInteger(end) && end > start);
  const identityValid = (row.store_environment === null && row.bundle_id === null)
    || (["Sandbox", "Production"].includes(row.store_environment)
      && typeof row.bundle_id === "string"
      && bundleIdPattern.test(row.bundle_id));
  return exactKeys(row, safeStatusFields)
    && Number.isSafeInteger(row.billing_gate_generation)
    && row.billing_gate_generation >= 0
    && historyBillingGateKeys.every((key) => [0, 1].includes(row[key]))
    && Number.isSafeInteger(row.history_recovery_generation)
    && row.history_recovery_generation >= 0
    && recoveryStates.has(row.history_recovery_state)
    && identityValid
    && intervalValid
    && Number.isSafeInteger(row.committed_page_count)
    && row.committed_page_count >= 0
    && Number.isSafeInteger(row.committed_record_count)
    && row.committed_record_count >= 0
    && Number.isSafeInteger(row.cursor_reset_count)
    && row.cursor_reset_count >= 0
    && Number.isSafeInteger(row.attempts)
    && row.attempts >= 0
    && Number.isSafeInteger(row.not_before)
    && row.not_before >= 0
    && (row.last_error_code === null
      || (typeof row.last_error_code === "string"
        && safeErrorCodePattern.test(row.last_error_code)))
    && validNullablePositiveInteger(start)
    && validNullablePositiveInteger(end);
}

export function parseHistoryStagingStatus(output, manifestInput) {
  const manifest = validateHistoryStagingControlManifest(manifestInput);
  const result = parseWranglerOutput(
    output,
    "notification history staging status",
  );
  if (result.meta.changes !== 0 || result.results.length !== 1) {
    throw new Error(
      "notification history staging status did not return exactly one read-only row",
    );
  }
  const row = result.results[0];
  if (!validRecoveryStatusRow(row)
      || row.billing_gate_generation !== manifest.expectedGeneration
      || row.store_environment !== manifest.expectedStoreEnvironment
      || row.bundle_id !== manifest.expectedBundleId
      || !exactGateState(row, manifest.expectedGates)) {
    throw new Error(
      "notification history staging status does not match the reviewed manifest",
    );
  }
  return Object.freeze({
    ...row,
    expectedGates: Object.freeze({ ...manifest.expectedGates }),
  });
}

export function parseHistoryEmergencyOff(output, manifestInput) {
  const manifest = validateHistoryStagingControlManifest(manifestInput);
  if (manifest.expectedGates[historyGateKey] !== 1) {
    throw new Error(
      "notification history emergency OFF requires a reviewed lower gate that is ON",
    );
  }
  const result = parseWranglerOutput(
    output,
    "notification history emergency OFF",
  );
  if (result.meta.changes !== 1 || result.results.length !== 1) {
    throw new Error(
      "notification history emergency OFF CAS did not change exactly one row",
    );
  }
  const row = result.results[0];
  const keys = ["billing_gate_generation", ...historyBillingGateKeys];
  if (!exactKeys(row, keys)
      || row.billing_gate_generation !== manifest.expectedGeneration + 1
      || historyBillingGateKeys.some((key) => row[key] !== (
        key === historyGateKey ? 0 : manifest.expectedGates[key]
      ))) {
    throw new Error(
      "notification history emergency OFF CAS returned an unexpected row",
    );
  }
  return Object.freeze({ ...row });
}

function versionCommand(projectDirectory, manifest) {
  return Object.freeze({
    executable: process.execPath,
    args: Object.freeze([wranglerEntry(projectDirectory), "--version"]),
    cwd: projectDirectory,
    accountId: manifest.accountId,
  });
}

async function verifyOrigin(
  manifest,
  expectedGeneration,
  lowerHistoryGate,
  fetchImpl,
  timeoutMilliseconds = 15_000,
) {
  if (!Number.isSafeInteger(timeoutMilliseconds)
      || timeoutMilliseconds < 1 || timeoutMilliseconds > 30_000) {
    throw new Error("notification history health timeout is invalid");
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
      "notification history same-origin health verification failed",
    );
  } finally {
    clearTimeout(timer);
  }
  const effectiveHistory = response.headers.get(
    "neko-runtime-billing-apple-notification-history-recovery",
  );
  if (response.status !== 200
      || response.headers.get("content-type")?.toLowerCase()
        .startsWith("application/json") !== true
      || response.headers.get("neko-runtime-billing-gate-generation")
        !== String(expectedGeneration)
      || !["ON", "OFF"].includes(effectiveHistory ?? "")
      || (lowerHistoryGate === 0 && effectiveHistory !== "OFF")) {
    throw new Error(
      "notification history same-origin health verification failed",
    );
  }
  for (const key of historyBillingGateKeys) {
    const header = healthHeaders[key];
    const actual = header === undefined ? null : response.headers.get(header);
    const expected = manifest.expectedGates[key] === 1 ? "ON" : "OFF";
    if (header === undefined || !["ON", "OFF"].includes(actual ?? "")
        || (key !== historyGateKey && actual !== expected)) {
      throw new Error(
        "notification history same-origin health verification failed",
      );
    }
  }
  let body;
  try {
    body = await response.json();
  } catch {
    throw new Error(
      "notification history same-origin health verification failed",
    );
  }
  if (!exactKeys(body, ["protocolVersion", "status"])
      || body.protocolVersion !== 1 || body.status !== "ok") {
    throw new Error(
      "notification history same-origin health verification failed",
    );
  }
  return effectiveHistory;
}

export function parseHistoryStagingControlArguments(argv) {
  if (!Array.isArray(argv) || argv.length !== 1) {
    throw new Error(
      "use exactly --plan, --status, or --confirm-history-emergency-off",
    );
  }
  if (argv[0] === "--plan") return Object.freeze({ action: "plan" });
  if (argv[0] === "--status") return Object.freeze({ action: "status" });
  if (argv[0] === "--confirm-history-emergency-off") {
    return Object.freeze({ action: "emergency-off" });
  }
  throw new Error(
    "use exactly --plan, --status, or --confirm-history-emergency-off",
  );
}

export async function runHistoryStagingControl(argv, {
  projectDirectory,
  readFileImpl = readFile,
  runCommand = runRuntimeGateCommand,
  fetchImpl = fetch,
} = {}) {
  const mode = parseHistoryStagingControlArguments(argv);
  let manifest;
  let config;
  try {
    manifest = validateHistoryStagingControlManifest(JSON.parse(
      await readFileImpl(
        join(projectDirectory, historyStagingControlManifestName),
        "utf8",
      ),
    ));
    config = JSON.parse(await readFileImpl(
      join(projectDirectory, historyStagingControlConfigName),
      "utf8",
    ));
  } catch (error) {
    if (error instanceof Error && error.message.includes("manifest")) {
      throw error;
    }
    throw new Error(
      "notification history staging control files are unavailable or invalid",
    );
  }
  validateFixedConfig(config, manifest);

  if (mode.action === "plan") {
    return "PASS notification history staging plan validated; no D1 update, deployment, or network request was performed. No ON operation exists.";
  }

  if (!new RegExp(`\\b${wranglerVersion.replaceAll(".", "\\.")}\\b`, "u")
    .test(await runCommand(versionCommand(projectDirectory, manifest)))) {
    throw new Error(`reviewed Wrangler ${wranglerVersion} is required`);
  }

  if (mode.action === "status") {
    const snapshot = parseHistoryStagingStatus(
      await runCommand(historyStagingStatusCommand(projectDirectory, manifest)),
      manifest,
    );
    const effective = await verifyOrigin(
      manifest,
      snapshot.billing_gate_generation,
      snapshot[historyGateKey],
      fetchImpl,
    );
    const window = snapshot.frozen_start_date_ms === null
      ? "none"
      : `${snapshot.frozen_start_date_ms}-${snapshot.frozen_end_date_ms}`;
    const lastError = snapshot.last_error_code ?? "none";
    const identity = snapshot.store_environment === null
      ? "none"
      : `${snapshot.store_environment}/${snapshot.bundle_id}`;
    return `PASS notification history staging status gate-generation=${snapshot.billing_gate_generation} lower=${snapshot[historyGateKey] ? "ON" : "OFF"} effective=${effective} identity=${identity} recovery=${snapshot.history_recovery_state} recovery-generation=${snapshot.history_recovery_generation} window=${window} pages=${snapshot.committed_page_count} records=${snapshot.committed_record_count} attempts=${snapshot.attempts} cursor-resets=${snapshot.cursor_reset_count} last-error=${lastError}; read-only D1 and health checks only.`;
  }

  if (manifest.expectedGates[historyGateKey] !== 1) {
    throw new Error(
      "notification history emergency OFF requires a reviewed lower gate that is ON",
    );
  }
  parseHistoryEmergencyOff(
    await runCommand(historyEmergencyOffCommand(projectDirectory, manifest)),
    manifest,
  );
  try {
    await verifyOrigin(
      manifest,
      manifest.expectedGeneration + 1,
      0,
      fetchImpl,
    );
  } catch {
    throw new Error(
      "notification history lower OFF CAS succeeded but health verification failed; do not repeat the update, review status with the new generation",
    );
  }
  return `PASS notification history lower gate emergency OFF generation ${manifest.expectedGeneration + 1} verified. No deploy or ON operation was performed; return the active Worker and verifier upper switches to OFF separately.`;
}
