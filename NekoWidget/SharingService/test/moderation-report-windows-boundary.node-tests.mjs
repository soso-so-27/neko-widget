import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";
import {
  createWindowsModerationSecurityPlan,
  runWindowsModerationSecurityProof,
} from "../scripts/moderation-report-tool.mjs";

const ROOT = dirname(fileURLToPath(new URL("../package.json", import.meta.url)));
const TOOL = join(ROOT, "scripts", "moderation-report-tool.mjs");
const KEYGEN_LIBRARY = join(ROOT, "scripts", "moderation-staging-keygen-lib.mjs");
const SECURITY_HELPER = join(
  ROOT,
  "scripts",
  "moderation-staging-keygen-windows-security.ps1",
);
const TRUSTED_NODE_HELPER = join(
  ROOT,
  "scripts",
  "moderation-windows-trusted-node.ps1",
);
const WINDOWS_WRAPPER = join(ROOT, "scripts", "moderation-report-tool-windows.ps1");
const WINDOWS_WRAPPERS = [
  "moderation-staging-keygen-windows.ps1",
  "moderation-staging-drill-windows.ps1",
  "moderation-staging-drill-review-windows.ps1",
  "moderation-report-tool-windows.ps1",
].map((name) => join(ROOT, "scripts", name));
const PACKAGE_JSON = join(ROOT, "package.json");
const WINDOWS_WORKFLOW = fileURLToPath(new URL(
  "../../../.github/workflows/sharing-service.yml",
  import.meta.url,
));
const TEST_REVIEWED_SHA256 = "a".repeat(64);
const KEY_DIRECTORY = "C:\\NekoModeration\\keys";
const CASE_DIRECTORY = "C:\\NekoModeration\\case-001";
const SYNTHETIC_DIRECTORY = "C:\\NekoModeration\\synthetic-001";

function productionDecryptArgs(extra = []) {
  return [
    "decrypt",
    "--metadata", `${CASE_DIRECTORY}\\moderation-export.json`,
    "--ciphertext", `${CASE_DIRECTORY}\\moderation-report.ciphertext`,
    "--moderation-key-id", "moderation-v1",
    "--private-key", `${KEY_DIRECTORY}\\moderation-v1.private.raw`,
    "--expected-public-key-sha256", TEST_REVIEWED_SHA256,
    "--output", `${CASE_DIRECTORY}\\moderation-review.jpg`,
    "--audit-log", `${CASE_DIRECTORY}\\moderation-audit.jsonl`,
    ...extra,
  ];
}

function productionDeleteArgs(kind) {
  const plaintext = kind === "plaintext";
  return [
    "delete",
    "--metadata", `${CASE_DIRECTORY}\\moderation-export.json`,
    "--file", `${CASE_DIRECTORY}\\${plaintext ? "moderation-review.jpg" : "moderation-report.ciphertext"}`,
    "--kind", kind,
    ...(plaintext
      ? ["--receipt", `${CASE_DIRECTORY}\\moderation-review.jpg.receipt`]
      : []),
    "--moderation-key-id", "moderation-v1",
    "--private-key", `${KEY_DIRECTORY}\\moderation-v1.private.raw`,
    "--expected-public-key-sha256", TEST_REVIEWED_SHA256,
    "--audit-log", `${CASE_DIRECTORY}\\moderation-audit.jsonl`,
    "--confirm-delete",
  ];
}

function syntheticDecryptArgs(extra = []) {
  return [
    "decrypt",
    "--metadata", `${SYNTHETIC_DIRECTORY}\\synthetic-export.json`,
    "--ciphertext", `${SYNTHETIC_DIRECTORY}\\synthetic-report.ciphertext`,
    "--moderation-key-id", "moderation-v1",
    "--private-key", `${KEY_DIRECTORY}\\moderation-v1.private.raw`,
    "--expected-public-key-sha256", TEST_REVIEWED_SHA256,
    "--output", `${SYNTHETIC_DIRECTORY}\\synthetic-review.jpg`,
    "--audit-log", `${SYNTHETIC_DIRECTORY}\\synthetic-audit.jsonl`,
    ...extra,
  ];
}

