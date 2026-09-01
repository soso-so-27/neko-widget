import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

import {
  activeWorkerRateLimitManifestName,
  attestActiveWorkerRateLimits,
  parseActiveWorkerRateLimitManifest,
  requireCloudflareAPIToken,
  verifyExactRateLimitBindings,
} from "../scripts/active-worker-ratelimit-attestation-lib.mjs";
import { runActiveWorkerRateLimitAttestationCLI } from
  "../scripts/check-active-worker-ratelimit-attestation.mjs";

const accountId = "0123456789abcdef0123456789abcdef";
const versionId = "11111111-1111-4111-8111-111111111111";
const deploymentId = "22222222-2222-4222-8222-222222222222";
const token = "fixture-token-visible-only-inside-test";

const rateLimits = Object.freeze([
  Object.freeze({
    name: "CREATE_RATE_LIMITER",
    namespaceId: "700001",
    limit: 5,
    period: 60,
    mitigationTimeout: null,
  }),
  Object.freeze({
    name: "INVITE_RATE_LIMITER",
    namespaceId: "700002",
    limit: 10,
    period: 60,
    mitigationTimeout: 60,
  }),
  Object.freeze({
    name: "MEMBER_RATE_LIMITER",
    namespaceId: "700003",
    limit: 120,
    period: 60,
    mitigationTimeout: 0,
  }),
  Object.freeze({
    name: "BILLING_RATE_LIMITER",
    namespaceId: "700004",
    limit: 30,
    period: 60,
    mitigationTimeout: null,
  }),
  Object.freeze({
    name: "BILLING_APPLE_NOTIFICATION_RATE_LIMITER",
    namespaceId: "700005",
    limit: 30,
    period: 60,
    mitigationTimeout: null,
  }),
]);

function manifestValue(overrides = {}) {
  return {
    schemaVersion: 1,
    accountId,
    scriptName: "neko-window-sharing-staging",
    expectedVersionId: versionId,
    rateLimits: rateLimits.map((value) => ({ ...value })),
    ...overrides,
  };
}

function manifest(overrides = {}) {
  return parseActiveWorkerRateLimitManifest(JSON.stringify(manifestValue(overrides)));
}

function envelope(result, overrides = {}) {
  return {
    success: true,
    errors: [],
    messages: [],
    result,
    ...overrides,
  };
}

function deploymentsResult({
  activeDeploymentId = deploymentId,
  activeVersionId = versionId,
  percentage = 100,
  strategy = "percentage",
  versions,
} = {}) {
  return envelope({
    deployments: [{
      id: activeDeploymentId,
      created_on: "2026-09-01T00:00:00.000Z",
      source: "wrangler",
      strategy,
      versions: versions ?? [{ version_id: activeVersionId, percentage }],
    }],
  });
}

function versionResult(bindings = rateLimits.map((value) => ({
  type: "ratelimit",
  name: value.name,
  namespace_id: value.namespaceId,
  simple: {
    limit: value.limit,
    period: value.period,
    ...(value.mitigationTimeout === null
      ? {}
      : { mitigation_timeout: value.mitigationTimeout }),
  },
}))) {
  return envelope({
    id: versionId,
    number: 41,
    metadata: { source: "wrangler" },
    resources: {
      script: "ignored-script-content",
      bindings: [
        { type: "d1", name: "DB", id: "ignored" },
        ...bindings,
      ],
    },
  });
}

function jsonResponse(value, init = {}) {
  return new Response(JSON.stringify(value), {
    status: 200,
    headers: { "Content-Type": "application/json" },
    ...init,
  });
}

function sequenceFetch(values, calls = []) {
  let index = 0;
  return async (url, init) => {
    calls.push({ url: String(url), init });
    const value = values[index];
    index += 1;
    if (value instanceof Error) throw value;
    return value instanceof Response ? value : jsonResponse(value);
  };
}

test("strictly parses a reviewed Worker-scoped manifest", () => {
  const parsed = manifest();
  assert.equal(parsed.accountId, accountId);
  assert.equal(parsed.expectedVersionId, versionId);
  assert.deepEqual(parsed.rateLimits, rateLimits);

  for (const mutate of [
    (value) => { value.extra = true; },
    (value) => { value.schemaVersion = 2; },
    (value) => { value.accountId = "not-an-account"; },
    (value) => { value.scriptName = "../another-worker"; },
    (value) => { value.expectedVersionId = "not-a-version"; },
    (value) => { value.rateLimits[0].extra = true; },
    (value) => { value.rateLimits[0].namespaceId = value.rateLimits[1].namespaceId; },
    (value) => { value.rateLimits[0].limit = 0; },
    (value) => { value.rateLimits[0].period = 30; },
    (value) => { value.rateLimits[0].mitigationTimeout = 30; },
    (value) => { value.rateLimits[0].mitigationTimeout = 10; },
    (value) => { value.rateLimits = value.rateLimits.filter(
      (binding) => binding.name !== "BILLING_APPLE_NOTIFICATION_RATE_LIMITER",
    ); },
  ]) {
    const value = manifestValue();
    mutate(value);
    assert.throws(
      () => parseActiveWorkerRateLimitManifest(JSON.stringify(value)),
      /invalid|incomplete|unique/u,
    );
  }
  assert.throws(
    () => parseActiveWorkerRateLimitManifest("x".repeat(65 * 1024)),
    /invalid/u,
  );
  assert.throws(
    () => parseActiveWorkerRateLimitManifest(
      JSON.stringify(manifestValue()).replace(
        '"schemaVersion":1',
        '"schemaVersion":1,"schemaVersion":1',
      ),
    ),
    /duplicate/u,
  );
  assert.throws(
    () => parseActiveWorkerRateLimitManifest(
      JSON.stringify(manifestValue()).replace('"limit":5', '"limit":5,"limit":5'),
    ),
    /duplicate/u,
  );
});

