import { isIP } from "node:net";

const DEFAULT_TIMEOUT_MS = 10_000;

const EXPECTATIONS = Object.freeze({
  on: Object.freeze([
    Object.freeze({
      name: "health",
      path: "/health",
      status: 200,
      body: Object.freeze({ status: "ok", protocolVersion: 1 }),
    }),
    Object.freeze({
      name: "moment",
      path: "/v2/moments/changes",
      status: 401,
      errorCode: "invalid_authentication",
    }),
    Object.freeze({
      name: "reaction",
      path: "/v2/reactions/changes",
      status: 401,
      errorCode: "invalid_authentication",
    }),
    Object.freeze({
      name: "push-register",
      method: "PUT",
      path: "/v2/push-subscriptions/current",
      status: 401,
      errorCode: "invalid_authentication",
    }),
    Object.freeze({
      name: "push-delete",
      method: "DELETE",
      path: "/v2/push-subscriptions/current",
      status: 401,
      errorCode: "invalid_authentication",
    }),
    Object.freeze({
      name: "window-name",
      path: "/v2/window-name",
      status: 401,
      errorCode: "invalid_authentication",
    }),
    Object.freeze({
      name: "legacy",
      path: "/v1/sharing/sources",
      status: 503,
      errorCode: "legacy_sharing_runtime_disabled",
    }),
  ]),
  "moment-on-window-name-off": Object.freeze([
    Object.freeze({
      name: "health",
      path: "/health",
      status: 200,
      body: Object.freeze({ status: "ok", protocolVersion: 1 }),
    }),
    Object.freeze({
      name: "moment",
      path: "/v2/moments/changes",
      status: 401,
      errorCode: "invalid_authentication",
    }),
    Object.freeze({
      name: "window-name",
      path: "/v2/window-name",
      status: 503,
      errorCode: "window_name_runtime_disabled",
    }),
    Object.freeze({
      name: "legacy",
      path: "/v1/sharing/sources",
      status: 503,
      errorCode: "legacy_sharing_runtime_disabled",
    }),
  ]),
  off: Object.freeze([
    Object.freeze({
      name: "health",
      path: "/health",
      status: 200,
      body: Object.freeze({ status: "ok", protocolVersion: 1 }),
    }),
    Object.freeze({
      name: "moment",
      path: "/v2/moments/changes",
      status: 503,
      errorCode: "moment_runtime_disabled",
    }),
    Object.freeze({
      name: "window-name",
      path: "/v2/window-name",
      status: 503,
      errorCode: "window_name_runtime_disabled",
    }),
    Object.freeze({
      name: "legacy",
      path: "/v1/sharing/sources",
      status: 503,
      errorCode: "legacy_sharing_runtime_disabled",
    }),
  ]),
});

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function assertExactObject(actual, expected, label) {
  if (!isPlainObject(actual)) {
    throw new Error(`${label} did not return a JSON object`);
  }
  const actualKeys = Object.keys(actual).sort();
  const expectedKeys = Object.keys(expected).sort();
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) {
    throw new Error(`${label} returned an unexpected JSON shape`);
  }
  for (const [key, value] of Object.entries(expected)) {
    if (actual[key] !== value) {
      throw new Error(`${label} returned an unexpected ${key}`);
    }
  }
}

export function normalizePublicHttpsOrigin(input) {
  if (typeof input !== "string" || input.trim() !== input || input.length === 0) {
    throw new Error("staging origin must be a non-empty canonical HTTPS origin");
  }

  let url;
  try {
    url = new URL(input);
  } catch {
    throw new Error("staging origin must be a valid HTTPS URL");
  }

  const hostname = url.hostname.replace(/^\[|\]$/gu, "").toLowerCase();
  if (
    url.protocol !== "https:" ||
    url.username !== "" ||
    url.password !== "" ||
    url.port !== "" ||
    url.pathname !== "/" ||
    url.search !== "" ||
    url.hash !== "" ||
    url.origin !== input
  ) {
    throw new Error("staging origin must be a canonical HTTPS origin without credentials, port, path, query, or fragment");
  }
  if (
    hostname.length === 0 ||
    isIP(hostname) !== 0 ||
    hostname === "localhost" ||
    hostname.endsWith(".localhost") ||
    hostname.endsWith(".local") ||
    hostname.endsWith(".internal")
  ) {
    throw new Error("staging origin must use a public DNS hostname");
  }

  return url.origin;
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${label} did not return valid JSON`);
  }
}

async function checkEndpoint({ origin, expectation, fetchImpl, timeoutMs }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  let bodyText;

  try {
    response = await fetchImpl(`${origin}${expectation.path}`, {
      method: expectation.method ?? "GET",
      headers: { Accept: "application/json" },
      redirect: "manual",
      signal: controller.signal,
    });
    if (response.status >= 300 && response.status < 400) {
      throw new Error(`${expectation.name} returned a redirect`);
    }
    if (!response.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
      throw new Error(`${expectation.name} did not return application/json`);
    }
    bodyText = await response.text();
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`${expectation.name} timed out`);
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }

  if (response.status !== expectation.status) {
    throw new Error(`${expectation.name} returned HTTP ${response.status}; expected ${expectation.status}`);
  }

  const body = parseJson(bodyText, expectation.name);
  if (expectation.body !== undefined) {
    assertExactObject(body, expectation.body, expectation.name);
  } else {
    const code = isPlainObject(body) && isPlainObject(body.error) ? body.error.code : undefined;
    if (code !== expectation.errorCode) {
      throw new Error(`${expectation.name} returned an unexpected error code`);
    }
  }

  return Object.freeze({
    name: expectation.name,
    path: expectation.path,
    status: response.status,
    code: expectation.errorCode,
  });
}

export async function checkStagingRuntime({
  origin,
  expected,
  fetchImpl = globalThis.fetch,
  timeoutMs = DEFAULT_TIMEOUT_MS,
}) {
  const normalizedOrigin = normalizePublicHttpsOrigin(origin);
  const expectations = EXPECTATIONS[expected];
  if (expectations === undefined) {
    throw new Error(
      "expected runtime state must be 'on', 'moment-on-window-name-off', or 'off'",
    );
  }
  if (typeof fetchImpl !== "function") {
    throw new Error("fetch implementation is unavailable");
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60_000) {
    throw new Error("timeout must be an integer from 1 through 60000 milliseconds");
  }

  const checks = await Promise.all(
    expectations.map((expectation) => checkEndpoint({
      origin: normalizedOrigin,
      expectation,
      fetchImpl,
      timeoutMs,
    })),
  );

  return Object.freeze({ origin: normalizedOrigin, expected, checks: Object.freeze(checks) });
}