test("Windows production decrypt binds fixed files to pre-read and post-create proofs", () => {
  const plan = createWindowsModerationSecurityPlan(productionDecryptArgs());
  assert.equal(plan.command, "decrypt");
  assert.equal(plan.layout, "production");
  assert.deepEqual(plan.pre.map(({ mode }) => mode), [
    "ValidateKeyDirectory",
    "ValidateModerationDecryptInput",
  ]);
  assert.deepEqual(plan.post.map(({ mode }) => mode), ["HardenModerationDecryptOutput"]);
  assert.equal(plan.pre[1].outputDirectory, CASE_DIRECTORY);
  assert.equal(plan.pre[1].disjointDirectory, KEY_DIRECTORY);

  const withoutCiphertext = createWindowsModerationSecurityPlan(
    productionDecryptArgs(["--delete-ciphertext-after-success"]),
  );
  assert.equal(
    withoutCiphertext.post[0].mode,
    "HardenModerationDecryptOutputWithoutCiphertext",
  );
});

test("Windows production delete binds each lifecycle boundary", () => {
  const plaintext = createWindowsModerationSecurityPlan(productionDeleteArgs("plaintext"));
  assert.deepEqual(plaintext.pre.map(({ mode }) => mode), [
    "ValidateKeyDirectory",
    "ValidateModerationPlaintextDeleteInput",
  ]);
  assert.equal(plaintext.post[0].mode, "HardenModerationAfterPlaintextDelete");

  const ciphertext = createWindowsModerationSecurityPlan(productionDeleteArgs("ciphertext"));
  assert.deepEqual(ciphertext.pre.map(({ mode }) => mode), [
    "ValidateKeyDirectory",
    "ValidateModerationCiphertextDeleteInput",
  ]);
  assert.equal(ciphertext.post[0].mode, "HardenModerationAfterCiphertextDelete");
});

test("Windows synthetic drill remains on the same mandatory proof boundary", () => {
  const decrypt = createWindowsModerationSecurityPlan(syntheticDecryptArgs());
  assert.equal(decrypt.layout, "synthetic");
  assert.equal(decrypt.pre[1].mode, "ValidateDrillForReview");
  assert.equal(decrypt.post[0].mode, "HardenDrillReviewFiles");

  const plaintextArgs = productionDeleteArgs("plaintext").map((value) => value
    .replaceAll(CASE_DIRECTORY, SYNTHETIC_DIRECTORY)
    .replace("moderation-export.json", "synthetic-export.json")
    .replace("moderation-review.jpg.receipt", "synthetic-review.jpg.receipt")
    .replace("moderation-review.jpg", "synthetic-review.jpg")
    .replace("moderation-audit.jsonl", "synthetic-audit.jsonl"));
  const plaintext = createWindowsModerationSecurityPlan(plaintextArgs);
  assert.equal(plaintext.pre[1].mode, "ValidateDrillForDelete");
  assert.equal(plaintext.post[0].mode, "HardenDrillAfterPlaintextDelete");

  const ciphertextArgs = productionDeleteArgs("ciphertext").map((value) => value
    .replaceAll(CASE_DIRECTORY, SYNTHETIC_DIRECTORY)
    .replace("moderation-export.json", "synthetic-export.json")
    .replace("moderation-report.ciphertext", "synthetic-report.ciphertext")
    .replace("moderation-audit.jsonl", "synthetic-audit.jsonl"));
  const ciphertext = createWindowsModerationSecurityPlan(ciphertextArgs);
  assert.equal(ciphertext.pre[1].mode, "ValidateDrillAfterPlaintextDelete");
  assert.equal(ciphertext.post[0].mode, "HardenDrillAfterDelete");
});

test("Windows plan rejects layout, bypass, whitespace, and disjointness violations", () => {
  const invalidArgumentSets = [
    productionDecryptArgs().map((value) => value.replace("moderation-export.json", "export.json")),
    productionDecryptArgs().map((value) => value.replace(
      `${CASE_DIRECTORY}\\moderation-audit.jsonl`,
      "C:\\NekoModeration\\other\\moderation-audit.jsonl",
    )),
    productionDecryptArgs().map((value) => value.replace(
      `${KEY_DIRECTORY}\\moderation-v1.private.raw`,
      `${CASE_DIRECTORY}\\keys\\moderation-v1.private.raw`,
    )),
    productionDecryptArgs().map((value) => value.replace(
      `${CASE_DIRECTORY}\\moderation-export.json`,
      ` ${CASE_DIRECTORY}\\moderation-export.json`,
    )),
    productionDecryptArgs().map((value) => value.replace(
      `${CASE_DIRECTORY}\\moderation-export.json`,
      ".\\moderation-export.json",
    )),
    productionDecryptArgs().map((value) => value === "moderation-v1" ? "moderation-v3" : value),
    [...productionDecryptArgs(), "--skip-windows-security"],
    [...productionDecryptArgs(), "--windows-security-helper", "C:\\untrusted.ps1"],
    productionDeleteArgs("plaintext").filter((value) => value !== "--confirm-delete"),
  ];
  for (const argv of invalidArgumentSets) {
    assert.throws(
      () => createWindowsModerationSecurityPlan(argv),
      /Windows|unsupported|confirmation|moderation key/u,
    );
  }
});

