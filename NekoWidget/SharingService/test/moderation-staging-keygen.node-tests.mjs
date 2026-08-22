import assert from "node:assert/strict";
import { createPrivateKey, createPublicKey } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import {
  MODERATION_PRIVATE_FILENAME,
  MODERATION_PUBLIC_FILENAME,
  ModerationKeygenError,
  X25519_PKCS8_PREFIX,
  X25519_SPKI_PREFIX,
  canonicalPublicKeyText,
  createKeyFilesInValidatedDirectory,
  deriveRawX25519PublicKey,
  extractRawX25519PrivateKey,
  extractRawX25519PublicKey,
  generateRawX25519KeyPair,
  generateStagingModerationKeyFiles,
  pathIsWithin,
  requireNode22,
  validateNewOutputDirectory,
} from "../scripts/moderation-staging-keygen-lib.mjs";
import {
  parseArguments,
  runCLI,
} from "../scripts/generate-moderation-staging-key.mjs";

// Synthetic fixture only. This value is shared with the moderation tool tests
// and must never be used for staging or production operations.
const FIXTURE_PRIVATE = Buffer.from(
  "70076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c6a",
  "hex",
);

function disposableDirectory() {
  return realpathSync.native(mkdtempSync(join(tmpdir(), "neko-keygen-test-")));
}

function cleanup(path) {
  rmSync(path, { recursive: true, force: true });
}

function fixturePair() {
  return {
    privateRaw: Buffer.from(FIXTURE_PRIVATE),
    publicRaw: deriveRawX25519PublicKey(FIXTURE_PRIVATE),
  };
}

function permissivePolicy(parent) {
  const policy = {
    platform: process.platform,
    currentDirectory: join(parent, "not-cwd"),
    repositoryRoot: join(parent, "not-repository"),
    temporaryDirectory: join(parent, "not-temp"),
    userProfile: join(parent, "not-profile"),
    environment: {},
  };
  for (const root of [
    policy.currentDirectory,
    policy.repositoryRoot,
    policy.temporaryDirectory,
    policy.userProfile,
  ]) {
    mkdirSync(root, { recursive: true });
  }
  return policy;
}

test("requires Node.js 22 before key generation", () => {
  assert.throws(() => requireNode22("21.99.0"), /Node\.js 22/u);
  assert.throws(() => requireNode22("invalid"), /Node\.js 22/u);
  assert.doesNotThrow(() => requireNode22("22.0.0"));
});

test("operational top-level generation fails closed on non-Windows", (context) => {
  if (process.platform === "win32") {
    context.skip("the non-Windows gate is exercised on the Linux CI runner");
    return;
  }
  const parent = disposableDirectory();
  const output = join(parent, "keys");
  try {
    assert.throws(
      () => generateStagingModerationKeyFiles({
        outputDirectory: output,
        confirmLocalEncryptedNoSync: true,
      }),
      /supported only on Windows/u,
    );
    assert.equal(existsSync(output), false);
  } finally {
    cleanup(parent);
  }
});

test("accepts only the exact explicit CLI contract", () => {
  const expected = parseArguments([
    "--output-dir",
    resolve("safe-output"),
    "--confirm-local-encrypted-nosync",
  ]);
  assert.equal(expected.outputDirectory, resolve("safe-output"));
  assert.equal(expected.confirmed, true);
  assert.throws(() => parseArguments([]), /output directory is required/u);
  assert.throws(() => parseArguments(["--output-dir"]), /value is missing/u);
  assert.throws(
    () => parseArguments(["--output-dir", resolve("a"), "--output-dir", resolve("b")]),
    /more than once/u,
  );
  assert.throws(
    () => parseArguments(["--output-dir", resolve("a"), "--unknown"]),
    /unsupported/u,
  );
  assert.throws(
    () => parseArguments([
      "--output-dir",
      resolve("a"),
      "--confirm-local-encrypted-nosync",
      "--confirm-local-encrypted-nosync",
    ]),
    /more than once/u,
  );
});

