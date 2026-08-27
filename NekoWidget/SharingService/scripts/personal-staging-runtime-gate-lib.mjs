import { spawn } from "node:child_process";
import process from "node:process";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

import { validateStagingConfig } from "./staging-config-lib.mjs";
import { normalizePublicHttpsOrigin } from "./staging-runtime-check-lib.mjs";

export const runtimeGateConfigName = "wrangler.general-staging-on.jsonc";
export const runtimeGateManifestName = "personal-staging-runtime-gate-manifest.json";
const databaseName = "neko-window-sharing-staging";
const workerName = "neko-window-sharing-staging";
const wranglerVersion = "4.125.0";
const exactManifestKeys = Object.freeze([
  "accountId", "databaseId", "desiredState", "expectedGeneration",
  "origin", "schemaVersion", "workerName",
]);
const states = Object.freeze({
  "build70-media-apns-on": Object.freeze({ media: 1, apns: 1, report: 0 }),
  "broad-off": Object.freeze({ media: 0, apns: 0, report: 0 }),
});
const statusSQL = `SELECT generation, media_enabled, apns_enabled,
       report_ingestion_enabled
  FROM personal_staging_runtime_gate
 WHERE singleton = 1`;

function plain(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, keys) {
  return plain(value)
    && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
}

export function validateRuntimeGateManifest(input) {
  if (!exactKeys(input, exactManifestKeys)
      || input.schemaVersion !== 1
      || typeof input.accountId !== "string"
      || !/^[0-9a-f]{32}$/u.test(input.accountId)
      || typeof input.databaseId !== "string"
      || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/u.test(input.databaseId)
      || input.workerName !== workerName
      || !Object.hasOwn(states, input.desiredState)
      || !Number.isSafeInteger(input.expectedGeneration)
      || input.expectedGeneration < 0
      || input.expectedGeneration > 2_147_483_646) {
    throw new Error("personal staging runtime gate manifest is unavailable or invalid");
  }
  return Object.freeze({
    schemaVersion: 1,
    accountId: input.accountId,
    databaseId: input.databaseId,
    workerName,
    origin: normalizePublicHttpsOrigin(input.origin),
    expectedGeneration: input.expectedGeneration,
    desiredState: input.desiredState,
  });
}

function validateFixedConfig(config, manifest) {
  validateStagingConfig(config, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
  });
  const binding = config.d1_databases[0];
  if (config.name !== workerName
      || binding?.database_name !== databaseName
      || binding?.database_id !== manifest.databaseId) {
    throw new Error("personal staging runtime gate target does not match the fixed config");
  }
}

export function runtimeGateUpdateSQL(manifestInput) {
  const manifest = validateRuntimeGateManifest(manifestInput);
  const desired = states[manifest.desiredState];
  return `UPDATE personal_staging_runtime_gate
SET generation = generation + 1,
    media_enabled = ${desired.media},
    apns_enabled = ${desired.apns},
    report_ingestion_enabled = ${desired.report},
    updated_at = unixepoch()
WHERE singleton = 1 AND generation = ${manifest.expectedGeneration}
RETURNING generation, media_enabled, apns_enabled,
          report_ingestion_enabled, updated_at`;
}

export function runtimeGateCommand(projectDirectory, manifestInput) {
  const manifest = validateRuntimeGateManifest(manifestInput);
  const entry = join(projectDirectory, "node_modules", "wrangler", "bin", "wrangler.js");
  return Object.freeze({
    executable: process.execPath,
    args: Object.freeze([
      entry, "d1", "execute", databaseName, "--remote", "--json",
      "--config", join(projectDirectory, runtimeGateConfigName),
      "--command", runtimeGateUpdateSQL(manifest),
    ]),
    cwd: projectDirectory,
    accountId: manifest.accountId,
  });
}

export function runtimeGateStatusCommand(projectDirectory, manifestInput) {
  const manifest = validateRuntimeGateManifest(manifestInput);
  const entry = join(projectDirectory, "node_modules", "wrangler", "bin", "wrangler.js");
  return Object.freeze({
    executable: process.execPath,
    args: Object.freeze([
      entry, "d1", "execute", databaseName, "--remote", "--json",
      "--config", join(projectDirectory, runtimeGateConfigName),
      "--command", statusSQL,
    ]),
    cwd: projectDirectory,
    accountId: manifest.accountId,
  });
}

function expectedResult(manifest) {
  const desired = states[manifest.desiredState];
  return {
    generation: manifest.expectedGeneration + 1,
    media_enabled: desired.media,
    apns_enabled: desired.apns,
    report_ingestion_enabled: desired.report,
  };
}

