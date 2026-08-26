import { spawn } from "node:child_process";
import process from "node:process";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { validateStagingConfig } from "./staging-config-lib.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
export const selectiveOffProjectDirectory = join(scriptDirectory, "..");
const reviewedWranglerVersion = "4.125.0";

export const selectiveOffPolicies = Object.freeze({
  apns: Object.freeze({
    sourceConfigName: "wrangler.general-staging-on.jsonc",
    targetConfigName: "wrangler.general-staging-apns-off.jsonc",
    offFlagNames: Object.freeze(["APNS_RUNTIME_ENABLED"]),
    confirmationArgument: "--confirm-apns-only-off",
    messageLabel: "APNs-only OFF",
    sourceOptions: Object.freeze({
      expectedMomentRuntime: "YES",
      expectedAPNSRuntime: "YES",
      expectedReportIngestionRuntime: "YES",
    }),
    targetOptions: Object.freeze({
      expectedMomentRuntime: "YES",
      expectedReportIngestionRuntime: "YES",
    }),
  }),
  "report-ingestion": Object.freeze({
    sourceConfigName: "wrangler.general-staging-on.jsonc",
    targetConfigName: "wrangler.notification-staging-on.jsonc",
    offFlagNames: Object.freeze(["REPORT_INGESTION_RUNTIME_ENABLED"]),
    confirmationArgument: "--confirm-report-ingestion-only-off",
    messageLabel: "report-ingestion-only OFF",
    sourceOptions: Object.freeze({
      expectedMomentRuntime: "YES",
      expectedAPNSRuntime: "YES",
      expectedReportIngestionRuntime: "YES",
    }),
    targetOptions: Object.freeze({
      expectedMomentRuntime: "YES",
      expectedAPNSRuntime: "YES",
    }),
  }),
  media: Object.freeze({
    sourceConfigName: "wrangler.general-staging-on.jsonc",
    targetConfigName: "wrangler.report-ingestion-staging-on.jsonc",
    offFlagNames: Object.freeze([
      "MOMENT_RUNTIME_ENABLED",
      "REACTION_RUNTIME_ENABLED",
      "WINDOW_NAME_RUNTIME_ENABLED",
      "APNS_RUNTIME_ENABLED",
    ]),
    confirmationArgument: "--confirm-media-only-off",
    messageLabel: "media-only OFF",
    sourceOptions: Object.freeze({
      expectedMomentRuntime: "YES",
      expectedAPNSRuntime: "YES",
      expectedReportIngestionRuntime: "YES",
    }),
    targetOptions: Object.freeze({
      expectedReportIngestionRuntime: "YES",
    }),
  }),
});

function requirePolicy(kind) {
  const policy = selectiveOffPolicies[kind];
  if (policy === undefined) {
    throw new Error("selective staging OFF policy is unsupported");
  }
  return policy;
}

export function parseSelectiveOffArguments(kind, argv) {
  const policy = requirePolicy(kind);
  if (!Array.isArray(argv) || argv.length !== 1) {
    throw new Error(
      `use exactly --local-dry-run or ${policy.confirmationArgument}`,
    );
  }
  if (argv[0] === "--local-dry-run") {
    return Object.freeze({ dryRun: true });
  }
  if (argv[0] === policy.confirmationArgument) {
    return Object.freeze({ dryRun: false });
  }
  throw new Error(`use exactly --local-dry-run or ${policy.confirmationArgument}`);
}