test("extracts only the exact X25519 PKCS8 and SPKI encodings", () => {
  const privateKey = createPrivateKey({
    key: Buffer.concat([X25519_PKCS8_PREFIX, FIXTURE_PRIVATE]),
    format: "der",
    type: "pkcs8",
  });
  const publicKey = createPublicKey(privateKey);
  const privateRaw = extractRawX25519PrivateKey(privateKey);
  const publicRaw = extractRawX25519PublicKey(publicKey);
  try {
    assert.deepEqual(privateRaw, FIXTURE_PRIVATE);
    assert.equal(publicRaw.length, 32);
    assert.deepEqual(deriveRawX25519PublicKey(privateRaw), publicRaw);
    assert.match(canonicalPublicKeyText(publicRaw), /^[A-Za-z0-9_-]{43}$/u);
  } finally {
    privateRaw.fill(0);
    publicRaw.fill(0);
  }

  assert.throws(
    () => extractRawX25519PrivateKey({
      export: () => Buffer.concat([Buffer.from("00", "hex"), X25519_PKCS8_PREFIX, FIXTURE_PRIVATE]),
    }),
    /DER encoding is unsupported/u,
  );
  assert.throws(
    () => extractRawX25519PublicKey({
      export: () => Buffer.concat([X25519_SPKI_PREFIX, Buffer.alloc(31)]),
    }),
    /DER encoding is unsupported/u,
  );
});

test("the real generator creates an internally consistent pair only in memory", () => {
  const pair = generateRawX25519KeyPair();
  let derived;
  try {
    derived = deriveRawX25519PublicKey(pair.privateRaw);
    assert.deepEqual(derived, pair.publicRaw);
    assert.equal(canonicalPublicKeyText(pair.publicRaw).length, 43);
  } finally {
    pair.privateRaw.fill(0);
    pair.publicRaw.fill(0);
    derived?.fill(0);
  }
});

test("rejects profile, temp, repository, working, sync, and provider paths", () => {
  const parent = disposableDirectory();
  try {
    const context = permissivePolicy(parent);
    const roots = {
      currentDirectory: join(parent, "cwd"),
      repositoryRoot: join(parent, "repository"),
      temporaryDirectory: join(parent, "temporary"),
      userProfile: join(parent, "profile"),
    };
    for (const root of Object.values(roots)) mkdirSync(root);
    for (const [name, root] of Object.entries(roots)) {
      assert.throws(
        () => validateNewOutputDirectory(join(root, "keys"), { ...context, ...roots }),
        /repository, working, temporary, profile, or sync root/u,
        name,
      );
    }
    const sync = join(parent, "custom-sync");
    mkdirSync(sync);
    assert.throws(
      () => validateNewOutputDirectory(join(sync, "keys"), {
        ...context,
        environment: { OneDrive: sync },
      }),
      /sync root/u,
    );
    assert.throws(
      () => validateNewOutputDirectory(join(parent, "OneDrive", "keys"), context),
      /cloud-provider/u,
    );
  } finally {
    cleanup(parent);
  }
});

test("canonicalizes policy roots before containment checks", (context) => {
  const parent = disposableDirectory();
  try {
    const restricted = join(parent, "canonical-restricted-root");
    const alias = join(parent, "restricted-root-alias");
    mkdirSync(restricted);
    try {
      symlinkSync(restricted, alias, process.platform === "win32" ? "junction" : "dir");
    } catch {
      context.skip("directory aliases are unavailable on this filesystem");
      return;
    }

    for (const rootName of [
      "currentDirectory",
      "repositoryRoot",
      "temporaryDirectory",
      "userProfile",
    ]) {
      assert.throws(
        () => validateNewOutputDirectory(join(restricted, `${rootName}-keys`), {
          ...permissivePolicy(parent),
          [rootName]: alias,
        }),
        /canonical output path is inside a restricted or sync root/u,
        rootName,
      );
    }

    assert.throws(
      () => validateNewOutputDirectory(join(restricted, "provider-keys"), {
        ...permissivePolicy(parent),
        environment: { OneDrive: alias },
      }),
      /canonical output path is inside a restricted or sync root/u,
    );
  } finally {
    cleanup(parent);
  }
});

test("canonical provider checks cover an injected Windows 8.3 alias fixture", () => {
  const parent = disposableDirectory();
  try {
    const canonicalProvider = join(parent, "canonical-provider-root");
    const shortAlias = join(parent, "CANONI~1");
    mkdirSync(canonicalProvider);
    const policy = permissivePolicy(parent);
    const canonicalizePath = (value) => (
      resolve(value) === resolve(shortAlias)
        ? realpathSync.native(canonicalProvider)
        : realpathSync.native(value)
    );
    assert.throws(
      () => validateNewOutputDirectory(join(canonicalProvider, "keys"), {
        ...policy,
        environment: { OneDrive: shortAlias },
        canonicalizePath,
      }),
      /canonical output path is inside a restricted or sync root/u,
    );
  } finally {
    cleanup(parent);
  }
});

