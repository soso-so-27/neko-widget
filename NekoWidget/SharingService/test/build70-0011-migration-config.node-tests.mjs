import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

import {
  build70MigrationConfigName,
  build70MigrationName,
  build70MigrationPattern,
  deriveBuild70MigrationConfig,
  parseBuild70MigrationConfigArguments,
  renderBuild70MigrationConfig,
  validateBuild70MigrationConfig,
  validateBuild70MigrationConfigText,
  validateBuild70MigrationIgnoreFile,
  validateBuild70MigrationInputs,
  validateBuild70MigrationInventory,
  validatePinnedWranglerSchema,
} from "../scripts/build70-0011-migration-config-lib.mjs";
import { renderStagingConfig } from "../scripts/staging-config-lib.mjs";

const projectDirectory = join(import.meta.dirname, "..");
const template = await readFile(join(projectDirectory, "wrangler.staging.template.jsonc"), "utf8");
const fixtureEnvironment = {
  NEKO_STAGING_D1_DATABASE_ID: "00000000-0000-4000-8000-000000000000",
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
  NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID: "700004",
};

function baseConfig() {
  return JSON.parse(renderStagingConfig(template, fixtureEnvironment, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
  }));
}

test("derives only the exact migration 0011 selector", () => {
  const base = baseConfig();
  const derived = deriveBuild70MigrationConfig(base);
  assert.equal(derived.d1_databases[0].migrations_pattern, build70MigrationPattern);
  const normalized = structuredClone(derived);
  delete normalized.d1_databases[0].migrations_pattern;
  assert.deepEqual(normalized, base);
  assert.doesNotThrow(() => validateBuild70MigrationConfig(base, derived));
  assert.doesNotThrow(() => validateBuild70MigrationConfigText(
    JSON.stringify(base),
    renderBuild70MigrationConfig(JSON.stringify(base)),
  ));
});

test("rejects wildcard, extra migration, and any unrelated configuration delta", () => {
  const base = baseConfig();
  const wildcard = deriveBuild70MigrationConfig(base);
  wildcard.d1_databases[0].migrations_pattern = "migrations/*.sql";
  assert.throws(
    () => validateBuild70MigrationConfig(base, wildcard),
    /unexpected selector/u,
  );

  const extraBindingField = deriveBuild70MigrationConfig(base);
  extraBindingField.d1_databases[0].migrations_table = "d1_migrations";
  assert.throws(
    () => validateBuild70MigrationConfig(base, extraBindingField),
    /unexpected selector/u,
  );

  const changedRuntime = deriveBuild70MigrationConfig(base);
  changedRuntime.vars.APNS_RUNTIME_ENABLED = "NO";
  assert.throws(
    () => validateBuild70MigrationConfig(base, changedRuntime),
    /may differ only/u,
  );
});

test("exact pattern resolves to one canonical migration and cannot select 0012 through 0018", async () => {
  const entries = await readdir(join(projectDirectory, "migrations"), { withFileTypes: true });
  const files = entries.filter((entry) => entry.isFile()).map((entry) => entry.name);
  assert.deepEqual(validateBuild70MigrationInventory(files), [build70MigrationName]);
  assert.throws(
    () => validateBuild70MigrationInventory(files.filter((name) => name !== build70MigrationName)),
    /exactly canonical migration 0011/u,
  );
  assert.throws(
    () => validateBuild70MigrationInventory(["0012_moderation_case_lifecycle.sql"]),
    /exactly canonical migration 0011/u,
  );
});

test("requires the pinned Wrangler 4.125.0 schema with migrations_pattern support", async () => {
  const [declaredPackage, installedPackage, schema] = await Promise.all([
    readFile(join(projectDirectory, "package.json"), "utf8").then(JSON.parse),
    readFile(join(projectDirectory, "node_modules", "wrangler", "package.json"), "utf8").then(JSON.parse),
    readFile(join(projectDirectory, "node_modules", "wrangler", "config-schema.json"), "utf8").then(JSON.parse),
  ]);
  assert.doesNotThrow(() => validatePinnedWranglerSchema({
    declaredPackage, installedPackage, schema,
  }));
  assert.throws(
    () => validatePinnedWranglerSchema({
      declaredPackage,
      installedPackage: { ...installedPackage, version: "4.126.0" },
      schema,
    }),
    /4\.125\.0/u,
  );
  assert.throws(
    () => validatePinnedWranglerSchema({ declaredPackage, installedPackage, schema: {} }),
    /does not support/u,
  );
});

test("fixed local inputs are ignored and validate without executing Wrangler", async () => {
  const [declaredPackageText, ignoreText, installedPackageText, schemaText] = await Promise.all([
    readFile(join(projectDirectory, "package.json"), "utf8"),
    readFile(join(projectDirectory, ".gitignore"), "utf8"),
    readFile(join(projectDirectory, "node_modules", "wrangler", "package.json"), "utf8"),
    readFile(join(projectDirectory, "node_modules", "wrangler", "config-schema.json"), "utf8"),
  ]);
  const migrationEntries = await readdir(join(projectDirectory, "migrations"), { withFileTypes: true });
  assert.doesNotThrow(() => validateBuild70MigrationInputs({
    baseConfigText: JSON.stringify(baseConfig()),
    declaredPackageText,
    ignoreText,
    installedPackageText,
    migrationFileNames: migrationEntries.filter((entry) => entry.isFile()).map((entry) => entry.name),
    schemaText,
  }));
  assert.doesNotThrow(() => validateBuild70MigrationIgnoreFile(ignoreText));
  assert.match(ignoreText, new RegExp(`^\\${build70MigrationConfigName}$`, "mu"));
});

test("CLI accepts only local render or check modes", () => {
  assert.equal(parseBuild70MigrationConfigArguments(["--render"]), "render");
  assert.equal(parseBuild70MigrationConfigArguments(["--check"]), "check");
  for (const args of [[], ["--apply"], ["--render", "--remote"]]) {
    assert.throws(() => parseBuild70MigrationConfigArguments(args), /exactly --render or --check/u);
  }
});

test("CLI has no Cloudflare command or network execution path", async () => {
  const sources = await Promise.all([
    readFile(join(projectDirectory, "scripts", "build70-0011-migration-config.mjs"), "utf8"),
    readFile(join(projectDirectory, "scripts", "build70-0011-migration-config-lib.mjs"), "utf8"),
  ]);
  const source = sources.join("\n");
  assert.doesNotMatch(source, /node:(?:child_process|http|https|net|tls)/u);
  assert.doesNotMatch(source, /\bfetch\s*\(/u);
  assert.doesNotMatch(source, /--remote|d1\s+(?:execute|migrations)|versions\s+(?:upload|deploy)/u);
});