export function parseRuntimeGateUpdate(output, manifestInput) {
  const manifest = validateRuntimeGateManifest(manifestInput);
  let parsed;
  try { parsed = JSON.parse(output); } catch {
    throw new Error("runtime gate D1 update returned invalid JSON");
  }
  if (!Array.isArray(parsed) || parsed.length !== 1 || !plain(parsed[0])
      || parsed[0].success !== true || parsed[0].meta?.changes !== 1
      || !Array.isArray(parsed[0].results) || parsed[0].results.length !== 1) {
    throw new Error("runtime gate CAS did not change exactly one row");
  }
  const row = parsed[0].results[0];
  if (!exactKeys(row, [
    "generation", "media_enabled", "apns_enabled",
    "report_ingestion_enabled", "updated_at",
  ]) || !Number.isSafeInteger(row.updated_at) || row.updated_at < 0) {
    throw new Error("runtime gate CAS returned an unexpected row");
  }
  const expected = expectedResult(manifest);
  for (const [key, value] of Object.entries(expected)) {
    if (row[key] !== value) throw new Error("runtime gate CAS returned an unexpected row");
  }
  return Object.freeze({ ...expected, updated_at: row.updated_at });
}

export function parseRuntimeGateStatus(output) {
  let parsed;
  try { parsed = JSON.parse(output); } catch {
    throw new Error("runtime gate D1 status returned invalid JSON");
  }
  if (!Array.isArray(parsed) || parsed.length !== 1 || !plain(parsed[0])
      || parsed[0].success !== true || parsed[0].meta?.changes !== 0
      || !Array.isArray(parsed[0].results) || parsed[0].results.length !== 1) {
    throw new Error("runtime gate D1 status did not return exactly one read-only row");
  }
  const row = parsed[0].results[0];
  if (!exactKeys(row, [
    "generation", "media_enabled", "apns_enabled", "report_ingestion_enabled",
  ]) || !Number.isSafeInteger(row.generation) || row.generation < 0
      || ![0, 1].includes(row.media_enabled)
      || ![0, 1].includes(row.apns_enabled)
      || row.report_ingestion_enabled !== 0
      || row.apns_enabled > row.media_enabled) {
    throw new Error("runtime gate D1 status returned an unexpected row");
  }
  return Object.freeze({
    generation: row.generation,
    media_enabled: row.media_enabled,
    apns_enabled: row.apns_enabled,
    report_ingestion_enabled: row.report_ingestion_enabled,
  });
}

async function verifyRuntimeGateOriginState(
  manifest,
  expected,
  fetchImpl,
  timeoutMilliseconds,
) {
  if (!Number.isSafeInteger(timeoutMilliseconds)
      || timeoutMilliseconds < 1 || timeoutMilliseconds > 30_000) {
    throw new Error("same-origin runtime gate verification timeout is invalid");
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
      "same-origin runtime gate verification failed; the D1 generation change may already be applied",
    );
  } finally {
    clearTimeout(timer);
  }
  if (response.status !== 200
      || response.headers.get("content-type")?.toLowerCase().startsWith("application/json") !== true
      || response.headers.get("neko-runtime-gate-generation") !== String(expected.generation)
      || response.headers.get("neko-runtime-media") !== (expected.media_enabled ? "ON" : "OFF")
      || response.headers.get("neko-runtime-apns") !== (expected.apns_enabled ? "ON" : "OFF")
      || response.headers.get("neko-runtime-report-ingestion") !== (expected.report_ingestion_enabled ? "ON" : "OFF")) {
    throw new Error("same-origin runtime gate verification failed");
  }
  let body;
  try { body = await response.json(); } catch {
    throw new Error("same-origin runtime gate verification failed");
  }
  if (!exactKeys(body, ["protocolVersion", "status"])
      || body.status !== "ok" || body.protocolVersion !== 1) {
    throw new Error("same-origin runtime gate verification failed");
  }
}

export async function verifyRuntimeGateOrigin(
  manifestInput,
  fetchImpl = fetch,
  { timeoutMilliseconds = 15_000 } = {},
) {
  const manifest = validateRuntimeGateManifest(manifestInput);
  const expected = expectedResult(manifest);
  await verifyRuntimeGateOriginState(
    manifest,
    expected,
    fetchImpl,
    timeoutMilliseconds,
  );
}

