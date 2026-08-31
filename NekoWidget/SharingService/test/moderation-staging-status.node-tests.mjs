import assert from "node:assert/strict";
import test from "node:test";

import {
  collectModerationStagingStatus,
  formatModerationStagingStatus,
  moderationStagingConfigName,
  moderationStatusCommand,
  moderationStatusQueries,
  requireNoModerationStatusArguments,
  runReadOnlyModerationWranglerCommand,
} from "../scripts/moderation-staging-status-lib.mjs";
import { renderStagingConfig } from "../scripts/staging-config-lib.mjs";

const projectDirectory = "/safe/neko-widget/SharingService";
const fixtureEnvironment = {
  NEKO_STAGING_D1_DATABASE_ID: "00000000-0000-0000-0000-000000000000",
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
  NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID: "700004",
};
const template = JSON.stringify({
  $schema: "node_modules/wrangler/config-schema.json",
  name: "neko-window-sharing-staging",
  main: "src/index.ts",
  compatibility_date: "2026-08-17",
  workers_dev: true,
  preview_urls: false,
  observability: { enabled: false, logs: { enabled: false } },
  vars: {
    ENVIRONMENT: "staging",
    MOMENT_RUNTIME_ENABLED: "NO",
    REPORT_INGESTION_RUNTIME_ENABLED: "NO",
    REACTION_RUNTIME_ENABLED: "NO",
    WINDOW_NAME_RUNTIME_ENABLED: "NO",
    APNS_RUNTIME_ENABLED: "NO",
    LEGACY_SHARING_RUNTIME_ENABLED: "NO",
    BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED: "NO",
    BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED: "NO",
    BILLING_APPLE_NOTIFICATION_RUNTIME_ENABLED: "NO",
    BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED: "NO",
    BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: "NO",
    BILLING_ACCOUNT_RECOVERY_RUNTIME_ENABLED: "NO",
    INVITATION_TTL_SECONDS: "86400",
    CHALLENGE_TTL_SECONDS: "300",
    PENDING_TTL_SECONDS: "86400",
    IDEMPOTENCY_TTL_SECONDS: "172800",
    SPACE_INACTIVITY_TTL_SECONDS: "2592000",
  },
  triggers: { crons: ["* * * * *", "*/5 * * * *", "2,7,12,17,22,27,32,37,42,47,52,57 * * * *"] },
  d1_databases: [{
    binding: "DB",
    database_name: "neko-window-sharing-staging",
    database_id: "__NEKO_STAGING_D1_DATABASE_ID__",
    migrations_dir: "migrations",
  }],
  r2_buckets: [
    { binding: "MEDIA", bucket_name: "neko-window-sharing-staging-media-private" },
    { binding: "MODERATION_MEDIA", bucket_name: "neko-window-sharing-staging-moderation-private" },
  ],
  ratelimits: [
    { name: "CREATE_RATE_LIMITER", namespace_id: "__NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID__", simple: { limit: 5, period: 60 } },
    { name: "INVITE_RATE_LIMITER", namespace_id: "__NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID__", simple: { limit: 10, period: 60 } },
    { name: "MEMBER_RATE_LIMITER", namespace_id: "__NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID__", simple: { limit: 120, period: 60 } },
    { name: "BILLING_RATE_LIMITER", namespace_id: "__NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID__", simple: { limit: 30, period: 60 } },
  ],
});

function renderedConfig() {
  return renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "NO",
    expectedAPNSRuntime: "NO",
    expectedReportIngestionRuntime: "YES",
  });
}

function successfulRows(rows) {
  return JSON.stringify([{ success: true, results: rows }]);
}

function localNodeCommand(source) {
  return Object.freeze({
    executable: process.execPath,
    args: Object.freeze(["--input-type=module", "--eval", source]),
    cwd: process.cwd(),
  });
}

