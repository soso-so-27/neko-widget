import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  timingSafeEqual,
} from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  closeSync,
  constants as fsConstants,
  fchmodSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readSync,
  realpathSync,
  readdirSync,
  rmdirSync,
  unlinkSync,
  writeSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  parse,
  relative,
  resolve,
} from "node:path";
import { fileURLToPath } from "node:url";

export const MODERATION_STAGING_KEY_ID = "moderation-v2";
export const MODERATION_PRIVATE_FILENAME = "moderation-v2.private.raw";
export const MODERATION_PUBLIC_FILENAME = "moderation-v2.public.base64url";
export const MODERATION_PUBLIC_FINGERPRINT_FILENAME = "moderation-v2.public.sha256";

export const X25519_PKCS8_PREFIX = Buffer.from(
  "302e020100300506032b656e04220420",
  "hex",
);
export const X25519_SPKI_PREFIX = Buffer.from(
  "302a300506032b656e032100",
  "hex",
);

const PROVIDER_COMPONENT = /^(?:onedrive(?:\s*-\s*.+)?|dropbox(?:\s*\(.+\))?|icloud(?:\s+drive)?|google\s*drive|googledrive|box(?:\s+sync)?|pcloud|nextcloud)$/iu;
const WINDOWS_RESERVED_COMPONENT = /^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$/iu;
const REPOSITORY_ROOT = fileURLToPath(new URL("../../../", import.meta.url));
const WINDOWS_POWERSHELL = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";

export class ModerationKeygenError extends Error {
  constructor(message) {
    super(message);
    this.name = "ModerationKeygenError";
  }
}

function fail(message) {
  throw new ModerationKeygenError(message);
}

export function requireNode22(version = process.versions.node) {
  const major = Number.parseInt(String(version).split(".", 1)[0], 10);
  if (!Number.isInteger(major) || major < 22) {
    fail("Node.js 22 or newer is required");
  }
}

function exactRawSuffix(der, prefix, description) {
  if (!Buffer.isBuffer(der)
      || der.length !== prefix.length + 32
      || !der.subarray(0, prefix.length).equals(prefix)) {
    fail(`${description} DER encoding is unsupported`);
  }
  return Buffer.from(der.subarray(prefix.length));
}

export function extractRawX25519PrivateKey(privateKey) {
  let der;
  try {
    der = privateKey.export({ format: "der", type: "pkcs8" });
    return exactRawSuffix(der, X25519_PKCS8_PREFIX, "X25519 private key");
  } catch (error) {
    if (error instanceof ModerationKeygenError) throw error;
    fail("X25519 private key could not be exported safely");
  } finally {
    der?.fill(0);
  }
}

export function extractRawX25519PublicKey(publicKey) {
  let der;
  try {
    der = publicKey.export({ format: "der", type: "spki" });
    return exactRawSuffix(der, X25519_SPKI_PREFIX, "X25519 public key");
  } catch (error) {
    if (error instanceof ModerationKeygenError) throw error;
    fail("X25519 public key could not be exported safely");
  } finally {
    der?.fill(0);
  }
}

export function deriveRawX25519PublicKey(privateRaw) {
  if (!Buffer.isBuffer(privateRaw) || privateRaw.length !== 32) {
    fail("X25519 private key must be exactly 32 raw bytes");
  }
  const privateDER = Buffer.concat([X25519_PKCS8_PREFIX, privateRaw]);
  try {
    const privateKey = createPrivateKey({
      key: privateDER,
      format: "der",
      type: "pkcs8",
    });
    return extractRawX25519PublicKey(createPublicKey(privateKey));
  } catch (error) {
    if (error instanceof ModerationKeygenError) throw error;
    fail("X25519 public key could not be derived from the private key");
  } finally {
    privateDER.fill(0);
  }
}

