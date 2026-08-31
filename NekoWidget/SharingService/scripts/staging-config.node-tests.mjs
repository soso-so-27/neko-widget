import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { unstable_splitSqlQuery } from "wrangler";

import { renderStagingConfig, validateStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(scriptDirectory, "..");
const template = await readFile(join(projectDirectory, "wrangler.staging.template.jsonc"), "utf8");

const fixtureEnvironment = {
  NEKO_STAGING_D1_DATABASE_ID: "00000000-0000-0000-0000-000000000000",
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
  NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID: "700004",
};

test("renders an isolated staging config with the moment runtime off", () => {
  const rendered = renderStagingConfig(template, fixtureEnvironment);
  const config = JSON.parse(rendered);
  assert.equal(config.name, "neko-window-sharing-staging");
  assert.equal(config.workers_dev, true);
  assert.equal(config.preview_urls, false);
  assert.equal(config.vars.ENVIRONMENT, "staging");
  assert.equal(config.vars.MOMENT_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.REACTION_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.WINDOW_NAME_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.APNS_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.REPORT_INGESTION_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.LEGACY_SHARING_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.BILLING_APPLE_NOTIFICATION_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.BILLING_ACCOUNT_RECOVERY_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED, "NO");
  assert.equal(config.limits, undefined);
  assert.equal(config.d1_databases[0].database_name, "neko-window-sharing-staging");
  assert.notEqual(config.r2_buckets[0].bucket_name, config.r2_buckets[1].bucket_name);
  assert.equal(new Set(config.ratelimits.map((value) => value.namespace_id)).size, 4);
});

test("derives the media test-window config by enabling all private media runtimes", () => {
  const offConfig = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
  const onConfig = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
  }));
  assert.equal(onConfig.vars.MOMENT_RUNTIME_ENABLED, "YES");
  assert.equal(onConfig.vars.REACTION_RUNTIME_ENABLED, "YES");
  assert.equal(onConfig.vars.WINDOW_NAME_RUNTIME_ENABLED, "YES");
  assert.equal(onConfig.vars.LEGACY_SHARING_RUNTIME_ENABLED, "NO");
  onConfig.vars.MOMENT_RUNTIME_ENABLED = "NO";
  onConfig.vars.REACTION_RUNTIME_ENABLED = "NO";
  onConfig.vars.WINDOW_NAME_RUNTIME_ENABLED = "NO";
  assert.deepEqual(onConfig, offConfig);
});

test("requires an explicit media policy when validating the moment runtime on", () => {
  const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
  }));
  assert.throws(() => validateStagingConfig(config), /reviewed staging policy/u);
  assert.doesNotThrow(() => validateStagingConfig(config, {
    expectedMomentRuntime: "YES",
  }));
});

test("never permits the legacy sharing runtime in a media test window", () => {
  const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
  }));
  config.vars.LEGACY_SHARING_RUNTIME_ENABLED = "YES";
  assert.throws(
    () => validateStagingConfig(config, { expectedMomentRuntime: "YES" }),
    /reviewed staging policy/u,
  );
});

test("rejects custom Worker limits that would require a paid plan", () => {
  const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
  config.limits = { cpu_ms: 30000, subrequests: 1200 };
  assert.throws(() => validateStagingConfig(config), /account plan defaults/u);
});

test("rejects a staging config that enables the moment runtime", () => {
  const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
  config.vars.MOMENT_RUNTIME_ENABLED = "YES";
  assert.throws(() => validateStagingConfig(config), /reviewed staging policy/u);
});

test("rejects every unreviewed top-level Wrangler capability", () => {
  for (const [field, value] of [
    ["services", [{ binding: "OTHER", service: "other-worker" }]],
    ["durable_objects", { bindings: [] }],
    ["queues", { producers: [] }],
    ["assets", { directory: "./public" }],
  ]) {
    const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
    config[field] = value;
    assert.throws(
      () => validateStagingConfig(config),
      /staging Wrangler configuration contains an unreviewed field/u,
    );
  }
});

