const cloudflareAPIOrigin = "https://api.cloudflare.com";
const maximumManifestBytes = 64 * 1024;
const maximumResponseBytes = 512 * 1024;
const defaultTimeoutMilliseconds = 15_000;

const accountIDPattern = /^[0-9a-f]{32}$/u;
const scriptNamePattern = /^[a-z0-9][a-z0-9_-]{0,62}$/u;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const bindingNamePattern = /^[A-Z][A-Z0-9_]{2,127}$/u;
const namespaceIDPattern = /^[1-9][0-9]{0,15}$/u;

export const activeWorkerRateLimitManifestName =
  "active-worker-ratelimit-attestation-manifest.json";

function fail(message = "active Worker rate-limit attestation failed") {
  throw new Error(message);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, expected, label) {
  if (!isRecord(value)) fail(`${label} is invalid`);
  const actual = Object.keys(value).sort();
  const reviewed = [...expected].sort();
  if (actual.length !== reviewed.length
      || actual.some((key, index) => key !== reviewed[index])) {
    fail(`${label} is invalid`);
  }
}

function exactString(value, pattern, label) {
  if (typeof value !== "string" || !pattern.test(value)) fail(`${label} is invalid`);
  return value;
}

function exactPositiveInteger(value, label) {
  if (!Number.isSafeInteger(value) || value <= 0) fail(`${label} is invalid`);
  return value;
}

function reviewedPeriod(value, label) {
  if (value !== 10 && value !== 60) fail(`${label} is invalid`);
  return value;
}

function reviewedMitigationTimeout(value, period, label) {
  if (value === null) return null;
  if (!Number.isSafeInteger(value) || value < 0 || value > 86_400) {
    fail(`${label} is invalid`);
  }
  if (value !== 0 && value !== 10 && value % 60 !== 0) fail(`${label} is invalid`);
  if (value !== 0 && value < period) fail(`${label} is invalid`);
  return value;
}

function byteLength(value) {
  return new TextEncoder().encode(value).byteLength;
}

function parseJSONString(text, cursor, label) {
  const start = cursor;
  if (text[cursor] !== '"') fail(`${label} is invalid`);
  cursor += 1;
  let escaped = false;
  while (cursor < text.length) {
    const code = text.charCodeAt(cursor);
    if (code < 0x20) fail(`${label} is invalid`);
    if (escaped) {
      escaped = false;
      cursor += 1;
      continue;
    }
    if (text[cursor] === "\\") {
      escaped = true;
      cursor += 1;
      continue;
    }
    if (text[cursor] === '"') {
      const token = text.slice(start, cursor + 1);
      try {
        return { value: JSON.parse(token), cursor: cursor + 1 };
      } catch {
        fail(`${label} is invalid`);
      }
    }
    cursor += 1;
  }
  fail(`${label} is invalid`);
}

function skipJSONWhitespace(text, cursor) {
  while (cursor < text.length && /[\t\n\r ]/u.test(text[cursor])) cursor += 1;
  return cursor;
}

