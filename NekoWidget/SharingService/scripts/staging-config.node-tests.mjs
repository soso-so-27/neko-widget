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
};

test("renders an isolated staging config with the moment runtime off", () => {
  const rendered = renderStagingConfig(template, fixtureEnvironment);
  const config = JSON.parse(rendered);
  assert.equal(config.name, "neko-window-sharing-staging");
  assert.equal(config.workers_dev, true);
  assert.equal(config.preview_urls, false);
  assert.equal(config.vars.ENVIRONMENT, "staging");
  assert.equal(config.vars.MOMENT_RUNTIME_ENABLED, "NO");
  assert.equal(config.vars.LEGACY_SHARING_RUNTIME_ENABLED, "NO");
  assert.equal(config.limits, undefined);
  assert.equal(config.d1_databases[0].database_name, "neko-window-sharing-staging");
  assert.notEqual(config.r2_buckets[0].bucket_name, config.r2_buckets[1].bucket_name);
  assert.equal(new Set(config.ratelimits.map((value) => value.namespace_id)).size, 3);
});

test("derives the media test-window config by changing only the moment runtime", () => {
  const offConfig = JSON.parse(renderStagingConfig(template, fixtureEnvironment));
  const onConfig = JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
  }));
  assert.equal(onConfig.vars.MOMENT_RUNTIME_ENABLED, "YES");
  assert.equal(onConfig.vars.LEGACY_SHARING_RUNTIME_ENABLED, "NO");
  onConfig.vars.MOMENT_RUNTIME_ENABLED = "NO";
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
  const repositoryIgnore = await readFile(join(projectDirectory, "..", "..", ".gitignore"), "utf8");
  assert.match(repositoryIgnore, /^\.wrangler\/$/mu);
});

test("keeps trigger migrations compatible with Cloudflare remote apply", async () => {
  const expectedStatementCounts = new Map([
    ["0001_pairing.sql", 37],
    ["0002_daily_sharing.sql", 52],
    ["0003_append_only_moments.sql", 72],
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
