import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import process from "node:process";

import { validateStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
export const moderationStagingProjectDirectory = join(scriptDirectory, "..");
export const moderationStagingConfigName = "wrangler.report-ingestion-staging-on.jsonc";
const moderationStatusTimeoutMilliseconds = 30_000;
const moderationStatusOutputLimitBytes = 1024 * 1024;

// These fixed queries expose aggregate operations data only. They never select
// report IDs, participant/device IDs, object keys, hashes, ciphertext, URLs,
// names, reason codes, or report content. The moderation key ID is a reviewed
// non-secret operational configuration value, not a report/user identifier.
export const moderationStatusQueries = Object.freeze([
  Object.freeze({
    name: "schema",
    sql: `SELECT COUNT(*) AS table_count
            FROM sqlite_schema
           WHERE type = 'table'
             AND name IN (
               'moment_reports',
               'moment_object_deletions',
               'moderation_cases',
               'moderation_case_events'
             )`,
  }),
  Object.freeze({
    name: "lifecycle",
    sql: `SELECT state, COUNT(*) AS count
            FROM moment_reports
           GROUP BY state
           ORDER BY state ASC`,
  }),
  Object.freeze({
    name: "key-lifecycle",
    sql: `SELECT moderation_key_id AS key_id, state, COUNT(*) AS count
            FROM moment_reports
           GROUP BY moderation_key_id, state
           ORDER BY moderation_key_id ASC, state ASC`,
  }),
  Object.freeze({
    name: "committed-age",
    sql: `SELECT
            COALESCE(SUM(CASE
              WHEN committed_at <= unixepoch()
               AND committed_at > unixepoch() - 86400 THEN 1 ELSE 0 END), 0) AS under_24h,
            COALESCE(SUM(CASE
              WHEN committed_at <= unixepoch() - 86400
               AND committed_at > unixepoch() - 172800 THEN 1 ELSE 0 END), 0) AS from_24h_to_48h,
            COALESCE(SUM(CASE
              WHEN committed_at <= unixepoch() - 172800 THEN 1 ELSE 0 END), 0) AS over_48h,
            COALESCE(SUM(CASE
              WHEN committed_at > unixepoch() THEN 1 ELSE 0 END), 0) AS future_count
           FROM moment_reports
          WHERE state = 'committed'`,
  }),
  Object.freeze({
    name: "review-lifecycle",
    sql: `SELECT
            COALESCE(SUM(CASE WHEN review_started_at IS NULL THEN 1 ELSE 0 END), 0)
              AS unreviewed,
            COALESCE(SUM(CASE
              WHEN review_started_at IS NOT NULL AND decided_at IS NULL THEN 1 ELSE 0 END), 0)
              AS in_review,
            COALESCE(SUM(CASE WHEN decided_at IS NOT NULL THEN 1 ELSE 0 END), 0)
              AS decided,
            COALESCE(SUM(CASE
              WHEN (review_started_at IS NULL AND review_due_at < unixepoch())
                OR review_started_at > review_due_at THEN 1 ELSE 0 END), 0)
              AS sla_exceeded,
            COALESCE(SUM(CASE WHEN committed_at > unixepoch() THEN 1 ELSE 0 END), 0)
              AS future_count,
            COALESCE(SUM(CASE
              WHEN latest_event_at > unixepoch() THEN 1 ELSE 0 END), 0)
              AS future_event_count
           FROM (
             SELECT moderation_case.report_id,
                    moderation_case.committed_at,
                    moderation_case.review_due_at,
                    MIN(CASE
                      WHEN event.event_type = 'review_started' THEN event.recorded_at END)
                      AS review_started_at,
                    MIN(CASE
                      WHEN event.event_type = 'review_decided' THEN event.recorded_at END)
                      AS decided_at,
                    MAX(event.recorded_at) AS latest_event_at
               FROM moderation_cases AS moderation_case
               LEFT JOIN moderation_case_events AS event
                 ON event.report_id = moderation_case.report_id
              GROUP BY moderation_case.report_id,
                       moderation_case.committed_at,
                       moderation_case.review_due_at
           ) AS lifecycle`,
  }),
  Object.freeze({
    name: "cleanup",
    sql: `SELECT
            (SELECT COUNT(*)
               FROM moment_reports
              WHERE state IN ('reserved', 'uploaded')
                AND upload_expires_at <= unixepoch()) AS expired_upload_reports,
            (SELECT COUNT(*)
               FROM moment_reports
              WHERE state = 'committed'
                AND content_expires_at <= unixepoch()) AS expired_content_reports,
            (SELECT COUNT(*)
               FROM moment_object_deletions
              WHERE object_type = 'report'
                AND state = 'pending') AS pending_report_deletions,
            (SELECT COUNT(*)
               FROM moment_object_deletions
              WHERE object_type = 'report'
                AND state = 'pending'
                AND not_before <= unixepoch()) AS due_report_deletions`,
  }),
]);

export function requireNoModerationStatusArguments(argv) {
  if (!Array.isArray(argv) || argv.length !== 0) {
    throw new Error("this read-only check accepts no arguments");
  }
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireCount(value) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error("moderation status query returned an invalid count");
  }
  return value;
}

