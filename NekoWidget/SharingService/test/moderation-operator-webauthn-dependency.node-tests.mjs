import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = join(testDirectory, "..");
const reviewedVersion = "13.3.3";
const reviewedModule = "src/moderation-operator-webauthn.ts";

async function sourceFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await sourceFiles(path));
    if (entry.isFile() && entry.name.endsWith(".ts")) files.push(path);
  }
  return files;
}

test("pins the reviewed SimpleWebAuthn release and lock integrity", async () => {
  const packageJson = JSON.parse(await readFile(join(projectDirectory, "package.json"), "utf8"));
  const packageLock = JSON.parse(await readFile(join(projectDirectory, "package-lock.json"), "utf8"));
  assert.equal(packageJson.dependencies?.["@simplewebauthn/server"], reviewedVersion);
  assert.equal(packageLock.packages?.[""]?.dependencies?.["@simplewebauthn/server"], reviewedVersion);

  const locked = packageLock.packages?.["node_modules/@simplewebauthn/server"];
  assert.equal(locked?.version, reviewedVersion);
  assert.equal(
    locked?.resolved,
    `https://registry.npmjs.org/@simplewebauthn/server/-/server-${reviewedVersion}.tgz`,
  );
  assert.match(locked?.integrity ?? "", /^sha512-[A-Za-z0-9+/]+={0,2}$/u);
  assert.equal(locked?.engines?.node, ">=20.0.0");
});

test("allows the package API only behind the strict operator wrapper", async () => {
  const imports = [];
  for (const path of await sourceFiles(join(projectDirectory, "src"))) {
    const content = await readFile(path, "utf8");
    if (content.includes("@simplewebauthn/server")) {
      imports.push(relative(projectDirectory, path).replaceAll("\\", "/"));
      assert.doesNotMatch(
        content,
        /generateRegistrationOptions|verifyRegistrationResponse|generateAuthenticationOptions/u,
      );
    }
  }
  assert.deepEqual(imports, [reviewedModule]);
});