test("bounds moderation Wrangler execution and enforces its process environment", async (context) => {
  await context.test("forces telemetry, error-report, banner, and update suppression", async () => {
    const accountId = "11111111111111111111111111111111";
    const command = Object.freeze({
      ...localNodeCommand(`process.stdout.write(JSON.stringify({
        DO_NOT_TRACK: process.env.DO_NOT_TRACK,
        WRANGLER_HIDE_BANNER: process.env.WRANGLER_HIDE_BANNER,
        WRANGLER_SEND_ERROR_REPORTS: process.env.WRANGLER_SEND_ERROR_REPORTS,
        WRANGLER_SEND_METRICS: process.env.WRANGLER_SEND_METRICS,
        CLOUDFLARE_ACCOUNT_ID: process.env.CLOUDFLARE_ACCOUNT_ID,
        preserved: process.env.NEKO_MODERATION_STATUS_TEST,
      }));`),
      accountId,
    });
    const output = await runReadOnlyModerationWranglerCommand(
      command,
      {
        environment: {
          ...process.env,
          CLOUDFLARE_ACCOUNT_ID: "22222222222222222222222222222222",
          DO_NOT_TRACK: "0",
          WRANGLER_HIDE_BANNER: "false",
          WRANGLER_SEND_ERROR_REPORTS: "true",
          WRANGLER_SEND_METRICS: "true",
          NEKO_MODERATION_STATUS_TEST: "preserved",
        },
        maxOutputBytes: 64 * 1024,
        timeoutMilliseconds: 5_000,
      },
    );
    assert.deepEqual(JSON.parse(output), {
      DO_NOT_TRACK: "1",
      WRANGLER_HIDE_BANNER: "true",
      WRANGLER_SEND_ERROR_REPORTS: "false",
      WRANGLER_SEND_METRICS: "false",
      CLOUDFLARE_ACCOUNT_ID: accountId,
      preserved: "preserved",
    });
  });

  await context.test("drains a large bounded stderr stream", async () => {
    const output = await runReadOnlyModerationWranglerCommand(
      localNodeCommand(`
        process.stderr.write("x".repeat(256 * 1024));
        process.stdout.write("ok");
      `),
      { maxOutputBytes: 512 * 1024, timeoutMilliseconds: 5_000 },
    );
    assert.equal(output, "ok");
  });

  await context.test("kills stdout and stderr overflow", async () => {
    for (const stream of ["stdout", "stderr"]) {
      await assert.rejects(
        runReadOnlyModerationWranglerCommand(
          localNodeCommand(`process.${stream}.write("x".repeat(64 * 1024));`),
          { maxOutputBytes: 1024, timeoutMilliseconds: 5_000 },
        ),
        /output exceeded the limit/u,
      );
    }
  });

  await context.test("kills a command that exceeds its explicit timeout", async () => {
    const startedAt = Date.now();
    await assert.rejects(
      runReadOnlyModerationWranglerCommand(
        localNodeCommand("setInterval(() => {}, 1_000);"),
        { maxOutputBytes: 1024, timeoutMilliseconds: 100 },
      ),
      /timed out/u,
    );
    assert.ok(Date.now() - startedAt < 5_000);
  });
});

const validResponses = Object.freeze({
  schema: successfulRows([{ table_count: 4 }]),
  lifecycle: successfulRows([
    { state: "committed", count: 3 },
    { state: "reserved", count: 1 },
  ]),
  "key-lifecycle": successfulRows([
    { key_id: "moderation-v1", state: "committed", count: 2 },
    { key_id: "moderation-v1", state: "reserved", count: 1 },
    { key_id: "moderation-v2", state: "committed", count: 1 },
  ]),
  "committed-age": successfulRows([{
    under_24h: 1,
    from_24h_to_48h: 1,
    over_48h: 1,
    future_count: 0,
  }]),
  "review-lifecycle": successfulRows([{
    unreviewed: 2,
    in_review: 1,
    decided: 3,
    sla_exceeded: 1,
    future_count: 0,
    future_event_count: 0,
  }]),
  cleanup: successfulRows([{
    expired_upload_reports: 1,
    expired_content_reports: 0,
    pending_report_deletions: 2,
    due_report_deletions: 1,
  }]),
});

function queryForCommand(command) {
  return moderationStatusQueries.find((entry) => command.args.includes(entry.sql));
}

