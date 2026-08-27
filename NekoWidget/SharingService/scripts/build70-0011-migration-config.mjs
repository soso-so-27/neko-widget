#!/usr/bin/env node

import { readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

import {
  build70MigrationBaseConfigName,
  build70MigrationConfigName,
  build70MigrationDirectory,
  parseBuild70MigrationConfigArguments,
  renderBuild70MigrationConfig,
  validateBuild70MigrationConfigText,
  validateBuild70MigrationInputs,
} from "./build70-0011-migration-config-lib.mjs";

const projectDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");

try {
  const mode = parseBuild70MigrationConfigArguments(process.argv.slice(2));
  const baseConfigPath = join(projectDirectory, build70MigrationBaseConfigName);
  const outputPath = join(projectDirectory, build70MigrationConfigName);
  const migrationsPath = join(projectDirectory, build70MigrationDirectory);
  const [
    baseConfigText,
    declaredPackageText,
    ignoreText,
    installedPackageText,
    migrationEntries,
    schemaText,
  ] = await Promise.all([
    readFile(baseConfigPath, "utf8"),
    readFile(join(projectDirectory, "package.json"), "utf8"),
    readFile(join(projectDirectory, ".gitignore"), "utf8"),
    readFile(join(projectDirectory, "node_modules", "wrangler", "package.json"), "utf8"),
    readdir(migrationsPath, { withFileTypes: true }),
    readFile(join(projectDirectory, "node_modules", "wrangler", "config-schema.json"), "utf8"),
  ]);
  validateBuild70MigrationInputs({
    baseConfigText,
    declaredPackageText,
    ignoreText,
    installedPackageText,
    migrationFileNames: migrationEntries.filter((entry) => entry.isFile()).map((entry) => entry.name),
    schemaText,
  });

  if (mode === "render") {
    const rendered = renderBuild70MigrationConfig(baseConfigText);
    await writeFile(outputPath, rendered, { encoding: "utf8", flag: "wx", mode: 0o600 });
    console.log("Created ignored Build 70 migration config selecting only migration 0011.");
    console.log("No Cloudflare query, migration, upload, or deployment was performed.");
  } else {
    const derivedConfigText = await readFile(outputPath, "utf8");
    validateBuild70MigrationConfigText(baseConfigText, derivedConfigText);
    console.log("Build 70 migration config preflight: PASS (exact migration 0011 only).");
    console.log("No Cloudflare query, migration, upload, or deployment was performed.");
  }
} catch (error) {
  console.error(
    `Build 70 migration config: FAIL: ${error instanceof Error ? error.message : "unknown error"}`,
  );
  process.exitCode = 1;
}