export function parseRuntimeGateArguments(argv) {
  if (!Array.isArray(argv) || argv.length !== 1) {
    throw new Error(
      "use exactly --plan, --status, --confirm-build70-media-apns-on, or --confirm-broad-off",
    );
  }
  const mapping = {
    "--plan": Object.freeze({ action: "plan", confirmation: null }),
    "--status": Object.freeze({ action: "status", confirmation: null }),
    "--confirm-build70-media-apns-on": "build70-media-apns-on",
    "--confirm-broad-off": "broad-off",
  };
  if (!Object.hasOwn(mapping, argv[0])) {
    throw new Error(
      "use exactly --plan, --status, --confirm-build70-media-apns-on, or --confirm-broad-off",
    );
  }
  const value = mapping[argv[0]];
  if (plain(value)) return value;
  return Object.freeze({ action: "confirm", confirmation: value });
}

export async function runRuntimeGateCommand(command, {
  environment = process.env,
  spawnImpl = spawn,
} = {}) {
  return new Promise((resolve, reject) => {
    const child = spawnImpl(command.executable, command.args, {
      cwd: command.cwd,
      env: {
        ...environment,
        CLOUDFLARE_ACCOUNT_ID: command.accountId,
        DO_NOT_TRACK: "1",
        WRANGLER_HIDE_BANNER: "true",
        WRANGLER_SEND_ERROR_REPORTS: "false",
        WRANGLER_SEND_METRICS: "false",
      },
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const chunks = [];
    let bytes = 0;
    let settled = false;
    let timer;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error === null) resolve(value); else reject(error);
    };
    child.stdout.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > 1024 * 1024) {
        child.kill();
        finish(new Error("runtime gate command output exceeded the limit"));
      } else chunks.push(Buffer.from(chunk));
    });
    child.stderr.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > 1024 * 1024) {
        child.kill();
        finish(new Error("runtime gate command output exceeded the limit"));
      }
    });
    child.on("error", () => finish(new Error("runtime gate command could not start")));
    child.on("close", (code) => finish(
      code === 0 ? null : new Error("runtime gate command failed"),
      Buffer.concat(chunks).toString("utf8"),
    ));
    timer = setTimeout(() => {
      child.kill();
      finish(new Error("runtime gate command timed out"));
    }, 30_000);
  });
}

export async function runRuntimeGateControl(argv, {
  projectDirectory,
  readFileImpl = readFile,
  runCommand = runRuntimeGateCommand,
  fetchImpl = fetch,
} = {}) {
  const mode = parseRuntimeGateArguments(argv);
  const manifestPath = join(projectDirectory, runtimeGateManifestName);
  const configPath = join(projectDirectory, runtimeGateConfigName);
  let manifest;
  let config;
  try {
    manifest = validateRuntimeGateManifest(JSON.parse(await readFileImpl(manifestPath, "utf8")));
    config = JSON.parse(await readFileImpl(configPath, "utf8"));
  } catch (error) {
    if (error instanceof Error && error.message.includes("manifest")) throw error;
    throw new Error("personal staging runtime gate files are unavailable or invalid");
  }
  validateFixedConfig(config, manifest);
  if (mode.action === "plan") {
    return "PASS runtime gate plan validated; no D1 update or network request was performed.";
  }
  if (mode.action === "confirm" && mode.confirmation !== manifest.desiredState) {
    throw new Error("runtime gate confirmation does not match the reviewed manifest");
  }
  const versionCommand = Object.freeze({
    executable: process.execPath,
    args: Object.freeze([join(projectDirectory, "node_modules", "wrangler", "bin", "wrangler.js"), "--version"]),
    cwd: projectDirectory,
    accountId: manifest.accountId,
  });
  if (!new RegExp(`\\b${wranglerVersion.replaceAll(".", "\\.")}\\b`, "u")
    .test(await runCommand(versionCommand))) {
    throw new Error(`reviewed Wrangler ${wranglerVersion} is required`);
  }
  if (mode.action === "status") {
    const snapshot = parseRuntimeGateStatus(
      await runCommand(runtimeGateStatusCommand(projectDirectory, manifest)),
    );
    await verifyRuntimeGateOriginState(
      manifest,
      snapshot,
      fetchImpl,
      15_000,
    );
    if (snapshot.generation !== manifest.expectedGeneration) {
      throw new Error(
        `runtime gate manifest generation is stale; live generation is ${snapshot.generation}`,
      );
    }
    return `PASS runtime gate status generation ${snapshot.generation} media=${snapshot.media_enabled ? "ON" : "OFF"} apns=${snapshot.apns_enabled ? "ON" : "OFF"} report=${snapshot.report_ingestion_enabled ? "ON" : "OFF"}; manifest generation reconciled.`;
  }
  const output = await runCommand(runtimeGateCommand(projectDirectory, manifest));
  parseRuntimeGateUpdate(output, manifest);
  await verifyRuntimeGateOrigin(manifest, fetchImpl);
  return `PASS runtime gate ${manifest.desiredState} generation ${manifest.expectedGeneration + 1} verified.`;
}