test("accepts the token only from a bounded single-line value", () => {
  assert.equal(requireCloudflareAPIToken(token), token);
  for (const value of [undefined, "", " token", "token ", "token\nother", "token\rother"]) {
    assert.throws(() => requireCloudflareAPIToken(value), /unavailable/u);
  }
});

test("attests one exact active version and the complete rate-limit binding set", async () => {
  const calls = [];
  const passed = await attestActiveWorkerRateLimits({
    manifest: manifest(),
    token,
    fetchImpl: sequenceFetch([
      deploymentsResult(),
      versionResult(),
      deploymentsResult(),
    ], calls),
  });
  assert.equal(passed, true);
  assert.equal(calls.length, 3);
  assert.match(calls[0].url, new RegExp(`/accounts/${accountId}/workers/scripts/`));
  assert.match(calls[0].url, /\/deployments$/u);
  assert.match(calls[1].url, new RegExp(`/versions/${versionId}$`));
  assert.equal(calls[2].url, calls[0].url);
  for (const call of calls) {
    assert.equal(call.init.method, "GET");
    assert.equal(call.init.redirect, "manual");
    assert.equal(call.init.headers.Authorization, `Bearer ${token}`);
    assert.equal(call.init.headers.Accept, "application/json");
    assert.ok(call.init.signal instanceof AbortSignal);
  }
});

test("rejects non-single, split, stale, or drifting active deployments", async () => {
  const invalidFirstResponses = [
    envelope({ deployments: [] }),
    deploymentsResult({ strategy: "gradual" }),
    deploymentsResult({ percentage: 99.99 }),
    deploymentsResult({ activeVersionId: "33333333-3333-4333-8333-333333333333" }),
    deploymentsResult({ versions: [
      { version_id: versionId, percentage: 50 },
      { version_id: "33333333-3333-4333-8333-333333333333", percentage: 50 },
    ] }),
  ];
  for (const first of invalidFirstResponses) {
    await assert.rejects(
      attestActiveWorkerRateLimits({
        manifest: manifest(),
        token,
        fetchImpl: sequenceFetch([first]),
      }),
      /invalid|failed/u,
    );
  }

  await assert.rejects(
    attestActiveWorkerRateLimits({
      manifest: manifest(),
      token,
      fetchImpl: sequenceFetch([
        deploymentsResult(),
        versionResult(),
        deploymentsResult({
          activeDeploymentId: "44444444-4444-4444-8444-444444444444",
        }),
      ]),
    }),
    /changed/u,
  );
});

test("rejects every binding-set and exact policy drift", async () => {
  const mutations = [
    (bindings) => { bindings.pop(); },
    (bindings) => { bindings.push({ ...bindings[0], name: "EXTRA_RATE_LIMITER", namespace_id: "700006" }); },
    (bindings) => { bindings[0].namespace_id = "799999"; },
    (bindings) => { bindings[0].simple.limit += 1; },
    (bindings) => { bindings[0].simple.period = 10; },
    (bindings) => { bindings[0].simple.mitigation_timeout = 60; },
    (bindings) => { bindings[0].namespace_id = bindings[1].namespace_id; },
    (bindings) => {
      bindings.find((value) => value.name === "BILLING_APPLE_NOTIFICATION_RATE_LIMITER")
        .namespace_id = bindings.find((value) => value.name === "BILLING_RATE_LIMITER")
          .namespace_id;
    },
    (bindings) => { bindings[0].unknown = true; },
    (bindings) => { bindings[0].simple.unknown = true; },
    (bindings) => { bindings[0] = { type: "ratelimit", name: "BROKEN" }; },
  ];
  for (const mutate of mutations) {
    const bindings = versionResult().result.resources.bindings.slice(1)
      .map((value) => structuredClone(value));
    mutate(bindings);
    await assert.rejects(
      attestActiveWorkerRateLimits({
        manifest: manifest(),
        token,
        fetchImpl: sequenceFetch([
          deploymentsResult(),
          versionResult(bindings),
          deploymentsResult(),
        ]),
      }),
      /invalid|match|unique/u,
    );
  }
});

test("pure exact verifier rejects duplicate and shared active namespaces", () => {
  assert.equal(verifyExactRateLimitBindings(rateLimits, rateLimits), true);
  const duplicate = rateLimits.map((value) => ({ ...value }));
  duplicate[1].namespaceId = duplicate[0].namespaceId;
  assert.throws(
    () => verifyExactRateLimitBindings(duplicate, rateLimits),
    /unique/u,
  );
});

