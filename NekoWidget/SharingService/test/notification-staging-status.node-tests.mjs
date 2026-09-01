import assert from "node:assert/strict";
import test from "node:test";

import {
  collectNotificationStagingStatus,
  formatNotificationStagingStatus,
  notificationStagingConfigName,
  notificationStatusCommand,
  notificationStatusQueries,
  requireNoStatusArguments,
  runReadOnlyWranglerCommand,
} from "../scripts/notification-staging-status-lib.mjs";
import { renderStagingConfig } from "../scripts/staging-config-lib.mjs";

const projectDirectory = "/safe/neko-widget/SharingService";
const fixtureEnvironment = {
  NEKO_STAGING_D1_DATABASE_ID: "00000000-0000-0000-0000-000000000000",
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
  NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID: "700004",
  NEKO_STAGING_BILLING_APPLE_NOTIFICATION_RATE_LIMIT_NAMESPACE_ID: "700005",
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
    BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED: "NO",
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
    { name: "BILLING_APPLE_NOTIFICATION_RATE_LIMITER", namespace_id: "__NEKO_STAGING_BILLING_APPLE_NOTIFICATION_RATE_LIMIT_NAMESPACE_ID__", simple: { limit: 30, period: 60 } },
  ],
});

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

test("bounds notification Wrangler execution and enforces its process environment", async (context) => {
  await context.test("forces telemetry, error-report, banner, and update suppression", async () => {
    const output = await runReadOnlyWranglerCommand(
      localNodeCommand(`process.stdout.write(JSON.stringify({
        DO_NOT_TRACK: process.env.DO_NOT_TRACK,
        WRANGLER_HIDE_BANNER: process.env.WRANGLER_HIDE_BANNER,
        WRANGLER_SEND_ERROR_REPORTS: process.env.WRANGLER_SEND_ERROR_REPORTS,
        WRANGLER_SEND_METRICS: process.env.WRANGLER_SEND_METRICS,
        preserved: process.env.NEKO_NOTIFICATION_STATUS_TEST,
      }));`),
      {
        environment: {
          ...process.env,
          DO_NOT_TRACK: "0",
          WRANGLER_HIDE_BANNER: "false",
          WRANGLER_SEND_ERROR_REPORTS: "true",
          WRANGLER_SEND_METRICS: "true",
          NEKO_NOTIFICATION_STATUS_TEST: "preserved",
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
      preserved: "preserved",
    });
  });

  await context.test("drains a large bounded stderr stream", async () => {
    const output = await runReadOnlyWranglerCommand(
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
        runReadOnlyWranglerCommand(
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
      runReadOnlyWranglerCommand(
        localNodeCommand("setInterval(() => {}, 1_000);"),
        { maxOutputBytes: 1024, timeoutMilliseconds: 100 },
      ),
      /timed out/u,
    );
    assert.ok(Date.now() - startedAt < 5_000);
  });
});

test("runs exactly the reviewed read-only D1 queries through the isolated ON config", async () => {
  const config = renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
  });
  const commands = [];
  const responses = new Map([
    ["route-schema", successfulRows([{ invalid_count: 0, normalizer_count: 1 }])],
    ["subscriptions", successfulRows([{ environment: "production", count: 2 }])],
    ["events", successfulRows([{ kind: "new_moment", count: 1 }])],
    ["deliveries", successfulRows([{ state: "accepted", status: "200", reason: "none", count: 1 }])],
  ]);
  const status = await collectNotificationStagingStatus({
    projectDirectory,
    readFileImpl: async (path) => {
      assert.equal(
        path.replaceAll("\\", "/"),
        `${projectDirectory}/${notificationStagingConfigName}`,
      );
      return config;
    },
    runCommand: async (command) => {
      commands.push(command);
      assert.equal(command.cwd, projectDirectory);
      assert.equal(command.executable, process.execPath);
      assert.equal(
        command.args[0].replaceAll("\\", "/"),
        `${projectDirectory}/node_modules/wrangler/bin/wrangler.js`,
      );
      assert.equal(command.args.includes("npx"), false);
      assert.equal(command.args.includes("npx.cmd"), false);
      assert.equal(command.args.includes("--no-install"), false);
      assert.equal(command.args.includes("--remote"), true);
      assert.equal(command.args.includes("--json"), true);
      assert.equal(command.args.includes("--local"), false);
      assert.equal(command.args.includes("--file"), false);
      assert.equal(command.args.includes("--config"), true);
      assert.equal(
        command.args.at(command.args.indexOf("--config") + 1).replaceAll("\\", "/"),
        `${projectDirectory}/${notificationStagingConfigName}`,
      );
      const query = notificationStatusQueries.find((entry) => command.args.includes(entry.sql));
      assert.notEqual(query, undefined);
      return responses.get(query.name);
    },
  });
  assert.equal(commands.length, 4);
  assert.deepEqual(status, {
    "route-schema": [{ state: "ready" }],
    subscriptions: [{ environment: "production", count: 2 }],
    events: [{ kind: "new_moment", count: 1 }],
    deliveries: [{ state: "accepted", status: "200", reason: "none", count: 1 }],
  });
  const text = formatNotificationStagingStatus(status);
  assert.match(text, /route_schema: ready/u);
  assert.match(text, /production=2/u);
  assert.match(text, /accepted\/200\/none=1/u);
  assert.doesNotMatch(text, /must-not-pass-through/u);
});