test("runs exactly the reviewed aggregate-only queries through report-ingestion staging", async () => {
  const commands = [];
  const accountId = "11111111111111111111111111111111";
  const status = await collectModerationStagingStatus({
    projectDirectory,
    expectedDatabaseId: fixtureEnvironment.NEKO_STAGING_D1_DATABASE_ID,
    accountId,
    readFileImpl: async (path) => {
      assert.equal(path.replaceAll("\\", "/"), `${projectDirectory}/${moderationStagingConfigName}`);
      return renderedConfig();
    },
    runCommand: async (command) => {
      commands.push(command);
      assert.equal(command.cwd, projectDirectory);
      assert.equal(command.accountId, accountId);
      assert.equal(command.executable, process.execPath);
      assert.equal(
        command.args[0].replaceAll("\\", "/"),
        `${projectDirectory}/node_modules/wrangler/bin/wrangler.js`,
      );
      assert.equal(command.args.includes("npx"), false);
      assert.equal(command.args.includes("npx.cmd"), false);
      assert.equal(command.args.includes("--remote"), true);
      assert.equal(command.args.includes("--json"), true);
      assert.equal(command.args.includes("--local"), false);
      assert.equal(command.args.includes("--file"), false);
      assert.equal(
        command.args.at(command.args.indexOf("--config") + 1).replaceAll("\\", "/"),
        `${projectDirectory}/${moderationStagingConfigName}`,
      );
      const query = queryForCommand(command);
      assert.notEqual(query, undefined);
      return validResponses[query.name];
    },
  });

  assert.equal(commands.length, 6);
  assert.deepEqual(status, {
    schema: [{ state: "ready" }],
    lifecycle: [{ state: "committed", count: 3 }, { state: "reserved", count: 1 }],
    "key-lifecycle": [
      { keyId: "moderation-v1", state: "committed", count: 2 },
      { keyId: "moderation-v1", state: "reserved", count: 1 },
      { keyId: "moderation-v2", state: "committed", count: 1 },
    ],
    "committed-age": { under24h: 1, from24hTo48h: 1, over48h: 1 },
    "review-lifecycle": {
      unreviewed: 2,
      inReview: 1,
      decided: 3,
      slaExceeded: 1,
    },
    cleanup: {
      expiredUploadReports: 1,
      expiredContentReports: 0,
      pendingReportDeletions: 2,
      dueReportDeletions: 1,
    },
  });
  const text = formatModerationStagingStatus(status);
  assert.match(text, /read-only aggregates/u);
  assert.match(text, /moderation-v1\/committed=2/u);
  assert.match(text, /moderation-v2\/committed=1/u);
  assert.match(text, /not review SLA/u);
  assert.match(text, /over_48h=1/u);
  assert.match(text, /unreviewed=2/u);
  assert.match(text, /in_review=1/u);
  assert.match(text, /decided=3/u);
  assert.match(text, /sla_exceeded=1/u);
  assert.doesNotMatch(text, /must-not-pass-through/u);
});

test("identifies a failed reviewed query without exposing runner diagnostics", async () => {
  let commands = 0;
  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      readFileImpl: async () => renderedConfig(),
      runCommand: async (command) => {
        commands += 1;
        const query = queryForCommand(command);
        if (query?.name === "key-lifecycle") {
          throw new Error("provider detail containing must-not-pass-through");
        }
        return validResponses[query.name];
      },
    }),
    (error) => {
      assert.equal(
        error.message,
        "moderation status key-lifecycle read-only D1 query failed",
      );
      assert.doesNotMatch(error.message, /must-not-pass-through/u);
      return true;
    },
  );
  assert.equal(commands, 3);
});

test("rejects arguments, unreviewed databases, and unreviewed SQL", () => {
  assert.doesNotThrow(() => requireNoModerationStatusArguments([]));
  assert.throws(
    () => requireNoModerationStatusArguments(["--command", "SELECT object_key FROM moment_reports"]),
    /accepts no arguments/u,
  );
  assert.throws(
    () => moderationStatusCommand({
      projectDirectory,
      databaseName: "other-database",
      sql: moderationStatusQueries[0].sql,
    }),
    /only the isolated staging database/u,
  );
  assert.throws(
    () => moderationStatusCommand({
      projectDirectory,
      databaseName: "neko-window-sharing-staging",
      sql: "SELECT object_key FROM moment_reports",
    }),
    /only reviewed read-only queries/u,
  );
});

test("binds moderation status to the reviewed D1 and account before any query", async () => {
  let commands = 0;
  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      expectedDatabaseId: "22222222-2222-2222-2222-222222222222",
      accountId: "11111111111111111111111111111111",
      readFileImpl: async () => renderedConfig(),
      runCommand: async () => {
        commands += 1;
        throw new Error("must not query");
      },
    }),
    /database does not match the reviewed target/u,
  );
  assert.equal(commands, 0);

  assert.throws(
    () => moderationStatusCommand({
      projectDirectory,
      databaseName: "neko-window-sharing-staging",
      sql: moderationStatusQueries[0].sql,
      accountId: "not-an-account",
    }),
    /account is unavailable or invalid/u,
  );
});