export function canonicalPublicKeyText(publicRaw) {
  if (!Buffer.isBuffer(publicRaw) || publicRaw.length !== 32) {
    fail("X25519 public key must be exactly 32 raw bytes");
  }
  const text = publicRaw.toString("base64url");
  let decoded;
  try {
    decoded = Buffer.from(text, "base64url");
    if (!/^[A-Za-z0-9_-]{43}$/u.test(text)
        || decoded.length !== 32
        || decoded.toString("base64url") !== text
        || !timingSafeEqual(decoded, publicRaw)) {
      fail("X25519 public key is not canonical base64url");
    }
    return text;
  } finally {
    decoded?.fill(0);
  }
}

export function canonicalPublicKeyFingerprint(publicRaw) {
  if (!Buffer.isBuffer(publicRaw) || publicRaw.length !== 32) {
    fail("X25519 public key must be exactly 32 raw bytes");
  }
  const fingerprint = createHash("sha256").update(publicRaw).digest("hex");
  if (!/^[0-9a-f]{64}$/u.test(fingerprint)) {
    fail("X25519 public-key fingerprint is not canonical lowercase hex");
  }
  return fingerprint;
}

export function generateRawX25519KeyPair() {
  let privateRaw;
  let generatedPublicRaw;
  let derivedPublicRaw;
  try {
    const generated = generateKeyPairSync("x25519");
    privateRaw = extractRawX25519PrivateKey(generated.privateKey);
    generatedPublicRaw = extractRawX25519PublicKey(generated.publicKey);
    derivedPublicRaw = deriveRawX25519PublicKey(privateRaw);
    if (!timingSafeEqual(generatedPublicRaw, derivedPublicRaw)) {
      fail("generated X25519 public key does not match its private key");
    }
    return {
      privateRaw: Buffer.from(privateRaw),
      publicRaw: Buffer.from(generatedPublicRaw),
    };
  } finally {
    privateRaw?.fill(0);
    generatedPublicRaw?.fill(0);
    derivedPublicRaw?.fill(0);
  }
}

function comparisonPath(path, platform) {
  const absolute = resolve(path).replace(/[\\/]+$/u, "");
  return platform === "win32" ? absolute.toLowerCase() : absolute;
}

export function pathIsWithin(candidate, root, platform = process.platform) {
  if (typeof root !== "string" || root.length === 0) return false;
  const candidateValue = comparisonPath(candidate, platform);
  const rootValue = comparisonPath(root, platform);
  const separator = platform === "win32" ? "\\" : "/";
  return candidateValue === rootValue
    || candidateValue.startsWith(`${rootValue}${separator}`);
}

function providerEnvironmentRoots(environment) {
  const names = [
    "OneDrive",
    "OneDriveConsumer",
    "OneDriveCommercial",
    "Dropbox",
    "DropboxPath",
    "iCloudDrive",
    "GoogleDrive",
    "GoogleDriveFS",
    "Box",
    "BoxDrive",
  ];
  return names
    .map((name) => ({ name, value: environment[name] }))
    .filter(({ value }) => typeof value === "string" && value.length > 0);
}

function rejectWindowsNamespace(value) {
  if (/^(?:\\\\|\/\/|\\\\\?\\|\\\\\.\\)/u.test(value)) {
    fail("Windows network, device, and extended paths are not allowed");
  }
  const absolute = resolve(value);
  const root = parse(absolute).root;
  if (!/^[A-Za-z]:[\\/]$/u.test(root)
      || absolute.slice(root.length).includes(":")) {
    fail("Windows alternate data stream paths are not allowed");
  }
  const components = absolute.slice(root.length).split(/[\\/]+/u);
  if (components.some((component) => WINDOWS_RESERVED_COMPONENT.test(
    component.replace(/[ .]+$/u, ""),
  ))) {
    fail("Windows reserved device names are not allowed");
  }
}

