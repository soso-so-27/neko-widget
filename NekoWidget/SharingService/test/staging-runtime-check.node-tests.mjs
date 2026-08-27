import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  checkStagingRuntime,
  normalizePublicHttpsOrigin,
} from "../scripts/staging-runtime-check-lib.mjs";

const origin = "https://neko-window-sharing-staging.example.com";

function jsonResponse(status, body, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

function runtimeFetch({
  momentStatus,
  momentCode,
  reactionStatus = 401,
  reactionCode = "invalid_authentication",
  pushStatus = 401,
  pushCode = "invalid_authentication",
  targetedPushStatus = pushStatus,
  targetedPushCode = pushCode,
  reportStatus = 401,
  reportCode = "invalid_authentication",
  windowNameStatus,
  windowNameCode,
  healthMediaRuntime,
  healthReportRuntime = "OFF",
  legacyStatus = 503,
  legacyCode = "legacy_sharing_runtime_disabled",
}) {
  const resolvedWindowNameStatus = windowNameStatus ?? momentStatus;
  const resolvedWindowNameCode = windowNameCode
    ?? (momentCode === "moment_runtime_disabled"
      ? "window_name_runtime_disabled"
      : momentCode);
  const mediaRuntime = healthMediaRuntime ?? (
    momentStatus === 401 && resolvedWindowNameStatus === 401 ? "ON" : "OFF"
  );
  return async (url, options) => {
    assert.equal(options.redirect, "manual");
    switch (new URL(url).pathname) {
      case "/health":
        assert.equal(options.method, "GET");
        return jsonResponse(200, { status: "ok", protocolVersion: 1 }, {
          "Neko-Runtime-Gate-Generation": "7",
          "Neko-Runtime-Media": mediaRuntime,
          "Neko-Runtime-Apns": mediaRuntime,
          "Neko-Runtime-Report-Ingestion": healthReportRuntime,
        });
      case "/v2/moments/changes":
        assert.equal(options.method, "GET");
        return jsonResponse(momentStatus, { error: { code: momentCode, message: "expected test response" } });
      case "/v2/reactions/changes":
        assert.equal(options.method, "GET");
        return jsonResponse(reactionStatus, {
          error: { code: reactionCode, message: "expected test response" },
        });
      case "/v2/push-subscriptions/current":
        assert.ok(options.method === "PUT" || options.method === "DELETE");
        return jsonResponse(pushStatus, {
          error: { code: pushCode, message: "expected test response" },
        });
      case "/v3/push-subscriptions/current":
        assert.ok(options.method === "PUT" || options.method === "DELETE");
        return jsonResponse(targetedPushStatus, {
          error: { code: targetedPushCode, message: "expected test response" },
        });
      case "/v2/window-name":
        assert.equal(options.method, "GET");
        return jsonResponse(resolvedWindowNameStatus, {
          error: { code: resolvedWindowNameCode, message: "expected test response" },
        });
      case "/v2/reports/reservations":
      case "/v2/reports/0000000000000000000000/commit":
        assert.equal(options.method, "POST");
        return jsonResponse(reportStatus, {
          error: { code: reportCode, message: "expected test response" },
        });
      case "/v2/reports/0000000000000000000000/ciphertext":
        assert.equal(options.method, "PUT");
        assert.equal(options.headers["Content-Type"], "application/octet-stream");
        return jsonResponse(reportStatus, {
          error: { code: reportCode, message: "expected test response" },
        });
      case "/v1/sharing/sources":
        assert.equal(options.method, "GET");
        return jsonResponse(legacyStatus, { error: { code: legacyCode, message: "expected test response" } });
      default:
        throw new Error("unexpected URL");
    }
  };
}

test("accepts the expected ON runtime boundary", async () => {
  const result = await checkStagingRuntime({
    origin,
    expected: "on",
    fetchImpl: runtimeFetch({ momentStatus: 401, momentCode: "invalid_authentication" }),
  });
  assert.deepEqual(result.checks.map(({ name, status }) => ({ name, status })), [
    { name: "health", status: 200 },
    { name: "moment", status: 401 },
    { name: "reaction", status: 401 },
    { name: "push-register", status: 401 },
    { name: "push-delete", status: 401 },
    { name: "targeted-push-register", status: 401 },
    { name: "targeted-push-delete", status: 401 },
    { name: "window-name", status: 401 },
    { name: "legacy", status: 503 },
  ]);
});

test("accepts limited external beta when health is OFF and report routes stay auth-first", async () => {
  const result = await checkStagingRuntime({
    origin,
    expected: "limited-external-beta",
    fetchImpl: runtimeFetch({
      momentStatus: 401,
      momentCode: "invalid_authentication",
      reportStatus: 401,
      reportCode: "invalid_authentication",
    }),
  });
  assert.deepEqual(result.checks.map(({ name, status, code }) => ({ name, status, code })), [
    { name: "health", status: 200, code: undefined },
    { name: "moment", status: 401, code: "invalid_authentication" },
    { name: "reaction", status: 401, code: "invalid_authentication" },
    { name: "push-register", status: 401, code: "invalid_authentication" },
    { name: "push-delete", status: 401, code: "invalid_authentication" },
    { name: "targeted-push-register", status: 401, code: "invalid_authentication" },
    { name: "targeted-push-delete", status: 401, code: "invalid_authentication" },
    { name: "window-name", status: 401, code: "invalid_authentication" },
    { name: "report-reserve", status: 401, code: "invalid_authentication" },
    { name: "report-upload", status: 401, code: "invalid_authentication" },
    { name: "report-commit", status: 401, code: "invalid_authentication" },
    { name: "legacy", status: 503, code: "legacy_sharing_runtime_disabled" },
  ]);
});

test("rejects limited external beta if report ingestion becomes reachable", async () => {
  await assert.rejects(checkStagingRuntime({
    origin,
    expected: "limited-external-beta",
    fetchImpl: runtimeFetch({
      momentStatus: 401,
      momentCode: "invalid_authentication",
      healthReportRuntime: "ON",
      reportStatus: 401,
      reportCode: "invalid_authentication",
    }),
  }), /health returned an unexpected runtime gate state/u);
});

test("the daily monitor pins the current policy revisions and limited-beta boundary", async () => {
  const workflow = await readFile(
    new URL("../../../.github/workflows/sharing-staging-monitor.yml", import.meta.url),
    "utf8",
  );
  assert.equal(workflow.match(/revision: "2026-08-27"/gu)?.length, 1);
  assert.equal(workflow.match(/revision: "2026-08-26"/gu)?.length, 1);
  assert.doesNotMatch(workflow, /revision: "2026-08-(?:24|25)"/u);
  assert.match(workflow, /node scripts\/check-staging-runtime\.mjs --expected limited-external-beta/u);
});

test("rejects an ON boundary without the Build 70 targeted push route", async () => {
  await assert.rejects(
    checkStagingRuntime({
      origin,
      expected: "on",
      fetchImpl: runtimeFetch({
        momentStatus: 401,
        momentCode: "invalid_authentication",
        targetedPushStatus: 404,
        targetedPushCode: "not_found",
      }),
    }),
    /targeted-push-register returned HTTP 404; expected 401/u,
  );
});

test("accepts the expected OFF runtime boundary", async () => {
  const result = await checkStagingRuntime({
    origin,
    expected: "off",
    fetchImpl: runtimeFetch({
      momentStatus: 503,
      momentCode: "moment_runtime_disabled",
      reactionStatus: 503,
      reactionCode: "reaction_runtime_disabled",
    }),
  });
  assert.deepEqual(result.checks.map(({ name, status, code }) => ({ name, status, code })), [
    { name: "health", status: 200, code: undefined },
    { name: "moment", status: 503, code: "moment_runtime_disabled" },
    { name: "reaction", status: 503, code: "reaction_runtime_disabled" },
    { name: "window-name", status: 503, code: "window_name_runtime_disabled" },
    { name: "legacy", status: 503, code: "legacy_sharing_runtime_disabled" },
  ]);
});

test("rejects an OFF boundary that leaves reactions enabled", async () => {
  await assert.rejects(
    checkStagingRuntime({
      origin,
      expected: "off",
      fetchImpl: runtimeFetch({
        momentStatus: 503,
        momentCode: "moment_runtime_disabled",
        reactionStatus: 401,
        reactionCode: "invalid_authentication",
      }),
    }),
    /reaction returned HTTP 401; expected 503/u,
  );
});

test("accepts moment ON with private window-name and legacy runtimes OFF", async () => {
  const result = await checkStagingRuntime({
    origin,
    expected: "moment-on-window-name-off",
    fetchImpl: runtimeFetch({
      momentStatus: 401,
      momentCode: "invalid_authentication",
      windowNameStatus: 503,
      windowNameCode: "window_name_runtime_disabled",
    }),
  });
  assert.deepEqual(result.checks.map(({ name, status, code }) => ({ name, status, code })), [
    { name: "health", status: 200, code: undefined },
    { name: "moment", status: 401, code: "invalid_authentication" },
    { name: "window-name", status: 503, code: "window_name_runtime_disabled" },
    { name: "legacy", status: 503, code: "legacy_sharing_runtime_disabled" },
  ]);
});

test("rejects an enabled private window-name runtime in the mixed boundary", async () => {
  await assert.rejects(
    checkStagingRuntime({
      origin,
      expected: "moment-on-window-name-off",
      fetchImpl: runtimeFetch({
        momentStatus: 401,
        momentCode: "invalid_authentication",
        windowNameStatus: 401,
        windowNameCode: "invalid_authentication",
        healthMediaRuntime: "OFF",
      }),
    }),
    /window-name returned HTTP 401; expected 503/u,
  );
});

test("rejects a disabled moment runtime in the mixed boundary", async () => {
  await assert.rejects(
    checkStagingRuntime({
      origin,
      expected: "moment-on-window-name-off",
      fetchImpl: runtimeFetch({
        momentStatus: 503,
        momentCode: "moment_runtime_disabled",
        windowNameStatus: 503,
        windowNameCode: "window_name_runtime_disabled",
      }),
    }),
    /moment returned HTTP 503; expected 401/u,
  );
});

test("rejects a moment state mismatch", async () => {
  await assert.rejects(
    checkStagingRuntime({
      origin,
      expected: "on",
      fetchImpl: runtimeFetch({
        momentStatus: 503,
        momentCode: "moment_runtime_disabled",
        windowNameStatus: 401,
        windowNameCode: "invalid_authentication",
        healthMediaRuntime: "ON",
      }),
    }),
    /moment returned HTTP 503; expected 401/u,
  );
});

test("rejects a same-status response with the wrong error code", async () => {
  await assert.rejects(
    checkStagingRuntime({
      origin,
      expected: "on",
      fetchImpl: runtimeFetch({
        momentStatus: 401,
        momentCode: "unexpected_code",
        windowNameStatus: 401,
        windowNameCode: "invalid_authentication",
      }),
    }),
    /moment returned an unexpected error code/u,
  );
});

test("rejects a private window-name state mismatch", async () => {
  await assert.rejects(
    checkStagingRuntime({
      origin,
      expected: "on",
      fetchImpl: runtimeFetch({
        momentStatus: 401,
        momentCode: "invalid_authentication",
        windowNameStatus: 503,
        windowNameCode: "window_name_runtime_disabled",
        healthMediaRuntime: "ON",
      }),
    }),
    /window-name returned HTTP 503; expected 401/u,
  );
});

test("requires the exact health shape and a JSON content type", async () => {
  const wrongHealthFetch = async (url) => {
    if (new URL(url).pathname === "/health") {
      return jsonResponse(200, { status: "ok", protocolVersion: 1, extra: true });
    }
    return jsonResponse(503, { error: { code: "legacy_sharing_runtime_disabled" } });
  };
  await assert.rejects(
    checkStagingRuntime({ origin, expected: "on", fetchImpl: wrongHealthFetch }),
    /health returned an unexpected JSON shape/u,
  );

  const textFetch = async () => new Response("{}", {
    status: 200,
    headers: { "Content-Type": "text/plain" },
  });
  await assert.rejects(
    checkStagingRuntime({ origin, expected: "on", fetchImpl: textFetch }),
    /did not return application\/json/u,
  );
});

test("rejects an enabled or malformed legacy runtime", async () => {
  await assert.rejects(
    checkStagingRuntime({
      origin,
      expected: "on",
      fetchImpl: runtimeFetch({
        momentStatus: 401,
        momentCode: "invalid_authentication",
        legacyStatus: 401,
        legacyCode: "invalid_authentication",
      }),
    }),
    /legacy returned HTTP 401; expected 503/u,
  );
});

test("rejects redirects", async () => {
  const fetchImpl = async () => new Response(null, { status: 302, headers: { Location: "https://example.org" } });
  await assert.rejects(
    checkStagingRuntime({ origin, expected: "on", fetchImpl }),
    /returned a redirect/u,
  );
});

test("rejects requests that exceed the timeout", async () => {
  const fetchImpl = async (_url, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
  await assert.rejects(
    checkStagingRuntime({ origin, expected: "on", fetchImpl, timeoutMs: 10 }),
    /timed out/u,
  );
});

test("accepts only canonical public HTTPS origins", () => {
  assert.equal(normalizePublicHttpsOrigin(origin), origin);
  for (const unsafe of [
    "http://example.com",
    "https://example.com/health",
    "https://example.com?state=on",
    "https://example.com/#fragment",
    "https://user:pass@example.com",
    "https://example.com:8443",
    "https://localhost",
    "https://127.0.0.1",
    "https://service.internal",
    " https://example.com",
  ]) {
    assert.throws(() => normalizePublicHttpsOrigin(unsafe));
  }
});