test("rejects unexpected fields and categories without rendering them", async () => {
  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      readFileImpl: async () => renderedConfig(),
      runCommand: async (command) => {
        const query = queryForCommand(command);
        if (query?.name === "schema") return validResponses.schema;
        if (query?.name === "lifecycle") {
          return successfulRows([{
            state: "reviewed",
            count: 1,
            object_key: "must-not-pass-through",
          }]);
        }
        throw new Error("later queries must not run after malformed lifecycle output");
      },
    }),
    /unexpected fields|unexpected category/u,
  );
});

test("fails closed for unknown, whitespace, duplicate, or inconsistent moderation key aggregates", async () => {
  for (const keyID of ["moderation-v3", " moderation-v1", "", "MODERATION-V1"]) {
    await assert.rejects(
      collectModerationStagingStatus({
        projectDirectory,
        readFileImpl: async () => renderedConfig(),
        runCommand: async (command) => {
          const query = queryForCommand(command);
          if (query?.name === "key-lifecycle") {
            return successfulRows([{ key_id: keyID, state: "committed", count: 3 }]);
          }
          return validResponses[query.name];
        },
      }),
      /unsupported key ID/u,
    );
  }

  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      readFileImpl: async () => renderedConfig(),
      runCommand: async (command) => {
        const query = queryForCommand(command);
        if (query?.name === "key-lifecycle") {
          return successfulRows([
            { key_id: "moderation-v1", state: "committed", count: 3 },
            { key_id: "moderation-v1", state: "committed", count: 0 },
            { key_id: "moderation-v1", state: "reserved", count: 1 },
          ]);
        }
        return validResponses[query.name];
      },
    }),
    /duplicate key\/lifecycle pair/u,
  );

  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      readFileImpl: async () => renderedConfig(),
      runCommand: async (command) => {
        const query = queryForCommand(command);
        if (query?.name === "key-lifecycle") {
          return successfulRows([
            { key_id: "moderation-v1", state: "committed", count: 2 },
            { key_id: "moderation-v1", state: "reserved", count: 1 },
          ]);
        }
        return validResponses[query.name];
      },
    }),
    /counts inconsistent with lifecycle totals/u,
  );
});

test("fails closed when the moderation schema is unavailable", async () => {
  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      readFileImpl: async () => renderedConfig(),
      runCommand: async () => successfulRows([{ table_count: 1 }]),
    }),
    /schema is unavailable/u,
  );
});

test("fails closed for future timestamps and inconsistent aggregate counts", async () => {
  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      readFileImpl: async () => renderedConfig(),
      runCommand: async (command) => {
        const query = queryForCommand(command);
        if (query?.name === "committed-age") {
          return successfulRows([{
            under_24h: 0,
            from_24h_to_48h: 0,
            over_48h: 0,
            future_count: 1,
          }]);
        }
        return validResponses[query.name];
      },
    }),
    /future timestamps/u,
  );

  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      readFileImpl: async () => renderedConfig(),
      runCommand: async (command) => {
        const query = queryForCommand(command);
        if (query?.name === "review-lifecycle") {
          return successfulRows([{
            unreviewed: 0,
            in_review: 0,
            decided: 0,
            sla_exceeded: 0,
            future_count: 1,
            future_event_count: 0,
          }]);
        }
        return validResponses[query.name];
      },
    }),
    /future case timestamps/u,
  );

  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      readFileImpl: async () => renderedConfig(),
      runCommand: async (command) => {
        const query = queryForCommand(command);
        if (query?.name === "review-lifecycle") {
          return successfulRows([{
            unreviewed: 0,
            in_review: 1,
            decided: 0,
            sla_exceeded: 0,
            future_count: 0,
            future_event_count: 1,
          }]);
        }
        return validResponses[query.name];
      },
    }),
    /future event timestamps/u,
  );

  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      readFileImpl: async () => renderedConfig(),
      runCommand: async (command) => {
        const query = queryForCommand(command);
        if (query?.name === "review-lifecycle") {
          return successfulRows([{
            unreviewed: 1,
            in_review: 0,
            decided: 0,
            sla_exceeded: 2,
            future_count: 0,
            future_event_count: 0,
          }]);
        }
        return validResponses[query.name];
      },
    }),
    /inconsistent counts/u,
  );

  await assert.rejects(
    collectModerationStagingStatus({
      projectDirectory,
      readFileImpl: async () => renderedConfig(),
      runCommand: async (command) => {
        const query = queryForCommand(command);
        if (query?.name === "cleanup") {
          return successfulRows([{
            expired_upload_reports: 0,
            expired_content_reports: 0,
            pending_report_deletions: 1,
            due_report_deletions: 2,
          }]);
        }
        return validResponses[query.name];
      },
    }),
    /inconsistent counts/u,
  );
});