test("rejects unreviewed databases and SQL before starting Wrangler", () => {
  assert.doesNotThrow(() => requireNoStatusArguments([]));
  assert.throws(
    () => requireNoStatusArguments(["--command", "DELETE FROM notification_events"]),
    /accepts no arguments/u,
  );
  assert.throws(
    () => notificationStatusCommand({
      projectDirectory,
      databaseName: "other-database",
      sql: notificationStatusQueries[0].sql,
    }),
    /only the isolated staging database/u,
  );
  assert.throws(
    () => notificationStatusCommand({
      projectDirectory,
      databaseName: "neko-window-sharing-staging",
      sql: "DELETE FROM notification_events",
    }),
    /only reviewed read-only queries/u,
  );
});

test("rejects malformed or raw provider output without rendering it", async () => {
  const config = renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
  });
  await assert.rejects(
    collectNotificationStagingStatus({
      projectDirectory,
      readFileImpl: async () => config,
      runCommand: async () => successfulRows([{
        environment: "production",
        count: 2,
        token_ciphertext: "must-not-pass-through",
      }]),
    }),
    /unexpected response|unexpected category|unexpected fields/u,
  );
});

test("fails closed when the applied route schema is missing or invalid", async () => {
  const config = renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
  });
  await assert.rejects(
    collectNotificationStagingStatus({
      projectDirectory,
      readFileImpl: async () => config,
      runCommand: async (command) => {
        const query = notificationStatusQueries.find((entry) => command.args.includes(entry.sql));
        if (query?.name === "route-schema") {
          return successfulRows([{ invalid_count: 1, normalizer_count: 1 }]);
        }
        throw new Error("later queries must not run after a schema failure");
      },
    }),
    /route schema contains invalid rows/u,
  );
});

test("fails closed when the rollback normalizer trigger is missing", async () => {
  const config = renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
  });
  await assert.rejects(
    collectNotificationStagingStatus({
      projectDirectory,
      readFileImpl: async () => config,
      runCommand: async (command) => {
        const query = notificationStatusQueries.find((entry) => command.args.includes(entry.sql));
        if (query?.name === "route-schema") {
          return successfulRows([{ invalid_count: 0, normalizer_count: 0 }]);
        }
        throw new Error("later queries must not run after a schema failure");
      },
    }),
    /route schema normalizer is unavailable/u,
  );
});