function parseStrictJSONValue(text, initialCursor, depth, label) {
  if (depth > 64) fail(`${label} is invalid`);
  let cursor = skipJSONWhitespace(text, initialCursor);
  if (text[cursor] === '"') return parseJSONString(text, cursor, label);
  if (text[cursor] === "{") {
    cursor = skipJSONWhitespace(text, cursor + 1);
    const value = Object.create(null);
    const keys = new Set();
    if (text[cursor] === "}") return { value, cursor: cursor + 1 };
    while (cursor < text.length) {
      const key = parseJSONString(text, cursor, label);
      if (keys.has(key.value)) fail(`${label} contains a duplicate key`);
      keys.add(key.value);
      cursor = skipJSONWhitespace(text, key.cursor);
      if (text[cursor] !== ":") fail(`${label} is invalid`);
      const parsed = parseStrictJSONValue(text, cursor + 1, depth + 1, label);
      value[key.value] = parsed.value;
      cursor = skipJSONWhitespace(text, parsed.cursor);
      if (text[cursor] === "}") return { value, cursor: cursor + 1 };
      if (text[cursor] !== ",") fail(`${label} is invalid`);
      cursor = skipJSONWhitespace(text, cursor + 1);
    }
    fail(`${label} is invalid`);
  }
  if (text[cursor] === "[") {
    cursor = skipJSONWhitespace(text, cursor + 1);
    const value = [];
    if (text[cursor] === "]") return { value, cursor: cursor + 1 };
    while (cursor < text.length) {
      const parsed = parseStrictJSONValue(text, cursor, depth + 1, label);
      value.push(parsed.value);
      cursor = skipJSONWhitespace(text, parsed.cursor);
      if (text[cursor] === "]") return { value, cursor: cursor + 1 };
      if (text[cursor] !== ",") fail(`${label} is invalid`);
      cursor = skipJSONWhitespace(text, cursor + 1);
    }
    fail(`${label} is invalid`);
  }
  for (const [literal, value] of [
    ["true", true],
    ["false", false],
    ["null", null],
  ]) {
    if (text.startsWith(literal, cursor)) {
      return { value, cursor: cursor + literal.length };
    }
  }
  const number = text.slice(cursor).match(
    /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/u,
  );
  if (number === null) fail(`${label} is invalid`);
  const value = Number(number[0]);
  if (!Number.isFinite(value)) fail(`${label} is invalid`);
  return { value, cursor: cursor + number[0].length };
}

function parseStrictJSON(text, label) {
  const parsed = parseStrictJSONValue(text, 0, 0, label);
  if (skipJSONWhitespace(text, parsed.cursor) !== text.length) fail(`${label} is invalid`);
  return parsed.value;
}

export function parseActiveWorkerRateLimitManifest(text) {
  if (typeof text !== "string" || byteLength(text) > maximumManifestBytes) {
    fail("active Worker rate-limit manifest is invalid");
  }
  const raw = parseStrictJSON(text, "active Worker rate-limit manifest");
  exactKeys(raw, [
    "schemaVersion",
    "accountId",
    "scriptName",
    "expectedVersionId",
    "rateLimits",
  ], "active Worker rate-limit manifest");
  if (raw.schemaVersion !== 1) fail("active Worker rate-limit manifest is invalid");
  const accountId = exactString(raw.accountId, accountIDPattern, "account ID");
  const scriptName = exactString(raw.scriptName, scriptNamePattern, "script name");
  const expectedVersionId = exactString(
    raw.expectedVersionId,
    uuidPattern,
    "expected version ID",
  );
  if (!Array.isArray(raw.rateLimits) || raw.rateLimits.length < 2
      || raw.rateLimits.length > 32) {
    fail("active Worker rate-limit manifest is invalid");
  }
  const names = new Set();
  const namespaces = new Set();
  const rateLimits = raw.rateLimits.map((input) => {
    exactKeys(input, [
      "name",
      "namespaceId",
      "limit",
      "period",
      "mitigationTimeout",
    ], "reviewed rate-limit binding");
    const name = exactString(input.name, bindingNamePattern, "binding name");
    const namespaceId = exactString(
      input.namespaceId,
      namespaceIDPattern,
      "namespace ID",
    );
    const limit = exactPositiveInteger(input.limit, "rate limit");
    const period = reviewedPeriod(input.period, "rate-limit period");
    const mitigationTimeout = reviewedMitigationTimeout(
      input.mitigationTimeout,
      period,
      "mitigation timeout",
    );
    if (names.has(name) || namespaces.has(namespaceId)) {
      fail("reviewed rate-limit bindings are not unique");
    }
    names.add(name);
    namespaces.add(namespaceId);
    return Object.freeze({ name, namespaceId, limit, period, mitigationTimeout });
  });
  for (const required of [
    "BILLING_RATE_LIMITER",
    "BILLING_APPLE_NOTIFICATION_RATE_LIMITER",
  ]) {
    if (!names.has(required)) fail("reviewed billing rate-limit bindings are incomplete");
  }
  return Object.freeze({
    schemaVersion: 1,
    accountId,
    scriptName,
    expectedVersionId,
    rateLimits: Object.freeze(rateLimits),
  });
}

export function requireCloudflareAPIToken(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 2_048
      || value.trim() !== value || !/^[\x21-\x7e]+$/u.test(value)) {
    fail("CLOUDFLARE_API_TOKEN is unavailable");
  }
  return value;
}

