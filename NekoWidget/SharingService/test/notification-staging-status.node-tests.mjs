import assert from "node:assert/strict";
import test from "node:test";

import {
  collectNotificationStagingStatus,
  formatNotificationStagingStatus,
  notificationStagingConfigName,
  notificationStatusCommand,
  notificationStatusQueries,
  requireNoStatusArguments,
} from "../scripts/notification-staging-status-lib.mjs";
import { renderStagingConfig } from "../scripts/staging-config-lib.mjs";

const projectDirectory = "/safe/neko-widget/SharingService";
const fixtureEnvironment = {
  NEKO_STAGING_D1_DATABASE_ID: "00000000-0000-0000-0000-000000000000",
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
};
const template = JSON.stringify({
  name: "neko-window-sharing-staging",
  main: "src/index.ts",
  compatibility_date: "2026-08-17",
  workers_dev: true,
  preview_urls: false,
  observability: { enabled: false, logs: { enabled: false } },
  vars: {
    ENVIRONMENT: "staging",
    MOMENT_RUNTIME_ENABLED: "NO",
    REACTION_RUNTIME_ENABLED: "NO",
    WINDOW_NAME_RUNTIME_ENABLED: "NO",
    APNS_RUNTIME_ENABLED: "NO",
    LEGACY_SHARING_RUNTIME_ENABLED: "NO",
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
  ],
});

function successfulRows(rows) {
  return JSON.stringify([{ success: true, results: rows }]);
}

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