test("Windows proof runner fixes executable, helper, environment boundary, and bounds", () => {
  const proof = createWindowsModerationSecurityPlan(productionDecryptArgs()).pre[1];
  let invocation;
  const fakeSpawn = (executable, args, options) => {
    invocation = { executable, args, options };
    return {
      error: undefined,
      signal: null,
      status: 0,
      stderr: "",
      stdout: "NEKO_MODERATION_KEYGEN_WINDOWS_VALIDATEMODERATIONDECRYPTINPUT_V1\r\n",
    };
  };
  runWindowsModerationSecurityProof(proof, fakeSpawn);
  assert.equal(
    invocation.executable,
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
  );
  assert.deepEqual(invocation.args.slice(0, 7), [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    SECURITY_HELPER,
  ]);
  assert.equal(invocation.args[invocation.args.indexOf("-Mode") + 1], proof.mode);
  assert.equal(
    invocation.args[invocation.args.indexOf("-DisjointDirectory") + 1],
    KEY_DIRECTORY,
  );
  assert.equal(invocation.options.timeout, 30_000);
  assert.equal(invocation.options.maxBuffer, 4_096);
  assert.equal(invocation.options.windowsHide, true);
  assert.equal(
    Object.keys(invocation.options.env).some((name) => name.toLowerCase() === "psmodulepath"),
    false,
  );
  assert.equal(invocation.options.env.SystemRoot, "C:\\Windows");
});

test("Windows proof runner fails closed on timeout, overflow, stderr, signal, and forged proof", () => {
  const proof = createWindowsModerationSecurityPlan(productionDecryptArgs()).pre[1];
  const failures = [
    { error: Object.assign(new Error("timeout"), { code: "ETIMEDOUT" }), signal: "SIGTERM", status: null, stderr: "", stdout: "" },
    { error: Object.assign(new Error("overflow"), { code: "ENOBUFS" }), signal: null, status: null, stderr: "", stdout: "" },
    { error: undefined, signal: null, status: 0, stderr: "unexpected", stdout: "NEKO_MODERATION_KEYGEN_WINDOWS_VALIDATEMODERATIONDECRYPTINPUT_V1\n" },
    { error: undefined, signal: "SIGTERM", status: null, stderr: "", stdout: "" },
    { error: undefined, signal: null, status: 0, stderr: "", stdout: "FORGED\n" },
    { error: undefined, signal: null, status: 0, stderr: "", stdout: "NEKO_MODERATION_KEYGEN_WINDOWS_VALIDATEMODERATIONDECRYPTINPUT_V1\n\n" },
    { error: undefined, signal: null, status: 1, stderr: "", stdout: "" },
  ];
  for (const result of failures) {
    assert.throws(
      () => runWindowsModerationSecurityProof(proof, () => result),
      /Windows moderation security verification failed/u,
    );
  }
});