function parseDeploymentEnvelope(value, expectedVersionId) {
  exactKeys(value, ["success", "errors", "messages", "result"], "Cloudflare response");
  if (value.success !== true || !Array.isArray(value.errors)
      || value.errors.length !== 0 || !Array.isArray(value.messages)) {
    fail("Cloudflare response is invalid");
  }
  const result = value.result;
  if (!isRecord(result) || !Array.isArray(result.deployments)
      || result.deployments.length < 1) {
    fail("active Worker deployment is invalid");
  }
  const deployment = result.deployments[0];
  if (!isRecord(deployment)) fail("active Worker deployment is invalid");
  const id = exactString(deployment.id, uuidPattern, "active deployment ID");
  if (deployment.strategy !== "percentage" || !Array.isArray(deployment.versions)
      || deployment.versions.length !== 1) {
    fail("active Worker deployment is invalid");
  }
  const version = deployment.versions[0];
  exactKeys(version, ["version_id", "percentage"], "active deployment version");
  const versionId = exactString(version.version_id, uuidPattern, "active version ID");
  if (versionId !== expectedVersionId || version.percentage !== 100) {
    fail("active Worker deployment is invalid");
  }
  return Object.freeze({
    deploymentId: id,
    strategy: "percentage",
    versionId,
    percentage: 100,
  });
}

function sanitizeRateLimitBindings(value, expectedVersionId) {
  exactKeys(value, ["success", "errors", "messages", "result"], "Cloudflare response");
  if (value.success !== true || !Array.isArray(value.errors)
      || value.errors.length !== 0 || !Array.isArray(value.messages)) {
    fail("Cloudflare response is invalid");
  }
  const result = value.result;
  if (!isRecord(result) || result.id !== expectedVersionId
      || !isRecord(result.resources) || !Array.isArray(result.resources.bindings)) {
    fail("active Worker version is invalid");
  }
  const sanitized = [];
  for (const binding of result.resources.bindings) {
    if (!isRecord(binding) || typeof binding.type !== "string"
        || typeof binding.name !== "string" || binding.name.length === 0) {
      fail("active Worker binding is invalid");
    }
    if (binding.type !== "ratelimit") continue;
    exactKeys(
      binding,
      ["name", "namespace_id", "simple", "type"],
      "active rate-limit binding",
    );
    exactString(binding.name, bindingNamePattern, "active binding name");
    exactString(binding.namespace_id, namespaceIDPattern, "active namespace ID");
    if (!isRecord(binding.simple)) fail("active rate-limit binding is invalid");
    const simpleKeys = Object.keys(binding.simple).sort();
    const withoutMitigation = ["limit", "period"];
    const withMitigation = ["limit", "mitigation_timeout", "period"];
    if (JSON.stringify(simpleKeys) !== JSON.stringify(withoutMitigation)
        && JSON.stringify(simpleKeys) !== JSON.stringify(withMitigation)) {
      fail("active rate-limit binding is invalid");
    }
    const limit = exactPositiveInteger(binding.simple.limit, "active rate limit");
    const period = reviewedPeriod(binding.simple.period, "active rate-limit period");
    const mitigationTimeout = reviewedMitigationTimeout(
      Object.hasOwn(binding.simple, "mitigation_timeout")
        ? binding.simple.mitigation_timeout
        : null,
      period,
      "active mitigation timeout",
    );
    sanitized.push(Object.freeze({
      name: binding.name,
      namespaceId: binding.namespace_id,
      limit,
      period,
      mitigationTimeout,
    }));
  }
  return Object.freeze(sanitized);
}

function canonicalRateLimits(rateLimits) {
  return [...rateLimits].sort((left, right) => left.name.localeCompare(right.name));
}

