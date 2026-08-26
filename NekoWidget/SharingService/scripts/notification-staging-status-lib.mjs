import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

import { validateStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
export const notificationStagingProjectDirectory = join(scriptDirectory, "..");
export const notificationStagingConfigName = "wrangler.notification-staging-on.jsonc";

// These queries intentionally expose only coarse operational buckets. They
// never select IDs, token digests/ciphertext, encrypted media, or raw APNs
// provider reasons.
export const notificationStatusQueries = Object.freeze([
  Object.freeze({
    name: "route-schema",
    // Referencing the column is intentional: Wrangler fails this read-only
    // check when migration 0011 has not been applied to staging.
    sql: `SELECT
            (SELECT COUNT(*)
               FROM apns_subscriptions
              WHERE route_schema_version NOT IN (1, 2)) AS invalid_count,
            (SELECT COUNT(*)
               FROM sqlite_schema
              WHERE type = 'trigger'
                AND tbl_name = 'apns_subscriptions'
                AND name = 'apns_subscriptions_normalize_legacy_route_update'
                AND instr(sql, 'AFTER UPDATE OF participant_id, environment') > 0
                AND instr(sql, 'SET route_schema_version = 1') > 0) AS normalizer_count`,
  }),
  Object.freeze({
    name: "subscriptions",
    sql: `SELECT environment, COUNT(*) AS count
            FROM apns_subscriptions
           WHERE expires_at > unixepoch()
           GROUP BY environment
           ORDER BY environment ASC`,
  }),
  Object.freeze({
    name: "events",
    sql: `SELECT kind, COUNT(*) AS count
            FROM notification_events
           WHERE expires_at > unixepoch()
           GROUP BY kind
           ORDER BY kind ASC`,
  }),
  Object.freeze({
    name: "deliveries",
    sql: `SELECT state,
                   CASE
                     WHEN last_status IS NULL THEN 'none'
                     WHEN last_status = 200 THEN '200'
                     ELSE 'other'
                   END AS status,
                   CASE
                     WHEN last_reason IS NULL THEN 'none'
                     WHEN last_reason = 'NetworkError' THEN 'network_error'
                     WHEN last_reason = 'TokenDecryptFailed' THEN 'token_decrypt_failed'
                     WHEN last_reason LIKE 'configuration_error:%' THEN 'configuration_error'
                     WHEN last_reason IN ('BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered') THEN 'invalid_token'
                     WHEN last_reason IN ('TooManyProviderTokenUpdates', 'ExpiredProviderToken') THEN 'transient_provider'
                     ELSE 'other'
                   END AS reason,
                   COUNT(*) AS count
            FROM notification_deliveries
           GROUP BY state, status, reason
           ORDER BY state ASC, status ASC, reason ASC`,
  }),
]);

export function requireNoStatusArguments(argv) {
  if (!Array.isArray(argv) || argv.length !== 0) {
    throw new Error("this read-only check accepts no arguments");
  }
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireCount(value) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error("notification status query returned an invalid count");
  }
  return value;
}

function requireExactKeys(row, expected) {
  const actual = Object.keys(row).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error("notification status query returned unexpected fields");
  }
}

function requireExactString(value, allowed) {
  if (typeof value !== "string" || !allowed.has(value)) {
    throw new Error("notification status query returned an unexpected category");
  }
  return value;
}

function parseWranglerRows(output) {
  let parsed;
  try {
    parsed = JSON.parse(output);
  } catch {
    throw new Error("notification status query did not return JSON");
  }
  if (!Array.isArray(parsed) || parsed.length !== 1 || !isRecord(parsed[0])) {
    throw new Error("notification status query returned an unexpected response");
  }
  const envelope = parsed[0];
  if (envelope.success !== true || !Array.isArray(envelope.results)) {
    throw new Error("notification status query was not successful");
  }
  if (!envelope.results.every(isRecord)) {
    throw new Error("notification status query returned malformed rows");
  }
  return envelope.results;
}

function validateSubscriptionRows(rows) {
  return rows.map((row) => {
    requireExactKeys(row, ["environment", "count"]);
    return Object.freeze({
      environment: requireExactString(
        row.environment,
        new Set(["development", "production"]),
      ),
      count: requireCount(row.count),
    });
  });
}