test("Windows helper and wrapper contain the exact ACL, link, module, and fixed-file boundaries", () => {
  const helper = readFileSync(SECURITY_HELPER, "utf8");
  for (const requiredSource of [
    "Test-ExactAcl",
    "Test-CanonicalSingleLinkPath",
    "Test-ExactFixedFiles",
    "Test-VolumeProtection",
    'FileSystem -eq "NTFS"',
    'VolumeStatus.ToString() -eq "FullyEncrypted"',
    'ProtectionStatus.ToString() -eq "On"',
    "$PSHOME",
    "Storage\\Get-Volume",
    "BitLocker\\Get-BitLockerVolume",
    '"moderation-export.json"',
    '"moderation-report.ciphertext"',
    '"moderation-review.jpg"',
    '"moderation-review.jpg.receipt"',
    '"moderation-audit.jsonl"',
    "unexpected file fixture was accepted",
    "inherited file ACL fixture was accepted",
    "hard-linked fixed file fixture was accepted",
  ]) {
    assert.ok(helper.includes(requiredSource), `missing Windows security boundary: ${requiredSource}`);
  }
  assert.match(
    helper,
    /\$Mode -eq "HardenModerationDecryptInput"[\s\S]{0,500}-Harden \$true/u,
  );
  assert.match(
    helper,
    /\$Mode -eq "ValidateModerationDecryptInput"[\s\S]{0,500}-Harden \$false/u,
  );
  const operationalChecks = helper.slice(
    helper.indexOf("if ([string]::IsNullOrWhiteSpace($Mode)"),
  );
  assert.ok(
    operationalChecks.indexOf("Test-VolumeProtection")
      < operationalChecks.indexOf('$Mode -eq "ValidateModerationDecryptInput"'),
    "volume proof must precede decrypt-input mode success",
  );
  assert.ok(
    operationalChecks.indexOf("Test-ExactAcl -LiteralPath $fullOutput")
      < operationalChecks.indexOf('$Mode -eq "ValidateModerationDecryptInput"'),
    "case-directory exact ACL proof must precede decrypt-input mode success",
  );

  const wrapper = readFileSync(WINDOWS_WRAPPER, "utf8");
  assert.match(wrapper, /PrepareModerationCaseDirectory/u);
  assert.match(wrapper, /HardenModerationDecryptInput/u);
  assert.match(wrapper, /moderation-report-tool\.mjs/u);
  assert.match(wrapper, /\$nodeOutput -cne "Report decrypted and validated;/u);
  assert.match(wrapper, /\$nodeOutput -cne "Confirmed local moderation artifact deleted;/u);
  assert.doesNotMatch(wrapper, /\$env:SystemRoot/u);
  assert.ok(
    wrapper.indexOf('throw "human review deletion confirmation missing"')
      < wrapper.indexOf('Invoke-SecurityProof -SecurityMode "ValidateKeyDirectory"'),
    "deletion confirmation must fail before any security helper invocation",
  );
  assert.ok(
    wrapper.indexOf('"HardenModerationDecryptInput"')
      < wrapper.indexOf("& $node $Tool decrypt"),
    "wrapper hardening must precede Node decrypt",
  );

  const trustedNode = readFileSync(TRUSTED_NODE_HELPER, "utf8");
  for (const requiredSource of [
    "GetFolderPath",
    "SpecialFolder]::ProgramFiles",
    'Join-Path $programFiles "nodejs"',
    'Join-Path $nodeDirectory "node.exe"',
    "TrustedModerationNodeIdentity",
    "GetFinalPathNameByHandle",
    "NumberOfLinks",
    "ReparsePoint",
    "Test-TrustedModerationNodeAcl",
    "Disable-InheritedModerationNodeEnvironment",
    'StartsWith(\n                "NODE_"',
    "Node 22 or later is required",
  ]) {
    assert.ok(
      trustedNode.includes(requiredSource),
      `missing trusted Node boundary: ${requiredSource}`,
    );
  }
  assert.doesNotMatch(trustedNode, /Get-Command\s+node|where(?:\.exe)?\s+node/iu);
  for (const wrapperPath of WINDOWS_WRAPPERS) {
    const source = readFileSync(wrapperPath, "utf8");
    assert.match(source, /moderation-windows-trusted-node\.ps1/u);
    assert.match(source, /Disable-InheritedModerationNodeEnvironment/u);
    assert.match(source, /Get-TrustedModerationNodeExecutable/u);
    assert.match(source, /Restore-InheritedModerationNodeEnvironment/u);
    assert.doesNotMatch(source, /Get-Command\s+node/iu);
    assert.doesNotMatch(source, /\$env:SystemRoot/u);
  }
  const keygenLibrary = readFileSync(KEYGEN_LIBRARY, "utf8");
  assert.match(
    keygenLibrary,
    /C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1\.0\\\\powershell\.exe/u,
  );
  assert.doesNotMatch(keygenLibrary, /process\.env\.SystemRoot/u);
  assert.match(keygenLibrary, /SystemRoot: "C:\\\\Windows"/u);

  const tool = readFileSync(TOOL, "utf8");
  const mainBody = tool.slice(tool.indexOf("export function main"));
  assert.ok(
    mainBody.indexOf("runWindowsModerationSecurityProof")
      < mainBody.indexOf("decryptCommand(values)"),
    "pre-read proof must precede command execution",
  );
  assert.doesNotMatch(tool, /SKIP_WINDOWS|WINDOWS_SECURITY_HELPER_PATH|process\.env\.[A-Z_]*HELPER/u);

  const packageJSON = JSON.parse(readFileSync(PACKAGE_JSON, "utf8"));
  assert.match(packageJSON.scripts["check:moderation-tool"], /moderation-report-windows-boundary/u);

  const workflow = readFileSync(WINDOWS_WORKFLOW, "utf8");
  assert.match(workflow, /runs-on: windows-2022[\s\S]*moderation-report-tool-windows\.ps1/su);
  assert.match(workflow, /runs-on: windows-2022[\s\S]*moderation-windows-trusted-node\.ps1/su);
  assert.match(workflow, /runs-on: windows-2022[\s\S]*npm run check:moderation-tool/su);
});

test("fixed Program Files Node and inherited NODE_* suppression execute fail closed", {
  skip: process.platform !== "win32",
}, () => {
  const powershell = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
  const command = [
    `. '${TRUSTED_NODE_HELPER.replaceAll("'", "''")}'`,
    "$env:NODE_OPTIONS = '--definitely-invalid-for-boundary-test'",
    "$env:PSModulePath = 'C:\\attacker-controlled-modules'",
    "$env:SystemRoot = 'C:\\attacker-controlled'",
    "$saved = Disable-InheritedModerationNodeEnvironment",
    "try {",
    "  if (Test-Path Env:NODE_OPTIONS) { throw 'NODE_OPTIONS survived' }",
    "  if (Test-Path Env:PSModulePath) { throw 'PSModulePath survived' }",
    "  if ($env:SystemRoot -cne 'C:\\Windows') { throw 'SystemRoot survived' }",
    "  $node = Get-TrustedModerationNodeExecutable",
    "  $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)",
    "  $expected = Join-Path $programFiles 'nodejs\\node.exe'",
    "  if ($node -cne $expected) { throw 'unexpected Node' }",
    "} finally { Restore-InheritedModerationNodeEnvironment -Saved $saved }",
    "if ($env:NODE_OPTIONS -cne '--definitely-invalid-for-boundary-test') { throw 'restore failed' }",
    "if ($env:PSModulePath -cne 'C:\\attacker-controlled-modules') { throw 'PSModulePath restore failed' }",
    "if ($env:SystemRoot -cne 'C:\\attacker-controlled') { throw 'SystemRoot restore failed' }",
    "Write-Output 'NEKO_TRUSTED_MODERATION_NODE_V1'",
  ].join("; ");
  const result = spawnSync(powershell, [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-Command",
    command,
  ], {
    encoding: "utf8",
    maxBuffer: 16_384,
    timeout: 30_000,
    windowsHide: true,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, "");
  assert.equal(result.stdout.trim(), "NEKO_TRUSTED_MODERATION_NODE_V1");
});

test("Windows security helper parses and its policy self-test exercises ACL and hard-link rejection", {
  skip: process.platform !== "win32",
}, () => {
  const powershell = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
  const result = spawnSync(powershell, [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    SECURITY_HELPER,
    "-PolicySelfTest",
  ], {
    encoding: "utf8",
    maxBuffer: 16_384,
    timeout: 30_000,
    windowsHide: true,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, "");
  assert.equal(result.stdout.trim(), "NEKO_MODERATION_KEYGEN_WINDOWS_POLICY_SELFTEST_V1");
});

test("Windows wrapper rejects missing destructive confirmation without leaking paths", {
  skip: process.platform !== "win32",
}, () => {
  const powershell = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
  const result = spawnSync(powershell, [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    WINDOWS_WRAPPER,
    "-Mode",
    "DeletePlaintextAfterReview",
    "-ModerationKeyId",
    "moderation-v1",
    "-KeyDirectory",
    "C:\\unused-boundary-fixture\\keys",
    "-CaseDirectory",
    "C:\\unused-boundary-fixture\\case",
    "-ExpectedPublicKeySHA256",
    TEST_REVIEWED_SHA256,
    "-ConfirmLocalEncryptedNoSync",
  ], {
    encoding: "utf8",
    maxBuffer: 4_096,
    timeout: 10_000,
    windowsHide: true,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.equal(
    result.stderr.trim(),
    "Windows moderation operation refused; keep the restricted case directory quarantined for two-person recovery.",
  );
  assert.doesNotMatch(result.stderr, /unused-boundary-fixture|moderation-report-tool-windows\.ps1/u);
});