function canonicalizePolicyRoot(
  value,
  {
    platform,
    description,
    canonicalizePath,
  },
) {
  if (typeof value !== "string" || value.length === 0 || value.includes("\0")
      || !isAbsolute(value)) {
    fail(`${description} is not a valid absolute path`);
  }
  if (platform === "win32") rejectWindowsNamespace(value);
  try {
    const canonical = canonicalizePath(resolve(value));
    if (typeof canonical !== "string" || !isAbsolute(canonical)) {
      fail(`${description} could not be resolved safely`);
    }
    if (platform === "win32") rejectWindowsNamespace(canonical);
    return canonical;
  } catch (error) {
    if (error instanceof ModerationKeygenError) throw error;
    fail(`${description} could not be resolved safely`);
  }
}

function existingEntry(path, description) {
  try {
    return lstatSync(path, { bigint: true });
  } catch {
    fail(`${description} cannot be inspected safely`);
  }
}

function assertNoLinkedAncestor(path) {
  const absolute = resolve(path);
  const parsed = parse(absolute);
  const components = relative(parsed.root, absolute).split(/[\\/]+/u).filter(Boolean);
  let cursor = parsed.root;
  for (const component of components) {
    cursor = join(cursor, component);
    const entry = existingEntry(cursor, "output path ancestor");
    if (entry.isSymbolicLink() || !entry.isDirectory()) {
      fail("output path ancestors must be real directories, not links or junctions");
    }
  }
}

function hasRepositoryMarker(path) {
  let cursor = resolve(path);
  const root = parse(cursor).root;
  while (true) {
    try {
      lstatSync(join(cursor, ".git"), { bigint: true });
      return true;
    } catch { /* no marker at this level */ }
    if (cursor === root) return false;
    cursor = dirname(cursor);
  }
}

export function validateNewOutputDirectory(
  value,
  {
    platform = process.platform,
    currentDirectory = process.cwd(),
    repositoryRoot = REPOSITORY_ROOT,
    temporaryDirectory = tmpdir(),
    userProfile = homedir(),
    environment = process.env,
    allowPreparedWindowsDirectory = false,
    canonicalizePath = realpathSync.native,
  } = {},
) {
  if (typeof value !== "string" || value.length === 0 || value.includes("\0")
      || !isAbsolute(value)) {
    fail("an explicit absolute output directory is required");
  }
  if (platform === "win32") rejectWindowsNamespace(value);
  const absolute = resolve(value);
  const name = basename(absolute);
  if (name.length === 0 || name === "." || name === "..") {
    fail("the output directory must have a new final component");
  }

  const components = absolute.slice(parse(absolute).root.length).split(/[\\/]+/u);
  if (platform === "win32"
      && components.some((component) => /[ .]$/u.test(component))) {
    fail("Windows path components must not end with a dot or space");
  }
  if (components.some((component) => PROVIDER_COMPONENT.test(component))) {
    fail("known cloud-provider directories are not allowed");
  }

  const providerRoots = providerEnvironmentRoots(environment);
  const restrictedRoots = [
    { description: "current working directory", value: currentDirectory },
    { description: "repository root", value: repositoryRoot },
    { description: "temporary directory", value: temporaryDirectory },
    { description: "user profile", value: userProfile },
    ...providerRoots.map(({ name: providerName, value: providerPath }) => ({
      description: `${providerName} provider root`,
      value: providerPath,
    })),
  ];
  if (restrictedRoots.some(({ value: root }) => pathIsWithin(absolute, root, platform))) {
    fail("the output directory is inside a repository, working, temporary, profile, or sync root");
  }

  const canonicalRestrictedRoots = restrictedRoots.map(({ description, value: root }) => (
    canonicalizePolicyRoot(root, { platform, description, canonicalizePath })
  ));

  const parent = dirname(absolute);
  assertNoLinkedAncestor(parent);
  const canonicalParent = canonicalizePolicyRoot(parent, {
    platform,
    description: "output directory parent",
    canonicalizePath,
  });
  const canonicalTarget = join(canonicalParent, name);
  const canonicalComponents = canonicalTarget
    .slice(parse(canonicalTarget).root.length)
    .split(/[\\/]+/u);
  if (canonicalComponents.some((component) => PROVIDER_COMPONENT.test(component))
      || canonicalRestrictedRoots.some(
        (root) => pathIsWithin(canonicalTarget, root, platform),
      )) {
    fail("the canonical output path is inside a restricted or sync root");
  }
  if (platform === "win32"
      && comparisonPath(absolute, platform) !== comparisonPath(canonicalTarget, platform)) {
    fail("Windows path aliases and short-name spellings are not allowed");
  }
  if (hasRepositoryMarker(canonicalParent)) {
    fail("repository and worktree paths are not allowed");
  }

  try {
    const target = lstatSync(canonicalTarget, { bigint: true });
    if (platform === "win32" && allowPreparedWindowsDirectory
        && target.isDirectory() && !target.isSymbolicLink()
        && readdirSync(canonicalTarget).length === 0) {
      return Object.freeze({ path: canonicalTarget, prepared: true });
    }
    fail("the output directory already exists; overwrite and resume are refused");
  } catch (error) {
    if (error instanceof ModerationKeygenError) throw error;
    if (error?.code !== "ENOENT") fail("the output directory cannot be inspected safely");
  }
  if (platform === "win32" && allowPreparedWindowsDirectory) {
    fail("the Windows wrapper did not prepare the output directory");
  }
  return Object.freeze({ path: canonicalTarget, prepared: false });
}