test("rejects unreviewed fields inside every resource binding", () => {
  const mutations = [
    (config) => { config.d1_databases[0].preview_database_id = "unreviewed"; },
    (config) => { config.r2_buckets[0].jurisdiction = "eu"; },
    (config) => { config.ratelimits[0].extra = true; },
  ];
  for (const mutate of mutations) {
    const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
    mutate(config);
    assert.throws(
      () => validateStagingConfig(config),
      /contains an unreviewed field/u,
    );
  }
});

test("derives a notification window only with all private media runtimes enabled", () => {
  const offConfig = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
  const onConfig = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
  }));
  assert.equal(onConfig.vars.MOMENT_RUNTIME_ENABLED, "YES");
  assert.equal(onConfig.vars.REACTION_RUNTIME_ENABLED, "YES");
  assert.equal(onConfig.vars.WINDOW_NAME_RUNTIME_ENABLED, "YES");
  assert.equal(onConfig.vars.APNS_RUNTIME_ENABLED, "YES");
  assert.equal(onConfig.vars.REPORT_INGESTION_RUNTIME_ENABLED, "NO");
  onConfig.vars.MOMENT_RUNTIME_ENABLED = "NO";
  onConfig.vars.REACTION_RUNTIME_ENABLED = "NO";
  onConfig.vars.WINDOW_NAME_RUNTIME_ENABLED = "NO";
  onConfig.vars.APNS_RUNTIME_ENABLED = "NO";
  assert.deepEqual(onConfig, offConfig);
  assert.throws(
    () => renderStagingConfig(template, fixtureEnvironment, { expectedAPNSRuntime: "YES" }),
    /requires the reviewed private media runtimes/u,
  );
});

test("derives a report-ingestion window independently from APNs", () => {
  const offConfig = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
  const reportConfig = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedReportIngestionRuntime: "YES",
  }));
  assert.equal(reportConfig.vars.REPORT_INGESTION_RUNTIME_ENABLED, "YES");
  assert.equal(reportConfig.vars.MOMENT_RUNTIME_ENABLED, "NO");
  assert.equal(reportConfig.vars.REACTION_RUNTIME_ENABLED, "NO");
  assert.equal(reportConfig.vars.WINDOW_NAME_RUNTIME_ENABLED, "NO");
  assert.equal(reportConfig.vars.APNS_RUNTIME_ENABLED, "NO");
  reportConfig.vars.REPORT_INGESTION_RUNTIME_ENABLED = "NO";
  assert.deepEqual(reportConfig, offConfig);
});

test("derives exact general-distribution selective OFF candidates", () => {
  const general = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
  }));
  const apnsOff = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
  }));
  const reportOff = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
  }));
  const mediaOff = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedReportIngestionRuntime: "YES",
  }));

  const normalizedAPNs = structuredClone(general);
  normalizedAPNs.vars.APNS_RUNTIME_ENABLED = "NO";
  assert.deepEqual(normalizedAPNs, apnsOff);
  const normalizedReport = structuredClone(general);
  normalizedReport.vars.REPORT_INGESTION_RUNTIME_ENABLED = "NO";
  assert.deepEqual(normalizedReport, reportOff);
  const normalizedMedia = structuredClone(general);
  normalizedMedia.vars.MOMENT_RUNTIME_ENABLED = "NO";
  normalizedMedia.vars.REACTION_RUNTIME_ENABLED = "NO";
  normalizedMedia.vars.WINDOW_NAME_RUNTIME_ENABLED = "NO";
  normalizedMedia.vars.APNS_RUNTIME_ENABLED = "NO";
  assert.deepEqual(normalizedMedia, mediaOff);
});

test("rejects a staging config that enables only reactions", () => {
  const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
  config.vars.REACTION_RUNTIME_ENABLED = "YES";
  assert.throws(() => validateStagingConfig(config), /reviewed staging policy/u);
});

test("rejects a staging config that enables only private window-name sync", () => {
  const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
  config.vars.WINDOW_NAME_RUNTIME_ENABLED = "YES";
  assert.throws(() => validateStagingConfig(config), /reviewed staging policy/u);
});