export function verifyExactRateLimitBindings(actual, expected) {
  if (!Array.isArray(actual) || !Array.isArray(expected)) {
    fail("active rate-limit bindings are invalid");
  }
  const actualNames = new Set();
  const actualNamespaces = new Set();
  for (const binding of actual) {
    if (!isRecord(binding) || actualNames.has(binding.name)
        || actualNamespaces.has(binding.namespaceId)) {
      fail("active rate-limit bindings are not unique");
    }
    actualNames.add(binding.name);
    actualNamespaces.add(binding.namespaceId);
  }
  const actualBilling = actual.find((value) => value.name === "BILLING_RATE_LIMITER");
  const actualApple = actual.find(
    (value) => value.name === "BILLING_APPLE_NOTIFICATION_RATE_LIMITER",
  );
  if (actualBilling === undefined || actualApple === undefined
      || actualBilling.namespaceId === actualApple.namespaceId) {
    fail("active billing rate-limit bindings are invalid");
  }
  if (JSON.stringify(canonicalRateLimits(actual))
      !== JSON.stringify(canonicalRateLimits(expected))) {
    fail("active rate-limit bindings do not match the reviewed manifest");
  }
  return true;
}

async function readBoundedResponse(response, maximumBytes = maximumResponseBytes) {
  if (!(response instanceof Response) || response.redirected
      || response.status < 200 || response.status >= 300 || response.body === null) {
    fail("Cloudflare request failed");
  }
  if (response.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase()
      !== "application/json") {
    fail("Cloudflare response is invalid");
  }
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null
      && (!/^[0-9]+$/u.test(contentLength) || Number(contentLength) > maximumBytes)) {
    fail("Cloudflare response is invalid");
  }
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel();
      fail("Cloudflare response is invalid");
    }
    chunks.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return parseStrictJSON(
      new TextDecoder("utf-8", { fatal: true }).decode(body),
      "Cloudflare response",
    );
  } catch {
    fail("Cloudflare response is invalid");
  }
}

async function cloudflareGET(url, token, fetchImpl, timeoutMilliseconds) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMilliseconds);
  try {
    const response = await fetchImpl(url, {
      method: "GET",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${token}`,
      },
      redirect: "manual",
      signal: controller.signal,
    });
    // Await the bounded body while the same deadline is still armed. Clearing
    // the timer after headers alone would let a stalled stream hang forever.
    return await readBoundedResponse(response);
  } catch {
    fail("Cloudflare request failed");
  } finally {
    clearTimeout(timer);
  }
}

function sameDeployment(left, right) {
  return left.deploymentId === right.deploymentId
    && left.strategy === right.strategy
    && left.versionId === right.versionId
    && left.percentage === right.percentage;
}

export async function attestActiveWorkerRateLimits({
  manifest,
  token,
  fetchImpl = fetch,
  timeoutMilliseconds = defaultTimeoutMilliseconds,
} = {}) {
  if (!isRecord(manifest) || !Array.isArray(manifest.rateLimits)) {
    fail("active Worker rate-limit manifest is invalid");
  }
  const reviewedToken = requireCloudflareAPIToken(token);
  if (typeof fetchImpl !== "function" || !Number.isSafeInteger(timeoutMilliseconds)
      || timeoutMilliseconds < 1 || timeoutMilliseconds > 60_000) {
    fail("active Worker rate-limit attestation options are invalid");
  }
  const base = `${cloudflareAPIOrigin}/client/v4/accounts/${manifest.accountId}`
    + `/workers/scripts/${encodeURIComponent(manifest.scriptName)}`;
  const deploymentsURL = `${base}/deployments`;
  const firstDeployment = parseDeploymentEnvelope(
    await cloudflareGET(
      deploymentsURL,
      reviewedToken,
      fetchImpl,
      timeoutMilliseconds,
    ),
    manifest.expectedVersionId,
  );
  const rateLimits = sanitizeRateLimitBindings(
    await cloudflareGET(
      `${base}/versions/${manifest.expectedVersionId}`,
      reviewedToken,
      fetchImpl,
      timeoutMilliseconds,
    ),
    manifest.expectedVersionId,
  );
  verifyExactRateLimitBindings(rateLimits, manifest.rateLimits);
  const secondDeployment = parseDeploymentEnvelope(
    await cloudflareGET(
      deploymentsURL,
      reviewedToken,
      fetchImpl,
      timeoutMilliseconds,
    ),
    manifest.expectedVersionId,
  );
  if (!sameDeployment(firstDeployment, secondDeployment)) {
    fail("active Worker deployment changed during attestation");
  }
  return true;
}
