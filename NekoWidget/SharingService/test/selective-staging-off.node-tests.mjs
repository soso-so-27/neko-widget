import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import process from "node:process";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  createEmergencyOffSwitchPlan,
  localWranglerCommand,
  localOnlyWranglerEnvironment,
  parseSelectiveOffArguments,
  readEmergencyOffControlManifest,
  runSelectiveOffControl,
  validateEmergencyOffControlManifest,
  validateSelectiveOffConfigs,
} from "../scripts/selective-staging-off-lib.mjs";
import { renderStagingConfig } from "../scripts/staging-config-lib.mjs";

const testDirectory = dirname(fileURLToPath(import.meta.url));
const serviceDirectory = join(testDirectory, "..");
const template = await readFile(join(serviceDirectory, "wrangler.staging.template.jsonc"), "utf8");
const packageManifest = JSON.parse(
  await readFile(join(serviceDirectory, "package.json"), "utf8"),
);
const broadOffScriptPath = join(
  serviceDirectory,
  "scripts",
  "personal-staging-emergency-off-windows.ps1",
);
const broadOffScript = await readFile(broadOffScriptPath, "utf8");
const projectDirectory = "/safe/neko-widget/SharingService";
const fixtureEnvironment = {
  NEKO_STAGING_D1_DATABASE_ID: "00000000-0000-0000-0000-000000000000",
  NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID: "700001",
  NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID: "700002",
  NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID: "700003",
  NEKO_STAGING_BILLING_RATE_LIMIT_NAMESPACE_ID: "700004",
  NEKO_STAGING_BILLING_APPLE_NOTIFICATION_RATE_LIMIT_NAMESPACE_ID: "700005",
};
const emergencyOffManifest = Object.freeze({
  schemaVersion: 1,
  accountId: "0123456789abcdef0123456789abcdef",
  workerName: "neko-window-sharing-staging",
  origin: "https://neko-window-sharing-staging.example.workers.dev",
  expectedActiveVersionId: "11111111-1111-4111-8111-111111111111",
  preapprovedOffVersionId: "22222222-2222-4222-8222-222222222222",
});

function config(options = {}) {
  return JSON.parse(renderStagingConfig(template, fixtureEnvironment, options));
}

function fixtureReader(sourceName, sourceConfig, targetName, targetConfig) {
  return async (path) => {
    const normalized = path.replaceAll("\\", "/");
    if (normalized.endsWith(`/${sourceName}`)) return JSON.stringify(sourceConfig);
    if (normalized.endsWith(`/${targetName}`)) return JSON.stringify(targetConfig);
    throw new Error("unexpected fixture path");
  };
}

test("uses the current Node executable and reviewed local Wrangler entry point", () => {
  const command = localWranglerCommand(projectDirectory, ["--version"]);
  assert.equal(command.executable, process.execPath);
  assert.equal(
    command.args[0].replaceAll("\\", "/"),
    `${projectDirectory}/node_modules/wrangler/bin/wrangler.js`,
  );
  assert.equal(command.args.includes("npx"), false);
  assert.equal(command.args.includes("npx.cmd"), false);
});

test("local Wrangler commands suppress update checks, telemetry, and error reports", () => {
  assert.deepEqual(
    localOnlyWranglerEnvironment({ PATH: "fixture-path", WRANGLER_SEND_METRICS: "true" }),
    {
      PATH: "fixture-path",
      DO_NOT_TRACK: "1",
      WRANGLER_HIDE_BANNER: "true",
      WRANGLER_SEND_ERROR_REPORTS: "false",
      WRANGLER_SEND_METRICS: "false",
    },
  );
});

test("npm operator commands distinguish actual gate control from the legacy candidate dry-run", () => {
  for (const scriptName of [
    "staging:runtime:apns-off",
    "staging:runtime:report-ingestion-off",
    "staging:runtime:media-off",
  ]) {
    assert.match(packageManifest.scripts[scriptName], / --local-dry-run$/u);
    assert.doesNotMatch(packageManifest.scripts[scriptName], /--confirm-/u);
  }
  assert.match(
    packageManifest.scripts["staging:runtime:emergency-off-candidate:dry-run"],
    / -DryRun$/u,
  );
  assert.doesNotMatch(
    packageManifest.scripts["staging:runtime:emergency-off-candidate:dry-run"],
    /ConfirmPersonalStagingEmergencyOff/u,
  );
  assert.match(
    packageManifest.scripts["staging:runtime:emergency-off:confirm"],
    /--confirm-broad-off$/u,
  );
  assert.match(
    packageManifest.scripts["staging:runtime:recover:confirm"],
    /--confirm-build70-media-apns-on$/u,
  );
  assert.match(packageManifest.scripts["staging:runtime:status"], /--status$/u);
  assert.equal(packageManifest.scripts["staging:runtime:emergency-off"], undefined);
});