test("refuses an unresolvable configured provider root", () => {
  const parent = disposableDirectory();
  try {
    assert.throws(
      () => validateNewOutputDirectory(join(parent, "keys"), {
        ...permissivePolicy(parent),
        environment: { OneDrive: join(parent, "missing-provider-root") },
      }),
      /OneDrive provider root could not be resolved safely/u,
    );
  } finally {
    cleanup(parent);
  }
});

test("path containment uses component boundaries", () => {
  const root = resolve("root-boundary");
  assert.equal(pathIsWithin(join(root, "child"), root), true);
  assert.equal(pathIsWithin(`${root}2`, root), false);
});

test("rejects repository markers and linked parent directories", (context) => {
  const parent = disposableDirectory();
  try {
    const repository = join(parent, "foreign-repository");
    const real = join(parent, "real-parent");
    const link = join(parent, "linked-parent");
    mkdirSync(repository);
    mkdirSync(join(repository, ".git"));
    mkdirSync(real);
    assert.throws(
      () => validateNewOutputDirectory(join(repository, "keys"), permissivePolicy(parent)),
      /repository and worktree/u,
    );
    try {
      symlinkSync(real, link, process.platform === "win32" ? "junction" : "dir");
    } catch {
      context.skip("directory links are unavailable on this filesystem");
      return;
    }
    assert.throws(
      () => validateNewOutputDirectory(join(link, "keys"), permissivePolicy(parent)),
      /links or junctions/u,
    );
  } finally {
    cleanup(parent);
  }
});

test("rejects Windows namespace, ADS, and reserved-device paths", (context) => {
  if (process.platform !== "win32") {
    context.skip("Windows namespace rules are exercised on the Windows runner");
    return;
  }
  const parent = disposableDirectory();
  try {
    const policy = permissivePolicy(parent);
    assert.throws(
      () => validateNewOutputDirectory("\\\\server\\share\\keys", policy),
      /network, device, and extended/u,
    );
    assert.throws(
      () => validateNewOutputDirectory(`${join(parent, "keys")}:hidden`, policy),
      /alternate data stream/u,
    );
    assert.throws(
      () => validateNewOutputDirectory(join(parent, "NUL.txt"), policy),
      /reserved device/u,
    );
    assert.throws(
      () => validateNewOutputDirectory(join(parent, "keys"), {
        ...policy,
        environment: { OneDrive: "\\\\server\\share\\sync" },
      }),
      /network, device, and extended/u,
    );
    assert.throws(
      () => validateNewOutputDirectory(join(parent, "keys"), {
        ...policy,
        environment: { OneDrive: `${parent}:sync` },
      }),
      /alternate data stream/u,
    );
  } finally {
    cleanup(parent);
  }
});

test("writes only fixed synthetic key files with exact sizes and no newline", () => {
  const parent = disposableDirectory();
  const output = join(parent, "keys");
  let expectedPublic;
  try {
    createKeyFilesInValidatedDirectory(
      { path: output, prepared: false },
      { keyPairFactory: fixturePair },
    );
    assert.deepEqual(
      readdirSync(output).sort(),
      [MODERATION_PRIVATE_FILENAME, MODERATION_PUBLIC_FILENAME].sort(),
    );
    const privateBytes = readFileSync(join(output, MODERATION_PRIVATE_FILENAME));
    const publicBytes = readFileSync(join(output, MODERATION_PUBLIC_FILENAME));
    try {
      assert.equal(privateBytes.length, 32);
      assert.equal(publicBytes.length, 43);
      assert.equal(publicBytes.includes(0x0a), false);
      assert.equal(publicBytes.includes(0x0d), false);
      expectedPublic = deriveRawX25519PublicKey(privateBytes);
      assert.equal(publicBytes.toString("ascii"), canonicalPublicKeyText(expectedPublic));
      if (process.platform !== "win32") {
        assert.equal(statSync(output).mode & 0o077, 0);
        assert.equal(statSync(join(output, MODERATION_PRIVATE_FILENAME)).mode & 0o077, 0);
        assert.equal(statSync(join(output, MODERATION_PUBLIC_FILENAME)).mode & 0o077, 0);
      }
    } finally {
      privateBytes.fill(0);
      publicBytes.fill(0);
      expectedPublic?.fill(0);
    }
  } finally {
    cleanup(parent);
  }
});