test("fails closed on transport, redirect, status, envelope, size, and JSON errors", async () => {
  const failures = [
    new Error("network details must not escape"),
    new Response("", { status: 302, headers: { Location: "https://example.invalid" } }),
    new Response("{}", { status: 503 }),
    new Response("{}", { status: 200, headers: { "Content-Type": "text/plain" } }),
    jsonResponse(envelope({ deployments: [] }, { success: false })),
    jsonResponse(envelope({ deployments: [] }, { errors: [{ code: 1 }] })),
    new Response("{}", { status: 200, headers: {
      "Content-Type": "application/json",
      "Content-Length": "999999",
    } }),
    new Response("x".repeat(513 * 1024), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }),
    new Response("not-json", {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }),
    new Response(
      '{"success":true,"success":true,"errors":[],"messages":[],"result":{}}',
      { status: 200, headers: { "Content-Type": "application/json" } },
    ),
  ];
  for (const response of failures) {
    await assert.rejects(
      attestActiveWorkerRateLimits({
        manifest: manifest(),
        token,
        fetchImpl: sequenceFetch([response]),
      }),
      /failed|invalid/u,
    );
  }
});

test("aborts a timed-out Cloudflare request", async () => {
  await assert.rejects(
    attestActiveWorkerRateLimits({
      manifest: manifest(),
      token,
      timeoutMilliseconds: 5,
      fetchImpl: async (_url, init) => new Promise((_resolve, reject) => {
        init.signal.addEventListener("abort", () => reject(new Error("aborted")), {
          once: true,
        });
      }),
    }),
    /request failed/u,
  );

  await assert.rejects(
    attestActiveWorkerRateLimits({
      manifest: manifest(),
      token,
      timeoutMilliseconds: 5,
      fetchImpl: async (_url, init) => {
        const body = new ReadableStream({
          start(controller) {
            controller.enqueue(new TextEncoder().encode('{"success":true'));
            init.signal.addEventListener("abort", () => {
              controller.error(new Error("aborted while reading body"));
            }, { once: true });
          },
        });
        return new Response(body, {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      },
    }),
    /request failed/u,
  );
});

test("thin CLI emits only a boolean and never an ID or raw API body", async () => {
  for (const fixture of [
    {
      environment: { CLOUDFLARE_API_TOKEN: token },
      responses: [deploymentsResult(), versionResult(), deploymentsResult()],
      expectedCode: 0,
      expectedOutput: "true\n",
    },
    {
      environment: { CLOUDFLARE_API_TOKEN: "bad\ntoken" },
      responses: [],
      expectedCode: 1,
      expectedOutput: "false\n",
    },
    {
      environment: { CLOUDFLARE_API_TOKEN: token },
      responses: [jsonResponse(envelope({ deployments: [] }, {
        success: false,
        errors: [{ code: 1000, message: `sensitive ${accountId}` }],
      }))],
      expectedCode: 1,
      expectedOutput: "false\n",
    },
    {
      argv: [token],
      environment: {},
      responses: [],
      expectedCode: 1,
      expectedOutput: "false\n",
    },
  ]) {
    let output = "";
    const code = await runActiveWorkerRateLimitAttestationCLI({
      argv: fixture.argv ?? [],
      environment: fixture.environment,
      readFileImpl: async (path, encoding) => {
        assert.equal(path.endsWith(activeWorkerRateLimitManifestName), true);
        assert.equal(encoding, "utf8");
        return JSON.stringify(manifestValue());
      },
      fetchImpl: sequenceFetch(fixture.responses),
      stdout: { write(value) { output += value; } },
    });
    assert.equal(code, fixture.expectedCode);
    assert.equal(output, fixture.expectedOutput);
    assert.doesNotMatch(output, new RegExp(accountId, "u"));
    assert.doesNotMatch(output, new RegExp(versionId, "u"));
    assert.doesNotMatch(output, /sensitive|fixture-token/u);
  }
});

test("the review manifest is ignored and package exposes bounded commands", async () => {
  const projectDirectory = join(import.meta.dirname, "..");
  const [ignore, packageValue] = await Promise.all([
    readFile(join(projectDirectory, ".gitignore"), "utf8"),
    readFile(join(projectDirectory, "package.json"), "utf8").then(JSON.parse),
  ]);
  assert.match(
    ignore,
    new RegExp(`^${activeWorkerRateLimitManifestName.replaceAll(".", "\\.")}$`, "mu"),
  );
  assert.equal(
    packageValue.scripts["check:active-worker-ratelimit-attestation"],
    "node --test test/active-worker-ratelimit-attestation.node-tests.mjs",
  );
  assert.equal(
    packageValue.scripts["active-worker:ratelimit-attestation"],
    "node scripts/check-active-worker-ratelimit-attestation.mjs",
  );
  assert.match(packageValue.scripts.check, /check:active-worker-ratelimit-attestation/u);
});