function requireExactKeys(row, expected) {
  const actual = Object.keys(row).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error("moderation status query returned unexpected fields");
  }
}

function parseWranglerRows(output) {
  let parsed;
  try {
    parsed = JSON.parse(output);
  } catch {
    throw new Error("moderation status query did not return JSON");
  }
  if (!Array.isArray(parsed) || parsed.length !== 1 || !isRecord(parsed[0])) {
    throw new Error("moderation status query returned an unexpected response");
  }
  const envelope = parsed[0];
  if (envelope.success !== true || !Array.isArray(envelope.results)) {
    throw new Error("moderation status query was not successful");
  }
  if (!envelope.results.every(isRecord)) {
    throw new Error("moderation status query returned malformed rows");
  }
  return envelope.results;
}

function validateSchemaRows(rows) {
  if (rows.length !== 1) {
    throw new Error("moderation schema check returned an unexpected response");
  }
  requireExactKeys(rows[0], ["table_count"]);
  if (requireCount(rows[0].table_count) !== 4) {
    throw new Error("moderation schema is unavailable");
  }
  return Object.freeze([{ state: "ready" }]);
}

function validateLifecycleRows(rows) {
  const allowedStates = new Set(["reserved", "uploaded", "committed", "expired", "deleted"]);
  const seenStates = new Set();
  return rows.map((row) => {
    requireExactKeys(row, ["state", "count"]);
    if (typeof row.state !== "string" || !allowedStates.has(row.state) || seenStates.has(row.state)) {
      throw new Error("moderation status query returned an unexpected category");
    }
    seenStates.add(row.state);
    return Object.freeze({ state: row.state, count: requireCount(row.count) });
  });
}

function validateKeyLifecycleRows(rows) {
  const allowedKeyIDs = new Set(["moderation-v1", "moderation-v2"]);
  const allowedStates = new Set(["reserved", "uploaded", "committed", "expired", "deleted"]);
  const seenPairs = new Set();
  return Object.freeze(rows.map((row) => {
    requireExactKeys(row, ["key_id", "state", "count"]);
    if (typeof row.key_id !== "string" || !allowedKeyIDs.has(row.key_id)) {
      throw new Error("moderation key-lifecycle query returned an unsupported key ID");
    }
    if (typeof row.state !== "string" || !allowedStates.has(row.state)) {
      throw new Error("moderation key-lifecycle query returned an unexpected lifecycle category");
    }
    const pair = `${row.key_id}\0${row.state}`;
    if (seenPairs.has(pair)) {
      throw new Error("moderation key-lifecycle query returned a duplicate key/lifecycle pair");
    }
    seenPairs.add(pair);
    return Object.freeze({
      keyId: row.key_id,
      state: row.state,
      count: requireCount(row.count),
    });
  }));
}

function validateCommittedAgeRows(rows) {
  if (rows.length !== 1) {
    throw new Error("moderation committed-age query returned an unexpected response");
  }
  const row = rows[0];
  requireExactKeys(row, ["under_24h", "from_24h_to_48h", "over_48h", "future_count"]);
  if (requireCount(row.future_count) !== 0) {
    throw new Error("moderation committed-age query found future timestamps");
  }
  return Object.freeze({
    under24h: requireCount(row.under_24h),
    from24hTo48h: requireCount(row.from_24h_to_48h),
    over48h: requireCount(row.over_48h),
  });
}

