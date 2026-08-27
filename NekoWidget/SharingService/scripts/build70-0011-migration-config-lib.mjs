import { isDeepStrictEqual } from "node:util";

import { validateStagingConfig } from "./staging-config-lib.mjs";

export const build70MigrationBaseConfigName = "wrangler.notification-staging-on.jsonc";
export const build70MigrationConfigName = ".wrangler-build70-0011.jsonc";
export const build70MigrationDirectory = "migrations";
export const build70MigrationName = "0011_apns_route_schema.sql";
export const build70MigrationPattern = `${build70MigrationDirectory}/${build70MigrationName}`;
export const reviewedWranglerVersion = "4.125.0";

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function parseJson(text, label) {
  try {
    const value = JSON.parse(text);
    if (!isRecord(value)) throw new Error();
    return value;
  } catch {
    throw new Error(`${label} is unavailable or invalid`);
  }
}

function schemaSupportsMigrationPattern(value) {
  if (Array.isArray(value)) {
    return value.some(schemaSupportsMigrationPattern);
  }
  if (!isRecord(value)) return false;
  if (
    isRecord(value.properties)
    && isRecord(value.properties.migrations_dir)
    && value.properties.migrations_dir.type === "string"
    && isRecord(value.properties.migrations_pattern)
    && value.properties.migrations_pattern.type === "string"
  ) {
    return true;
  }
  return Object.values(value).some(schemaSupportsMigrationPattern);
}

export function validatePinnedWranglerSchema({
  declaredPackage,
  installedPackage,
  schema,
}) {
  if (
    !isRecord(declaredPackage)
    || !isRecord(declaredPackage.devDependencies)
    || declaredPackage.devDependencies.wrangler !== reviewedWranglerVersion
    || !isRecord(installedPackage)
    || installedPackage.version !== reviewedWranglerVersion
  ) {
    throw new Error(`reviewed Wrangler ${reviewedWranglerVersion} is required`);
  }
  if (!isRecord(schema) || !schemaSupportsMigrationPattern(schema)) {
    throw new Error("reviewed Wrangler schema does not support D1 migrations_pattern");
  }
}

export function validateBuild70MigrationInventory(relativeFileNames) {
  if (
    !Array.isArray(relativeFileNames)
    || relativeFileNames.some((name) => typeof name !== "string")
  ) {
    throw new Error("migration inventory is unavailable or invalid");
  }
  const selected = relativeFileNames.filter(
    (name) => `${build70MigrationDirectory}/${name}` === build70MigrationPattern,
  );
  if (selected.length !== 1 || selected[0] !== build70MigrationName) {
    throw new Error("Build 70 migration pattern must resolve to exactly canonical migration 0011");
  }
  return Object.freeze([...selected]);
}

function validateBaseConfig(baseConfig) {
  validateStagingConfig(baseConfig, {
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
    expectedReportIngestionRuntime: "NO",
  });
  const binding = baseConfig.d1_databases[0];
  if (
    binding.migrations_dir !== build70MigrationDirectory
    || Object.hasOwn(binding, "migrations_pattern")
  ) {
    throw new Error("notification staging base config has an unexpected migration selector");
  }
}

export function deriveBuild70MigrationConfig(baseConfigInput) {
  if (!isRecord(baseConfigInput)) {
    throw new Error("notification staging base config is unavailable or invalid");
  }
  validateBaseConfig(baseConfigInput);
  const derived = structuredClone(baseConfigInput);
  derived.d1_databases[0].migrations_pattern = build70MigrationPattern;
  validateBuild70MigrationConfig(baseConfigInput, derived);
  return derived;
}

export function validateBuild70MigrationConfig(baseConfigInput, derivedConfigInput) {
  if (!isRecord(baseConfigInput) || !isRecord(derivedConfigInput)) {
    throw new Error("Build 70 migration configuration is unavailable or invalid");
  }
  validateBaseConfig(baseConfigInput);
  const binding = derivedConfigInput.d1_databases?.[0];
  if (
    !isRecord(binding)
    || binding.migrations_pattern !== build70MigrationPattern
    || Object.keys(binding).sort().join("\n")
      !== [
        "binding",
        "database_id",
        "database_name",
        "migrations_dir",
        "migrations_pattern",
      ].sort().join("\n")
  ) {
    throw new Error("Build 70 migration configuration has an unexpected selector or D1 binding");
  }
  const normalized = structuredClone(derivedConfigInput);
  delete normalized.d1_databases[0].migrations_pattern;
  if (!isDeepStrictEqual(normalized, baseConfigInput)) {
    throw new Error("Build 70 migration configuration may differ only by the exact 0011 selector");
  }
}

export function renderBuild70MigrationConfig(baseConfigText) {
  const baseConfig = parseJson(baseConfigText, "notification staging base config");
  return `${JSON.stringify(deriveBuild70MigrationConfig(baseConfig), null, 2)}\n`;
}

export function validateBuild70MigrationConfigText(baseConfigText, derivedConfigText) {
  const baseConfig = parseJson(baseConfigText, "notification staging base config");
  const derivedConfig = parseJson(derivedConfigText, "Build 70 migration configuration");
  validateBuild70MigrationConfig(baseConfig, derivedConfig);
}

export function validateBuild70MigrationIgnoreFile(ignoreText) {
  if (typeof ignoreText !== "string") {
    throw new Error("SharingService gitignore is unavailable");
  }
  for (const name of [build70MigrationBaseConfigName, build70MigrationConfigName]) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
    if (!new RegExp(`^${escaped}$`, "mu").test(ignoreText)) {
      throw new Error(`reviewed ignored config entry is missing: ${name}`);
    }
  }
}

export function validateBuild70MigrationInputs({
  baseConfigText,
  declaredPackageText,
  ignoreText,
  installedPackageText,
  migrationFileNames,
  schemaText,
}) {
  const baseConfig = parseJson(baseConfigText, "notification staging base config");
  validateBaseConfig(baseConfig);
  validatePinnedWranglerSchema({
    declaredPackage: parseJson(declaredPackageText, "SharingService package"),
    installedPackage: parseJson(installedPackageText, "installed Wrangler package"),
    schema: parseJson(schemaText, "installed Wrangler schema"),
  });
  validateBuild70MigrationInventory(migrationFileNames);
  validateBuild70MigrationIgnoreFile(ignoreText);
  return baseConfig;
}

export function parseBuild70MigrationConfigArguments(argv) {
  if (
    !Array.isArray(argv)
    || argv.length !== 1
    || (argv[0] !== "--render" && argv[0] !== "--check")
  ) {
    throw new Error("use exactly --render or --check");
  }
  return argv[0].slice(2);
}