/**
 * Validate one existing, fixed-name staging artifact without reading it.
 *
 * This deliberately shares the key-ceremony path policy so a later staging
 * drill cannot re-introduce aliases, repository/profile/sync roots, linked
 * ancestors, or hard-linked files after key generation has completed.
 */
export function validateExistingRestrictedFile(
  value,
  {
    expectedFilename,
    expectedBytes,
    platform = process.platform,
    currentDirectory = process.cwd(),
    repositoryRoot = REPOSITORY_ROOT,
    temporaryDirectory = tmpdir(),
    userProfile = homedir(),
    environment = process.env,
    canonicalizePath = realpathSync.native,
  } = {},
) {
  if (typeof expectedFilename !== "string" || expectedFilename.length === 0
      || basename(expectedFilename) !== expectedFilename
      || !Number.isSafeInteger(expectedBytes) || expectedBytes < 1) {
    fail("the fixed existing-file contract is invalid");
  }
  if (typeof value !== "string" || value.length === 0 || value.includes("\0")
      || !isAbsolute(value) || basename(value) !== expectedFilename) {
    fail("the fixed existing file path is invalid");
  }
  if (platform === "win32") rejectWindowsNamespace(value);
  const absolute = resolve(value);
  const components = absolute.slice(parse(absolute).root.length).split(/[\\/]+/u);
  if (platform === "win32"
      && components.some((component) => /[ .]$/u.test(component))) {
    fail("Windows path components must not end with a dot or space");
  }
  if (components.some((component) => PROVIDER_COMPONENT.test(component))) {
    fail("known cloud-provider directories are not allowed");
  }

  const providerRoots = providerEnvironmentRoots(environment);
  const restrictedRoots = [
    { description: "current working directory", value: currentDirectory },
    { description: "repository root", value: repositoryRoot },
    { description: "temporary directory", value: temporaryDirectory },
    { description: "user profile", value: userProfile },
    ...providerRoots.map(({ name: providerName, value: providerPath }) => ({
      description: `${providerName} provider root`,
      value: providerPath,
    })),
  ];
  if (restrictedRoots.some(({ value: root }) => pathIsWithin(absolute, root, platform))) {
    fail("the existing file is inside a repository, working, temporary, profile, or sync root");
  }

  assertNoLinkedAncestor(dirname(absolute));
  const canonicalRestrictedRoots = restrictedRoots.map(({ description, value: root }) => (
    canonicalizePolicyRoot(root, { platform, description, canonicalizePath })
  ));
  let canonical;
  try {
    canonical = canonicalizePath(absolute);
  } catch {
    fail("the existing file could not be resolved safely");
  }
  if (typeof canonical !== "string" || !isAbsolute(canonical)) {
    fail("the existing file could not be resolved safely");
  }
  if (platform === "win32") rejectWindowsNamespace(canonical);
  if (comparisonPath(absolute, platform) !== comparisonPath(canonical, platform)) {
    fail("Windows path aliases and short-name spellings are not allowed");
  }
  if (canonicalRestrictedRoots.some((root) => pathIsWithin(canonical, root, platform))
      || hasRepositoryMarker(dirname(canonical))) {
    fail("the canonical existing file is inside a restricted or repository root");
  }

  const entry = existingEntry(canonical, "existing restricted file");
  if (!entry.isFile() || entry.isSymbolicLink() || entry.nlink !== 1n
      || entry.size !== BigInt(expectedBytes)) {
    fail("the existing restricted file is not an exact single-link regular file");
  }
  return Object.freeze({
    path: canonical,
    directory: dirname(canonical),
    device: entry.dev,
    inode: entry.ino,
    bytes: expectedBytes,
  });
}