test("refuses existing or partial output without overwriting it", () => {
  const parent = disposableDirectory();
  const output = join(parent, "keys");
  const sentinel = Buffer.from("synthetic-sentinel", "ascii");
  let generatorCalls = 0;
  try {
    mkdirSync(output);
    const existing = join(output, MODERATION_PUBLIC_FILENAME);
    writeFileSync(existing, sentinel);
    assert.throws(
      () => createKeyFilesInValidatedDirectory(
        { path: output, prepared: false },
        { keyPairFactory: () => { generatorCalls += 1; return fixturePair(); } },
      ),
      /new empty real directory|could not be created safely/u,
    );
    assert.equal(generatorCalls, 0);
    assert.deepEqual(readFileSync(existing), sentinel);
  } finally {
    sentinel.fill(0);
    cleanup(parent);
  }
});

test("cleans reserved files and the new directory when generation fails", () => {
  const parent = disposableDirectory();
  const output = join(parent, "keys");
  try {
    assert.throws(
      () => createKeyFilesInValidatedDirectory(
        { path: output, prepared: false },
        { keyPairFactory: () => { throw new Error("synthetic failure"); } },
      ),
      /could not be created safely/u,
    );
    assert.equal(existsSync(output), false);
  } finally {
    cleanup(parent);
  }
});

test("CLI success output never includes private fixture representations or a path", () => {
  const chunks = [];
  const output = resolve("private-looking-output-name");
  runCLI(
    ["--output-dir", output, "--confirm-local-encrypted-nosync"],
    {
      generate: () => Object.freeze({}),
      stdout: { write: (value) => { chunks.push(value); } },
    },
  );
  const text = chunks.join("");
  const forms = [
    FIXTURE_PRIVATE.toString("hex"),
    FIXTURE_PRIVATE.toString("base64"),
    FIXTURE_PRIVATE.toString("base64url"),
    output,
  ];
  for (const form of forms) assert.equal(text.includes(form), false);
  assert.equal(text, "Staging moderation key files were created with restricted access.\n");
});

test("implementation keeps the ceremony static and staging-only", () => {
  const library = readFileSync(
    new URL("../scripts/moderation-staging-keygen-lib.mjs", import.meta.url),
    "utf8",
  );
  const wrapper = readFileSync(
    new URL("../scripts/moderation-staging-keygen-windows.ps1", import.meta.url),
    "utf8",
  );
  const windowsSecurity = readFileSync(
    new URL("../scripts/moderation-staging-keygen-windows-security.ps1", import.meta.url),
    "utf8",
  );
  assert.match(library, /generateKeyPairSync\("x25519"\)/u);
  assert.match(library, /O_EXCL/u);
  assert.match(library, /privateRaw\?\.fill\(0\)/u);
  assert.doesNotMatch(library, /wrangler|CLOUDFLARE|SHARING_STAGING_MODERATION_PUBLIC_KEY/u);
  assert.match(windowsSecurity, /Get-BitLockerVolume -MountPoint/u);
  assert.match(windowsSecurity, /FullyEncrypted/u);
  assert.match(windowsSecurity, /ProtectionStatus/u);
  assert.match(windowsSecurity, /EncryptionPercentage/u);
  assert.match(windowsSecurity, /Get-Volume -DriveLetter/u);
  assert.match(windowsSecurity, /FileSystem -eq "NTFS"/u);
  assert.match(windowsSecurity, /S-1-5-18/u);
  assert.match(windowsSecurity, /S-1-5-32-544/u);
  assert.match(windowsSecurity, /Test-SafeAncestorChain/u);
  const topLevel = library.slice(library.indexOf("export function generateStagingModerationKeyFiles"));
  assert.ok(
    topLevel.indexOf('process.platform !== "win32"')
      < topLevel.indexOf("validateNewOutputDirectory(outputDirectory"),
    "the non-Windows operational gate must precede output preparation and key generation",
  );
  assert.doesNotMatch(
    `${wrapper}\n${windowsSecurity}`,
    /Invoke-Expression|Start-Process|cmd(?:\.exe)?\s+\/c/iu,
  );
});