function validateReviewLifecycleRows(rows) {
  if (rows.length !== 1) {
    throw new Error("moderation review-lifecycle query returned an unexpected response");
  }
  const row = rows[0];
  requireExactKeys(row, [
    "unreviewed",
    "in_review",
    "decided",
    "sla_exceeded",
    "future_count",
    "future_event_count",
  ]);
  if (requireCount(row.future_count) !== 0) {
    throw new Error("moderation review lifecycle found future case timestamps");
  }
  if (requireCount(row.future_event_count) !== 0) {
    throw new Error("moderation review lifecycle found future event timestamps");
  }
  const unreviewed = requireCount(row.unreviewed);
  const inReview = requireCount(row.in_review);
  const decided = requireCount(row.decided);
  const slaExceeded = requireCount(row.sla_exceeded);
  if (slaExceeded > unreviewed + inReview + decided) {
    throw new Error("moderation review lifecycle returned inconsistent counts");
  }
  return Object.freeze({ unreviewed, inReview, decided, slaExceeded });
}

function validateCleanupRows(rows) {
  if (rows.length !== 1) {
    throw new Error("moderation cleanup query returned an unexpected response");
  }
  const row = rows[0];
  requireExactKeys(row, [
    "expired_upload_reports",
    "expired_content_reports",
    "pending_report_deletions",
    "due_report_deletions",
  ]);
  const pendingReportDeletions = requireCount(row.pending_report_deletions);
  const dueReportDeletions = requireCount(row.due_report_deletions);
  if (dueReportDeletions > pendingReportDeletions) {
    throw new Error("moderation cleanup query returned inconsistent counts");
  }
  return Object.freeze({
    expiredUploadReports: requireCount(row.expired_upload_reports),
    expiredContentReports: requireCount(row.expired_content_reports),
    pendingReportDeletions,
    dueReportDeletions,
  });
}

function validatedRows(name, output) {
  const rows = parseWranglerRows(output);
  switch (name) {
    case "schema": return validateSchemaRows(rows);
    case "lifecycle": return validateLifecycleRows(rows);
    case "key-lifecycle": return validateKeyLifecycleRows(rows);
    case "committed-age": return validateCommittedAgeRows(rows);
    case "review-lifecycle": return validateReviewLifecycleRows(rows);
    case "cleanup": return validateCleanupRows(rows);
    default: throw new Error("moderation status query name is unsupported");
  }
}