function validateRouteSchemaRows(rows) {
  if (rows.length !== 1) {
    throw new Error("notification route schema check returned an unexpected response");
  }
  const row = rows[0];
  requireExactKeys(row, ["invalid_count", "normalizer_count"]);
  if (requireCount(row.invalid_count) !== 0) {
    throw new Error("notification route schema contains invalid rows");
  }
  if (requireCount(row.normalizer_count) !== 1) {
    throw new Error("notification route schema normalizer is unavailable");
  }
  return Object.freeze([{ state: "ready" }]);
}

function validateEventRows(rows) {
  return rows.map((row) => {
    requireExactKeys(row, ["kind", "count"]);
    return Object.freeze({
      kind: requireExactString(row.kind, new Set(["new_moment", "heart"])),
      count: requireCount(row.count),
    });
  });
}

function validateDeliveryRows(rows) {
  const states = new Set(["pending", "leased", "accepted"]);
  const statuses = new Set(["none", "200", "other"]);
  const reasons = new Set([
    "none",
    "network_error",
    "token_decrypt_failed",
    "configuration_error",
    "invalid_token",
    "transient_provider",
    "other",
  ]);
  return rows.map((row) => {
    requireExactKeys(row, ["state", "status", "reason", "count"]);
    return Object.freeze({
      state: requireExactString(row.state, states),
      status: requireExactString(row.status, statuses),
      reason: requireExactString(row.reason, reasons),
      count: requireCount(row.count),
    });
  });
}

function validatedRows(name, output) {
  const rows = parseWranglerRows(output);
  switch (name) {
    case "route-schema": return validateRouteSchemaRows(rows);
    case "subscriptions": return validateSubscriptionRows(rows);
    case "events": return validateEventRows(rows);
    case "deliveries": return validateDeliveryRows(rows);
    default: throw new Error("notification status query name is unsupported");
  }
}

export function notificationStatusCommand({ projectDirectory, databaseName, sql }) {
  if (typeof projectDirectory !== "string" || projectDirectory.length === 0) {
    throw new Error("notification status project directory is unavailable");
  }
  if (databaseName !== "neko-window-sharing-staging") {
    throw new Error("notification status may query only the isolated staging database");
  }
  if (!notificationStatusQueries.some((query) => query.sql === sql)) {
    throw new Error("notification status may execute only reviewed read-only queries");
  }
  const configPath = join(projectDirectory, notificationStagingConfigName);
  return Object.freeze({
    executable: process.platform === "win32" ? "npx.cmd" : "npx",
    args: Object.freeze([
      "--no-install",
      "wrangler",
      "d1",
      "execute",
      databaseName,
      "--remote",
      "--json",
      "--config",
      configPath,
      "--command",
      sql,
    ]),
    cwd: projectDirectory,
  });
}

export async function runReadOnlyWranglerCommand(command) {
  return new Promise((resolve, reject) => {
    const child = spawn(command.executable, command.args, {
      cwd: command.cwd,
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.on("error", () => reject(new Error("notification status could not start Wrangler")));
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error("notification status read-only D1 query failed"));
        return;
      }
      resolve(stdout);
    });
  });
}

export async function collectNotificationStagingStatus({
  projectDirectory = notificationStagingProjectDirectory,
  readFileImpl = readFile,
  runCommand = runReadOnlyWranglerCommand,
} = {}) {
  const configPath = join(projectDirectory, notificationStagingConfigName);
  let config;
  try {
    config = JSON.parse(await readFileImpl(configPath, "utf8"));
  } catch {
    throw new Error("notification staging ON configuration is unavailable or invalid");
  }
  validateStagingConfig(config, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
  });
  const databaseName = config.d1_databases[0]?.database_name;
  if (databaseName !== "neko-window-sharing-staging") {
    throw new Error("notification status may query only the isolated staging database");
  }

  const result = {};
  for (const query of notificationStatusQueries) {
    const command = notificationStatusCommand({
      projectDirectory,
      databaseName,
      sql: query.sql,
    });
    result[query.name] = validatedRows(query.name, await runCommand(command));
  }
  return Object.freeze(result);
}

function line(items, format) {
  return items.length === 0 ? "none=0" : items.map(format).join(", ");
}

export function formatNotificationStagingStatus(status) {
  return [
    "PASS notification staging status (read-only; no IDs, tokens, ciphertext, or raw provider reasons)",
    `route_schema: ${status["route-schema"][0].state}`,
    `subscriptions: ${line(status.subscriptions, (row) => `${row.environment}=${row.count}`)}`,
    `events: ${line(status.events, (row) => `${row.kind}=${row.count}`)}`,
    `deliveries: ${line(status.deliveries, (row) => `${row.state}/${row.status}/${row.reason}=${row.count}`)}`,
  ].join("\n");
}