function parseConfig(text, label) {
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${label} configuration is unavailable or invalid`);
  }
}

async function readReviewedConfig(readFileImpl, path, label) {
  try {
    return parseConfig(await readFileImpl(path, "utf8"), label);
  } catch (error) {
    if (error instanceof Error
        && error.message === `${label} configuration is unavailable or invalid`) {
      throw error;
    }
    throw new Error(`${label} configuration is unavailable or invalid`);
  }
}

function exactSerializedConfig(actual, expected, message) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(message);
  }
}

export function validateSelectiveOffConfigs(kind, sourceConfig, targetConfig) {
  const policy = requirePolicy(kind);
  validateStagingConfig(sourceConfig, policy.sourceOptions);
  validateStagingConfig(targetConfig, policy.targetOptions);
  const normalizedSource = structuredClone(sourceConfig);
  for (const flagName of policy.offFlagNames) {
    normalizedSource.vars[flagName] = "NO";
  }
  exactSerializedConfig(
    normalizedSource,
    targetConfig,
    `${policy.messageLabel} configs may differ only by its reviewed runtime flags`,
  );
  return Object.freeze({ sourceConfig, targetConfig, policy });
}

export function localWranglerCommand(projectDirectory, args) {
  if (typeof projectDirectory !== "string" || projectDirectory.length === 0) {
    throw new Error("selective staging OFF project directory is unavailable");
  }
  return Object.freeze({
    executable: process.execPath,
    args: Object.freeze([
      join(projectDirectory, "node_modules", "wrangler", "bin", "wrangler.js"),
      ...args,
    ]),
    cwd: projectDirectory,
  });
}

export function localOnlyWranglerEnvironment(environment = process.env) {
  return Object.freeze({
    ...environment,
    DO_NOT_TRACK: "1",
    WRANGLER_HIDE_BANNER: "true",
    WRANGLER_SEND_ERROR_REPORTS: "false",
    WRANGLER_SEND_METRICS: "false",
  });
}

export async function runSilentCommand(command) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command.executable, command.args, {
      cwd: command.cwd,
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
      env: localOnlyWranglerEnvironment(),
    });
    let stdout = "";
    let stderrBytes = 0;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (stdout.length > 4 * 1024 * 1024) {
        child.kill();
      }
    });
    child.stderr.on("data", (chunk) => {
      stderrBytes += chunk.length;
      if (stderrBytes > 4 * 1024 * 1024) {
        child.kill();
      }
    });
    child.on("error", () => rejectPromise(new Error("reviewed command could not start")));
    child.on("close", (code) => {
      if (code !== 0 || stdout.length > 4 * 1024 * 1024 || stderrBytes > 4 * 1024 * 1024) {
        rejectPromise(new Error("reviewed command failed"));
        return;
      }
      resolvePromise(stdout);
    });
  });
}

function dryRunCommand(projectDirectory, configPath) {
  return localWranglerCommand(projectDirectory, [
    "deploy", "--dry-run", "--config", configPath,
    "--autoconfig=false", "--experimental-provision=false",
    "--experimental-auto-create=false",
  ]);
}

export async function runSelectiveOffControl(kind, argv, {
  projectDirectory = selectiveOffProjectDirectory,
  readFileImpl = readFile,
  runCommand = runSilentCommand,
} = {}) {
  const policy = requirePolicy(kind);
  const mode = parseSelectiveOffArguments(kind, argv);
  const sourcePath = join(projectDirectory, policy.sourceConfigName);
  const targetPath = join(projectDirectory, policy.targetConfigName);
  const sourceConfig = await readReviewedConfig(
    readFileImpl,
    sourcePath,
    policy.messageLabel,
  );
  const targetConfig = await readReviewedConfig(
    readFileImpl,
    targetPath,
    policy.messageLabel,
  );
  validateSelectiveOffConfigs(kind, sourceConfig, targetConfig);

  const versionOutput = await runCommand(localWranglerCommand(projectDirectory, ["--version"]));
  if (!new RegExp(`\\b${reviewedWranglerVersion.replaceAll(".", "\\.")}\\b`, "u").test(versionOutput)) {
    throw new Error(`reviewed Wrangler ${reviewedWranglerVersion} is required`);
  }
  await runCommand(dryRunCommand(projectDirectory, targetPath));
  if (mode.dryRun) {
    return `PASS ${policy.messageLabel} dry-run; no deployment was performed.`;
  }
  throw new Error(
    `${policy.messageLabel} actual selective deployment is unavailable: `
      + "Wrangler deploy cannot atomically prove that code, triggers, bindings, "
      + "and the active version are unchanged. No repository command performs "
      + "an external staging OFF deployment.",
  );
}