test("rejects a media config that leaves private window-name sync off", () => {
  const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
  }));
  config.vars.WINDOW_NAME_RUNTIME_ENABLED = "NO";
  assert.throws(
    () => validateStagingConfig(config, { expectedMomentRuntime: "YES" }),
    /reviewed staging policy/u,
  );
});

test("rejects a media config that leaves reactions off", () => {
  const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
  }));
  config.vars.REACTION_RUNTIME_ENABLED = "NO";
  assert.throws(
    () => validateStagingConfig(config, { expectedMomentRuntime: "YES" }),
    /reviewed staging policy/u,
  );
});

test("rejects a staging config that enables the legacy sharing runtime", () => {
  const config = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
  config.vars.LEGACY_SHARING_RUNTIME_ENABLED = "YES";
  assert.throws(() => validateStagingConfig(config), /reviewed staging policy/u);
});

test("rejects shared rate limit namespace IDs", () => {
  assert.throws(
    () => renderStagingConfig(template, {
      ...fixtureEnvironment,
      NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID:
        fixtureEnvironment.NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID,
    }),
    /different account-unique namespace ID/u,
  );
});

test("requires every account-specific identifier at render time", () => {
  const missing = { ...fixtureEnvironment };
  delete missing.NEKO_STAGING_D1_DATABASE_ID;
  assert.throws(
    () => renderStagingConfig(template, missing),
    /NEKO_STAGING_D1_DATABASE_ID is required/u,
  );
});

test("keeps the generated staging config out of git", async () => {
  const ignore = await readFile(join(projectDirectory, ".gitignore"), "utf8");
  assert.match(ignore, /^wrangler\.staging\.jsonc$/mu);
  assert.match(ignore, /^wrangler\.media-staging-on\.jsonc$/mu);
  assert.match(ignore, /^wrangler\.notification-staging-on\.jsonc$/mu);
  assert.match(ignore, /^wrangler\.report-ingestion-staging-on\.jsonc$/mu);
  assert.match(ignore, /^wrangler\.general-staging-on\.jsonc$/mu);
  assert.match(ignore, /^wrangler\.general-staging-apns-off\.jsonc$/mu);
  const repositoryIgnore = await readFile(join(projectDirectory, "..", "..", ".gitignore"), "utf8");
  assert.match(repositoryIgnore, /^\.wrangler\/$/mu);
});

test("keeps trigger migrations compatible with Cloudflare remote apply", async () => {
  const expectedStatementCounts = new Map([
    ["0001_pairing.sql", 37],
    ["0002_daily_sharing.sql", 52],
    ["0003_append_only_moments.sql", 72],
    ["0004_encrypted_window_name.sql", 12],
    ["0005_device_recovery.sql", 20],
    ["0006_paw_reactions.sql", 15],
    ["0007_apns_notifications.sql", 19],
    ["0008_additional_participant_devices.sql", 7],
    ["0009_multi_window_apns_tokens.sql", 21],
    ["0010_multi_device_shared_data.sql", 7],
    ["0011_apns_route_schema.sql", 5],
    ["0012_moderation_case_lifecycle.sql", 11],
    ["0013_moderation_operator_control_plane.sql", 48],
    ["0014_moderation_evidence_ledger.sql", 10],
    ["0015_moderation_operator_routes.sql", 32],
    ["0016_moderation_operator_access_audit.sql", 45],
    ["0017_moderation_operator_enrollment_trust.sql", 39],
    ["0018_moderation_operator_case_reference_binding.sql", 21],
  ]);
  for (const [name, expectedStatementCount] of expectedStatementCounts) {
    const migration = await readFile(join(projectDirectory, "migrations", name));
    assert.equal(
      migration.includes(13),
      false,
      `${name} contains CR bytes; Wrangler remote trigger migrations require LF`,
    );
    const sql = migration.toString("utf8");
    assert.doesNotMatch(
      sql,
      /(?<!\()CASE\b/u,
      `${name} has an unparenthesized CASE expression that Cloudflare can misparse`,
    );
    assert.equal(
      unstable_splitSqlQuery(sql).length,
      expectedStatementCount,
      `${name} is not split into the reviewed statement count`,
    );
  }
});