function noFollowFlag() {
  return fsConstants.O_NOFOLLOW ?? 0;
}

function fsyncDirectory(path, platform = process.platform) {
  if (platform === "win32") return;
  let descriptor;
  try {
    descriptor = openSync(
      path,
      fsConstants.O_RDONLY | (fsConstants.O_DIRECTORY ?? 0) | noFollowFlag(),
    );
    fsyncSync(descriptor);
  } catch {
    fail("key directory could not be synchronized");
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function openExclusiveFile(path, platform) {
  let descriptor;
  let identity;
  try {
    descriptor = openSync(
      path,
      fsConstants.O_RDWR | fsConstants.O_CREAT | fsConstants.O_EXCL | noFollowFlag(),
      0o600,
    );
    if (platform !== "win32") fchmodSync(descriptor, 0o600);
    identity = fstatSync(descriptor, { bigint: true });
    if (!identity.isFile() || identity.nlink !== 1n || identity.size !== 0n
        || (platform !== "win32" && (identity.mode & 0o077n) !== 0n)) {
      fail("a key output could not be reserved safely");
    }
    return { descriptor, identity };
  } catch (error) {
    if (descriptor !== undefined) {
      try { closeSync(descriptor); } catch { /* cleanup continues */ }
    }
    safelyRemoveCreatedFile(path, identity);
    throw error;
  }
}

function safelyRemoveCreatedFile(path, identity) {
  if (identity === undefined) {
    try {
      lstatSync(path, { bigint: true });
      return false;
    } catch (error) {
      return error?.code === "ENOENT";
    }
  }
  try {
    const current = lstatSync(path, { bigint: true });
    if (!current.isFile() || current.isSymbolicLink() || current.nlink !== 1n
        || current.dev !== identity.dev || current.ino !== identity.ino) {
      return false;
    }
    unlinkSync(path);
    return true;
  } catch (error) {
    return error?.code === "ENOENT";
  }
}

function verifyFile(descriptor, expectedBytes, platform) {
  const entry = fstatSync(descriptor, { bigint: true });
  if (!entry.isFile() || entry.nlink !== 1n
      || entry.size !== BigInt(expectedBytes)
      || (platform !== "win32" && (entry.mode & 0o077n) !== 0n)) {
    fail("a generated key file failed its final identity or permission check");
  }
}

function verifyPathIdentity(path, identity) {
  const entry = lstatSync(path, { bigint: true });
  if (!entry.isFile() || entry.isSymbolicLink() || entry.nlink !== 1n
      || entry.dev !== identity.dev || entry.ino !== identity.ino) {
    fail("a generated key path no longer names its reserved file");
  }
}

function verifyDirectoryIdentity(path, identity) {
  const entry = lstatSync(path, { bigint: true });
  if (!entry.isDirectory() || entry.isSymbolicLink()
      || entry.dev !== identity.dev || entry.ino !== identity.ino) {
    fail("the generated key directory identity changed during the ceremony");
  }
}

export function createKeyFilesInValidatedDirectory(
  validated,
  {
    platform = process.platform,
    keyPairFactory = generateRawX25519KeyPair,
    postWriteVerifier = () => {},
  } = {},
) {
  if (validated === null || typeof validated !== "object"
      || typeof validated.path !== "string" || typeof validated.prepared !== "boolean") {
    fail("validated output directory descriptor is invalid");
  }
  const outputDirectory = validated.path;
  let directoryCreated = false;
  let privateFile;
  let publicFile;
  let fingerprintFile;
  let pair;
  let privateReadback;
  let derivedReadbackPublic;
  let publicBytes;
  let fingerprintBytes;
  let publicReadback;
  let fingerprintReadback;
  let directoryIdentity;
  let success = false;
  const privatePath = join(outputDirectory, MODERATION_PRIVATE_FILENAME);
  const publicPath = join(outputDirectory, MODERATION_PUBLIC_FILENAME);
  const fingerprintPath = join(outputDirectory, MODERATION_PUBLIC_FINGERPRINT_FILENAME);
  try {
    if (!validated.prepared) {
      mkdirSync(outputDirectory, { recursive: false, mode: 0o700 });
      directoryCreated = true;
      if (platform !== "win32") {
        chmodSync(outputDirectory, 0o700);
        if ((lstatSync(outputDirectory).mode & 0o077) !== 0) {
          fail("key directory permissions are not owner-only");
        }
      }
      fsyncDirectory(dirname(outputDirectory), platform);
    }
    directoryIdentity = existingEntry(outputDirectory, "key directory");
    if (!directoryIdentity.isDirectory() || directoryIdentity.isSymbolicLink()
        || readdirSync(outputDirectory).length !== 0) {
      fail("key directory must be a new empty real directory");
    }

    // Reserve every fixed name before generating any key material. This makes a
    // collision/race fail without ever creating a private key.
    publicFile = openExclusiveFile(publicPath, platform);
    verifyDirectoryIdentity(outputDirectory, directoryIdentity);
    fingerprintFile = openExclusiveFile(fingerprintPath, platform);
    verifyDirectoryIdentity(outputDirectory, directoryIdentity);
    privateFile = openExclusiveFile(privatePath, platform);
    verifyDirectoryIdentity(outputDirectory, directoryIdentity);
    fsyncDirectory(outputDirectory, platform);

    pair = keyPairFactory();
    if (!Buffer.isBuffer(pair?.privateRaw) || pair.privateRaw.length !== 32
        || !Buffer.isBuffer(pair?.publicRaw) || pair.publicRaw.length !== 32) {
      fail("key generator returned an invalid X25519 pair");
    }
    derivedReadbackPublic = deriveRawX25519PublicKey(pair.privateRaw);
    if (!timingSafeEqual(derivedReadbackPublic, pair.publicRaw)) {
      fail("generated X25519 key pair is inconsistent");
    }
    derivedReadbackPublic.fill(0);
    derivedReadbackPublic = undefined;

    publicBytes = Buffer.from(canonicalPublicKeyText(pair.publicRaw), "ascii");
    if (publicBytes.length !== 43 || publicBytes.includes(0x0a) || publicBytes.includes(0x0d)) {
      fail("public key output is not exactly 43 bytes without a newline");
    }
    fingerprintBytes = Buffer.from(canonicalPublicKeyFingerprint(pair.publicRaw), "ascii");
    if (fingerprintBytes.length !== 64
        || !/^[0-9a-f]{64}$/u.test(fingerprintBytes.toString("ascii"))) {
      fail("public-key fingerprint output is not exactly 64 lowercase hex bytes");
    }

    // Public first and private last: a crash cannot leave an apparently
    // usable public value unless the private write was the final data write.
    if (writeSync(publicFile.descriptor, publicBytes, 0, publicBytes.length, 0)
        !== publicBytes.length) {
      fail("public key output could not be written completely");
    }
    fsyncSync(publicFile.descriptor);
    if (writeSync(
      fingerprintFile.descriptor,
      fingerprintBytes,
      0,
      fingerprintBytes.length,
      0,
    ) !== fingerprintBytes.length) {
      fail("public-key fingerprint output could not be written completely");
    }
    fsyncSync(fingerprintFile.descriptor);
    if (writeSync(privateFile.descriptor, pair.privateRaw, 0, 32, 0) !== 32) {
      fail("private key output could not be written completely");
    }
    fsyncSync(privateFile.descriptor);
    verifyFile(publicFile.descriptor, 43, platform);
    verifyFile(fingerprintFile.descriptor, 64, platform);
    verifyFile(privateFile.descriptor, 32, platform);
    verifyPathIdentity(publicPath, publicFile.identity);
    verifyPathIdentity(fingerprintPath, fingerprintFile.identity);
    verifyPathIdentity(privatePath, privateFile.identity);

    publicReadback = Buffer.alloc(43);
    fingerprintReadback = Buffer.alloc(64);
    privateReadback = Buffer.alloc(32);
    if (readSync(publicFile.descriptor, publicReadback, 0, 43, 0) !== 43
        || readSync(fingerprintFile.descriptor, fingerprintReadback, 0, 64, 0) !== 64
        || readSync(privateFile.descriptor, privateReadback, 0, 32, 0) !== 32) {
      fail("generated key files could not be read back completely");
    }
    derivedReadbackPublic = deriveRawX25519PublicKey(privateReadback);
    const expectedText = Buffer.from(canonicalPublicKeyText(derivedReadbackPublic), "ascii");
    const expectedFingerprint = Buffer.from(
      canonicalPublicKeyFingerprint(derivedReadbackPublic),
      "ascii",
    );
    try {
      if (!timingSafeEqual(publicReadback, expectedText)
          || !timingSafeEqual(fingerprintReadback, expectedFingerprint)) {
        fail("written public key identity does not match the private key");
      }
    } finally {
      expectedText.fill(0);
      expectedFingerprint.fill(0);
    }
    fsyncDirectory(outputDirectory, platform);
    postWriteVerifier(Object.freeze({
      directory: outputDirectory,
      privatePath,
      publicPath,
      fingerprintPath,
    }));
    verifyPathIdentity(publicPath, publicFile.identity);
    verifyPathIdentity(fingerprintPath, fingerprintFile.identity);
    verifyPathIdentity(privatePath, privateFile.identity);
    verifyDirectoryIdentity(outputDirectory, directoryIdentity);
    success = true;
    return Object.freeze({
      directory: outputDirectory,
      privateFilename: MODERATION_PRIVATE_FILENAME,
      publicFilename: MODERATION_PUBLIC_FILENAME,
      publicFingerprintFilename: MODERATION_PUBLIC_FINGERPRINT_FILENAME,
      keyId: MODERATION_STAGING_KEY_ID,
    });
  } catch (error) {
    if (error instanceof ModerationKeygenError) throw error;
    fail("staging moderation key files could not be created safely");
  } finally {
    pair?.privateRaw?.fill(0);
    pair?.publicRaw?.fill(0);
    privateReadback?.fill(0);
    derivedReadbackPublic?.fill(0);
    publicBytes?.fill(0);
    fingerprintBytes?.fill(0);
    publicReadback?.fill(0);
    fingerprintReadback?.fill(0);
    if (privateFile?.descriptor !== undefined) {
      try { closeSync(privateFile.descriptor); } catch { /* cleanup continues */ }
    }
    if (publicFile?.descriptor !== undefined) {
      try { closeSync(publicFile.descriptor); } catch { /* cleanup continues */ }
    }
    if (fingerprintFile?.descriptor !== undefined) {
      try { closeSync(fingerprintFile.descriptor); } catch { /* cleanup continues */ }
    }
    if (!success) {
      const privateRemoved = safelyRemoveCreatedFile(privatePath, privateFile?.identity);
      const publicRemoved = safelyRemoveCreatedFile(publicPath, publicFile?.identity);
      const fingerprintRemoved = safelyRemoveCreatedFile(
        fingerprintPath,
        fingerprintFile?.identity,
      );
      try { fsyncDirectory(outputDirectory, platform); } catch { /* report original safe error */ }
      if ((directoryCreated || validated.prepared)
          && privateRemoved && publicRemoved && fingerprintRemoved) {
        try {
          verifyDirectoryIdentity(outputDirectory, directoryIdentity);
          if (readdirSync(outputDirectory).length === 0) {
            rmdirSync(outputDirectory);
            fsyncDirectory(dirname(outputDirectory), platform);
          }
        } catch { /* a restricted partial directory may require operator cleanup */ }
      }
    }
  }
}

export function windowsPowerShellExecutable() {
  let entry;
  try {
    entry = lstatSync(WINDOWS_POWERSHELL, { bigint: true });
  } catch {
    fail("the trusted Windows PowerShell executable is unavailable");
  }
  if (!entry.isFile() || entry.isSymbolicLink()) {
    fail("the trusted Windows PowerShell executable is invalid");
  }
  return WINDOWS_POWERSHELL;
}

function windowsSecurityEnvironment() {
  return {
    ...Object.fromEntries(
      Object.entries(process.env).filter(([name]) => name.toLowerCase() !== "psmodulepath"),
    ),
    SystemRoot: "C:\\Windows",
  };
}

export function runWindowsSecurityPhase(
  mode,
  outputDirectory,
  moderationKeyId = MODERATION_STAGING_KEY_ID,
) {
  if (moderationKeyId !== "moderation-v1" && moderationKeyId !== "moderation-v2") {
    fail("moderation key ID is unsupported");
  }
  const securityScript = fileURLToPath(
    new URL("./moderation-staging-keygen-windows-security.ps1", import.meta.url),
  );
  const expected = `NEKO_MODERATION_KEYGEN_WINDOWS_${mode.toUpperCase()}_V1`;
  const result = spawnSync(
    windowsPowerShellExecutable(),
    [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      securityScript,
      "-Mode",
      mode,
      "-OutputDirectory",
      outputDirectory,
      "-ModerationKeyId",
      moderationKeyId,
      "-ConfirmLocalEncryptedNoSync",
    ],
    {
      shell: false,
      windowsHide: true,
      encoding: "utf8",
      timeout: 30_000,
      maxBuffer: 8 * 1_024,
      stdio: ["ignore", "pipe", "pipe"],
      env: windowsSecurityEnvironment(),
    },
  );
  if (result.status !== 0 || result.signal !== null
      || result.stdout.trim() !== expected || result.stderr.trim() !== "") {
    fail("Windows BitLocker, volume, path, or ACL verification could not be proved");
  }
}

export function generateStagingModerationKeyFiles({
  outputDirectory,
  confirmLocalEncryptedNoSync,
} = {}) {
  requireNode22();
  if (process.platform !== "win32") {
    fail("operational moderation staging key generation is supported only on Windows");
  }
  if (confirmLocalEncryptedNoSync !== true) {
    fail("explicit local encrypted no-sync confirmation is required");
  }
  const validated = validateNewOutputDirectory(outputDirectory, {
    allowPreparedWindowsDirectory: true,
  });
  runWindowsSecurityPhase("VerifyDirectory", validated.path);
  return createKeyFilesInValidatedDirectory(validated, {
    postWriteVerifier: ({ directory }) => runWindowsSecurityPhase("HardenFiles", directory),
  });
}