export function moderationStatusCommand({ projectDirectory, databaseName, sql }) {
  if (typeof projectDirectory !== "string" || projectDirectory.length === 0) {
    throw new Error("moderation status project directory is unavailable");
  }
  if (databaseName !== "neko-window-sharing-staging") {
    throw new Error("moderation status may query only the isolated staging database");
  }
  if (!moderationStatusQueries.some((query) => query.sql === sql)) {
    throw new Error("moderation status may execute only reviewed read-only queries");
  }
  const configPath = join(projectDirectory, moderationStagingConfigName);
  const wranglerEntryPoint = join(projectDirectory, "node_modules", "wrangler", "bin", "wrangler.js");
  return Object.freeze({
    executable: process.execPath,
    args: Object.freeze([
      wranglerEntryPoint,
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

export function moderationWranglerEnvironment(environment = process.env) {
  return Object.freeze({
    ...environment,
    DO_NOT_TRACK: "1",
    WRANGLER_HIDE_BANNER: "true",
    WRANGLER_SEND_ERROR_REPORTS: "false",
    WRANGLER_SEND_METRICS: "false",
  });
}

function requirePositiveRunnerLimit(value, label) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${label} must be a positive safe integer`);
  }
  return value;
}

export async function runReadOnlyModerationWranglerCommand(command, {
  environment = process.env,
  maxOutputBytes = moderationStatusOutputLimitBytes,
  spawnImpl = spawn,
  timeoutMilliseconds = moderationStatusTimeoutMilliseconds,
} = {}) {
  requirePositiveRunnerLimit(maxOutputBytes, "moderation status output limit");
  requirePositiveRunnerLimit(timeoutMilliseconds, "moderation status timeout");
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawnImpl(command.executable, command.args, {
        cwd: command.cwd,
        env: moderationWranglerEnvironment(environment),
        shell: false,
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch {
      reject(new Error("moderation status could not start Wrangler"));
      return;
    }

    let outputBytes = 0;
    const stdoutChunks = [];
    let settled = false;
    let timeoutHandle;
    const finish = (error, output, killChild = false) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutHandle);
      if (killChild) {
        try {
          child.kill();
        } catch {
          // The original bounded failure remains authoritative.
        }
      }
      if (error === null) resolve(output);
      else reject(error);
    };
    const consume = (chunk, keep) => {
      if (settled) return;
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      outputBytes += bytes.length;
      if (outputBytes > maxOutputBytes) {
        finish(new Error("moderation status Wrangler output exceeded the limit"), undefined, true);
        return;
      }
      if (keep) stdoutChunks.push(bytes);
    };

    // Drain both pipes. Stderr is deliberately discarded after counting so
    // provider diagnostics cannot leak into operator output or block the child.
    child.stdout.on("data", (chunk) => consume(chunk, true));
    child.stderr.on("data", (chunk) => consume(chunk, false));
    child.on("error", () => {
      finish(new Error("moderation status could not start Wrangler"));
    });
    child.on("close", (code) => {
      if (code !== 0) {
        finish(new Error("moderation status read-only D1 query failed"));
        return;
      }
      finish(null, Buffer.concat(stdoutChunks).toString("utf8"));
    });
    timeoutHandle = setTimeout(() => {
      finish(new Error("moderation status read-only D1 query timed out"), undefined, true);
    }, timeoutMilliseconds);
  });
}

export async function collectModerationStagingStatus({
  projectDirectory = moderationStagingProjectDirectory,
  readFileImpl = readFile,
  runCommand = runReadOnlyModerationWranglerCommand,
} = {}) {
  const configPath = join(projectDirectory, moderationStagingConfigName);
  let config;
  try {
    config = JSON.parse(await readFileImpl(configPath, "utf8"));
  } catch {
    throw new Error("report-ingestion staging ON configuration is unavailable or invalid");
  }
  validateStagingConfig(config, {
    expectedMomentRuntime: "NO",
    expectedAPNSRuntime: "NO",
    expectedReportIngestionRuntime: "YES",
  });
  const databaseName = config.d1_databases[0]?.database_name;
  if (databaseName !== "neko-window-sharing-staging") {
    throw new Error("moderation status may query only the isolated staging database");
  }

  const result = {};
  for (const query of moderationStatusQueries) {
    const command = moderationStatusCommand({ projectDirectory, databaseName, sql: query.sql });
    result[query.name] = validatedRows(query.name, await runCommand(command));
  }
  const lifecycleCounts = new Map(result.lifecycle.map((row) => [row.state, row.count]));
  const keyedCounts = new Map();
  for (const row of result["key-lifecycle"]) {
    keyedCounts.set(row.state, (keyedCounts.get(row.state) ?? 0) + row.count);
  }
  const states = new Set([...lifecycleCounts.keys(), ...keyedCounts.keys()]);
  if ([...states].some(
    (state) => (lifecycleCounts.get(state) ?? 0) !== (keyedCounts.get(state) ?? 0)
  )) {
    throw new Error("moderation key-lifecycle query returned counts inconsistent with lifecycle totals");
  }
  return Object.freeze(result);
}

function line(items, format) {
  return items.length === 0 ? "none=0" : items.map(format).join(", ");
}

export function formatModerationStagingStatus(status) {
  return [
    "PASS moderation staging status (read-only aggregates; exact operational moderation key IDs only; no report/user/device IDs, names, object keys, hashes, ciphertext, URLs, secrets, reason codes, or report content)",
    `schema: ${status.schema[0].state}`,
    `lifecycle: ${line(status.lifecycle, (row) => `${row.state}=${row.count}`)}`,
    `key_lifecycle: ${line(status["key-lifecycle"], (row) => `${row.keyId}/${row.state}=${row.count}`)}`,
    `committed_report_age (content age, not review SLA): under_24h=${status["committed-age"].under24h}, 24h_to_48h=${status["committed-age"].from24hTo48h}, over_48h=${status["committed-age"].over48h}`,
    `review_lifecycle: unreviewed=${status["review-lifecycle"].unreviewed}, in_review=${status["review-lifecycle"].inReview}, decided=${status["review-lifecycle"].decided}, sla_exceeded=${status["review-lifecycle"].slaExceeded}`,
    `cleanup: expired_upload=${status.cleanup.expiredUploadReports}, expired_content=${status.cleanup.expiredContentReports}, pending_report_deletions=${status.cleanup.pendingReportDeletions}, due_report_deletions=${status.cleanup.dueReportDeletions}`,
  ].join("\n");
}