test("the legacy broad-OFF helper retains only a local dry-run path", () => {
  assert.match(
    broadOffScript,
    /\$wranglerEntryPoint deploy\s+`\r?\n\s*--dry-run/u,
  );
  for (const forbidden of [
    "npx.cmd",
    "--strict",
    "--keep-vars",
    "--remote",
    "expectedOrigin",
    "check-staging-runtime.mjs",
    "Start-Sleep",
    "origin/main",
    "deployed and publicly verified",
  ]) {
    assert.equal(broadOffScript.includes(forbidden), false, forbidden);
  }
  for (const required of [
    '$env:DO_NOT_TRACK = "1"',
    '$env:WRANGLER_HIDE_BANNER = "true"',
    '$env:WRANGLER_SEND_ERROR_REPORTS = "false"',
    '$env:WRANGLER_SEND_METRICS = "false"',
    "--validate-emergency-off-manifest",
    "emergency-off-control-manifest.json",
  ]) {
    assert.equal(broadOffScript.includes(required), true, required);
  }
});

test("binds the exact emergency OFF target and two distinct reviewed versions", async () => {
  assert.deepEqual(
    validateEmergencyOffControlManifest(emergencyOffManifest),
    emergencyOffManifest,
  );
  assert.deepEqual(
    await readEmergencyOffControlManifest(
      "/protected/emergency-off-control-manifest.json",
      async () => JSON.stringify(emergencyOffManifest),
    ),
    emergencyOffManifest,
  );

  for (const invalid of [
    { ...emergencyOffManifest, accountId: "not-an-account" },
    { ...emergencyOffManifest, workerName: "Unexpected Worker" },
    { ...emergencyOffManifest, origin: `${emergencyOffManifest.origin}/path` },
    { ...emergencyOffManifest, expectedActiveVersionId: "not-a-version" },
    {
      ...emergencyOffManifest,
      expectedActiveVersionId: "00000000-0000-0000-0000-000000000000",
    },
    {
      ...emergencyOffManifest,
      preapprovedOffVersionId: emergencyOffManifest.expectedActiveVersionId,
    },
    { ...emergencyOffManifest, apiToken: "must-not-be-accepted" },
  ]) {
    assert.throws(
      () => validateEmergencyOffControlManifest(invalid),
      /manifest|version|origin/u,
    );
  }
});

test("creates only a side-effect-free plan for the pre-approved existing OFF version", () => {
  const plan = createEmergencyOffSwitchPlan(emergencyOffManifest, {
    accountId: emergencyOffManifest.accountId,
    workerName: emergencyOffManifest.workerName,
    activeVersionId: emergencyOffManifest.expectedActiveVersionId,
  });
  assert.deepEqual(plan, {
    operation: "activate-existing-version",
    target: {
      accountId: emergencyOffManifest.accountId,
      workerName: emergencyOffManifest.workerName,
    },
    expectedActiveVersionId: emergencyOffManifest.expectedActiveVersionId,
    versionId: emergencyOffManifest.preapprovedOffVersionId,
    verification: {
      origin: emergencyOffManifest.origin,
      expected: "off",
    },
  });
  assert.equal(JSON.stringify(plan).includes("token"), false);
  assert.equal(JSON.stringify(plan).includes("email"), false);
  assert.equal(JSON.stringify(plan).includes("userId"), false);
});

test("refuses to create a switch plan for any active target mismatch", () => {
  const validSnapshot = {
    accountId: emergencyOffManifest.accountId,
    workerName: emergencyOffManifest.workerName,
    activeVersionId: emergencyOffManifest.expectedActiveVersionId,
  };
  for (const snapshot of [
    { ...validSnapshot, accountId: "fedcba9876543210fedcba9876543210" },
    { ...validSnapshot, workerName: "different-worker" },
    {
      ...validSnapshot,
      activeVersionId: "33333333-3333-4333-8333-333333333333",
    },
    { ...validSnapshot, extra: "unreviewed" },
  ]) {
    assert.throws(
      () => createEmergencyOffSwitchPlan(emergencyOffManifest, snapshot),
      (error) => {
        assert.match(error.message, /active version does not match/u);
        assert.equal(error.message.includes(String(snapshot.activeVersionId)), false);
        return true;
      },
    );
  }
});

test(
  "broad-OFF confirmation fails before resolving config or starting an external command",
  { skip: process.platform !== "win32" },
  () => {
    const result = spawnSync(
      "powershell.exe",
      [
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        broadOffScriptPath,
        "-ConfirmPersonalStagingEmergencyOff",
        "-ConfigDirectory",
        "Z:\\this-path-must-not-be-resolved",
      ],
      { encoding: "utf8", windowsHide: true },
    );
    assert.notEqual(result.status, 0);
    const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
    assert.match(output, /actual broad staging emergency OFF deployment is unavailable/u);
    assert.doesNotMatch(output, /Resolve-Path|cannot find path|Wrangler|Cloudflare/u);
  },
);

test("requires an exact dry-run or policy-specific actual confirmation", () => {
  assert.deepEqual(parseSelectiveOffArguments("apns", ["--local-dry-run"]), { dryRun: true });
  assert.deepEqual(
    parseSelectiveOffArguments("report-ingestion", ["--confirm-report-ingestion-only-off"]),
    { dryRun: false },
  );
  assert.deepEqual(
    parseSelectiveOffArguments("media", ["--confirm-media-only-off"]),
    { dryRun: false },
  );
  assert.throws(() => parseSelectiveOffArguments("apns", []), /use exactly/u);
  assert.throws(
    () => parseSelectiveOffArguments("apns", ["--dry-run"]),
    /--local-dry-run/u,
  );
  assert.throws(
    () => parseSelectiveOffArguments("apns", ["--confirm-report-ingestion-only-off"]),
    /confirm-apns-only-off/u,
  );
  assert.throws(
    () => parseSelectiveOffArguments("apns", ["--local-dry-run", "--confirm-apns-only-off"]),
    /use exactly/u,
  );
});

test("APNs-only OFF changes exactly APNS_RUNTIME_ENABLED", () => {
  const source = config({
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
  });
  const target = config({
    expectedMomentRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
  });
  assert.doesNotThrow(() => validateSelectiveOffConfigs("apns", source, target));
  target.vars.WINDOW_NAME_RUNTIME_ENABLED = "NO";
  assert.throws(
    () => validateSelectiveOffConfigs("apns", source, target),
    /reviewed staging policy|may differ only/u,
  );
});

test("report-ingestion-only OFF preserves media and APNs", () => {
  const source = config({
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
  });
  const target = config({ expectedMomentRuntime: "YES", expectedAPNSRuntime: "YES" });
  assert.equal(target.vars.MOMENT_RUNTIME_ENABLED, "YES");
  assert.equal(target.vars.APNS_RUNTIME_ENABLED, "YES");
  assert.doesNotThrow(() => validateSelectiveOffConfigs("report-ingestion", source, target));
  target.vars.APNS_RUNTIME_ENABLED = "NO";
  assert.throws(
    () => validateSelectiveOffConfigs("report-ingestion", source, target),
    /reviewed staging policy|may differ only/u,
  );
});

test("media-only OFF preserves report ingestion while stopping media and APNs", () => {
  const source = config({
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
  });
  const target = config({ expectedReportIngestionRuntime: "YES" });
  assert.equal(target.vars.REPORT_INGESTION_RUNTIME_ENABLED, "YES");
  assert.equal(target.vars.MOMENT_RUNTIME_ENABLED, "NO");
  assert.equal(target.vars.REACTION_RUNTIME_ENABLED, "NO");
  assert.equal(target.vars.WINDOW_NAME_RUNTIME_ENABLED, "NO");
  assert.equal(target.vars.APNS_RUNTIME_ENABLED, "NO");
  assert.doesNotThrow(() => validateSelectiveOffConfigs("media", source, target));
});

test("dry-runs each independent OFF config without any remote query or deployment", async () => {
  for (const fixture of [
    {
      kind: "apns",
      sourceName: "wrangler.general-staging-on.jsonc",
      source: config({
        expectedMomentRuntime: "YES",
        expectedAPNSRuntime: "YES",
        expectedReportIngestionRuntime: "YES",
      }),
      targetName: "wrangler.general-staging-apns-off.jsonc",
      target: config({
        expectedMomentRuntime: "YES",
        expectedReportIngestionRuntime: "YES",
      }),
    },
    {
      kind: "report-ingestion",
      sourceName: "wrangler.general-staging-on.jsonc",
      source: config({
        expectedMomentRuntime: "YES",
        expectedAPNSRuntime: "YES",
        expectedReportIngestionRuntime: "YES",
      }),
      targetName: "wrangler.notification-staging-on.jsonc",
      target: config({ expectedMomentRuntime: "YES", expectedAPNSRuntime: "YES" }),
    },
    {
      kind: "media",
      sourceName: "wrangler.general-staging-on.jsonc",
      source: config({
        expectedMomentRuntime: "YES",
        expectedAPNSRuntime: "YES",
        expectedReportIngestionRuntime: "YES",
      }),
      targetName: "wrangler.report-ingestion-staging-on.jsonc",
      target: config({ expectedReportIngestionRuntime: "YES" }),
    },
  ]) {
    const commands = [];
    const result = await runSelectiveOffControl(fixture.kind, ["--local-dry-run"], {
      projectDirectory,
      readFileImpl: fixtureReader(
        fixture.sourceName,
        fixture.source,
        fixture.targetName,
        fixture.target,
      ),
      runCommand: async (command) => {
        commands.push(command);
        assert.equal(command.executable, process.execPath);
        if (command.args.at(-1) === "--version") return "wrangler 4.125.0\n";
        assert.equal(command.args.includes("deploy"), true);
        assert.equal(command.args.includes("--dry-run"), true);
        assert.equal(command.args.includes("--strict"), false);
        return "local bundle built";
      },
    });
    assert.equal(commands.length, 2);
    assert.match(result, /dry-run; no deployment was performed/u);
  }
});

test("every actual selective OFF confirmation fails after local checks without remote access", async () => {
  const source = config({
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
  });
  const fixtures = [
    {
      kind: "apns",
      confirmation: "--confirm-apns-only-off",
      sourceName: "wrangler.general-staging-on.jsonc",
      targetName: "wrangler.general-staging-apns-off.jsonc",
      target: config({
        expectedMomentRuntime: "YES",
        expectedReportIngestionRuntime: "YES",
      }),
    },
    {
      kind: "report-ingestion",
      confirmation: "--confirm-report-ingestion-only-off",
      sourceName: "wrangler.general-staging-on.jsonc",
      targetName: "wrangler.notification-staging-on.jsonc",
      target: config({ expectedMomentRuntime: "YES", expectedAPNSRuntime: "YES" }),
    },
    {
      kind: "media",
      confirmation: "--confirm-media-only-off",
      sourceName: "wrangler.general-staging-on.jsonc",
      targetName: "wrangler.report-ingestion-staging-on.jsonc",
      target: config({ expectedReportIngestionRuntime: "YES" }),
    },
  ];

  for (const fixture of fixtures) {
    const commands = [];
    await assert.rejects(
      runSelectiveOffControl(fixture.kind, [fixture.confirmation], {
        projectDirectory,
        readFileImpl: fixtureReader(
          fixture.sourceName,
          source,
          fixture.targetName,
          fixture.target,
        ),
        runCommand: async (command) => {
          commands.push(command);
          assert.equal(command.executable, process.execPath);
          const args = command.args.slice(1);
          if (args[0] === "--version") return "wrangler 4.125.0\n";
          if (args[0] === "deploy" && args.includes("--dry-run")) return "local bundle built";
          throw new Error("unexpected non-local-check command");
        },
      }),
      /actual selective deployment is unavailable.*no repository command performs.*external staging OFF deployment/isu,
    );
    assert.equal(commands.length, 2);
    assert.deepEqual(commands.map((command) => command.args[1]), ["--version", "deploy"]);
    assert.equal(commands[1].args.includes("--dry-run"), true);
    assert.equal(commands[1].args.includes("--strict"), false);
    assert.equal(commands.some((command) => command.executable === "git"), false);
    assert.equal(
      commands.some((command) => command.args.includes("deployments")
        || command.args.includes("versions")),
      false,
    );
  }
});

test("actual confirmation cannot bypass exact local config validation", async () => {
  const source = config({
    expectedMomentRuntime: "YES",
    expectedAPNSRuntime: "YES",
    expectedReportIngestionRuntime: "YES",
  });
  const target = config({ expectedMomentRuntime: "YES", expectedAPNSRuntime: "YES" });
  target.r2_buckets[0].bucket_name = "unreviewed-bucket";
  let commandCount = 0;
  await assert.rejects(
    runSelectiveOffControl(
      "report-ingestion",
      ["--confirm-report-ingestion-only-off"],
      {
        projectDirectory,
        readFileImpl: fixtureReader(
          "wrangler.general-staging-on.jsonc",
          source,
          "wrangler.notification-staging-on.jsonc",
          target,
        ),
        runCommand: async () => {
          commandCount += 1;
          throw new Error("no command should run for an invalid config");
        },
      },
    ),
    /media bucket is not isolated|reviewed staging policy/u,
  );
  assert.equal(commandCount, 0);
});
