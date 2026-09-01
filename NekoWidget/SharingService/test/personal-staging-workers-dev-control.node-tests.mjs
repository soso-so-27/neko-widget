import assert from "node:assert/strict";
import { basename } from "node:path";
import test from "node:test";

import {
  requireWorkersDevCredentials,
  runWorkersDevControl,
  validateWorkersDevManifest,
  workersDevManifestName,
  workersDevRecoveryName,
} from "../scripts/personal-staging-workers-dev-control-lib.mjs";

const accountId = "0123456789abcdef0123456789abcdef";
const otherAccountId = "fedcba9876543210fedcba9876543210";
const deploymentId = "11111111-1111-4111-8111-111111111111";
const otherDeploymentId = "33333333-3333-4333-8333-333333333333";
const versionId = "22222222-2222-4222-8222-222222222222";
const databaseId = "44444444-4444-4444-8444-444444444444";
const otherDatabaseId = "55555555-5555-4555-8555-555555555555";
const token = "fixture-token";
const zoneScopeAttestation = "cloudflare-all-zones-v1";
const projectDirectory = "C:\\reviewed\\sharing-service";
const workerName = "neko-window-sharing-staging";
const databaseName = "neko-window-sharing-staging";
const origin = "https://neko-window-sharing-staging.nakanishisoya.workers.dev";
const zoneId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

function manifest(overrides = {}) {
  return {
    schemaVersion: 2,
    accountId,
    workerName,
    origin,
    expectedDeploymentId: deploymentId,
    expectedVersionId: versionId,
    databaseId,
    zoneScopeAttestation,
    ...overrides,
  };
}

function recovery(overrides = {}) {
  return {
    ...manifest(),
    disabledAt: "2030-01-02T03:04:05.000Z",
    ...overrides,
  };
}

function envelope(result) {
  return {
    success: true,
    errors: [],
    messages: [],
    result,
  };
}

function jsonResponse(value) {
  return new Response(JSON.stringify(value), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function healthResponse() {
  return jsonResponse({ status: "ok", protocolVersion: 1 });
}

function liveCloudflare({
  enabled = true,
  previewsEnabled = false,
  activeDeploymentId = deploymentId,
  activeVersionId = versionId,
  activeDatabaseId = databaseId,
  databaseDetailId = activeDatabaseId,
  databaseDetailName = databaseName,
  versionBindings,
  scriptsSearchRoutes,
  zonePages = [[zoneId]],
  routesByZone = {},
  domains = [],
  events = [],
} = {}) {
  const state = { enabled, previewsEnabled };
  const calls = [];
  const fetchImpl = async (input, init = {}) => {
    const url = String(input);
    const method = init.method ?? "GET";
    calls.push({ url, method, init });

    if (url === `${origin}/health`) {
      events.push(state.enabled ? "health:on" : "health:off");
      return state.enabled
        ? healthResponse()
        : new Response("not found", {
          status: 404,
          headers: { "Content-Type": "text/plain" },
        });
    }

    if (url.endsWith(`/workers/scripts/${workerName}/subdomain`)) {
      if (method === "POST") {
        const body = JSON.parse(init.body);
        events.push(`post:${body.enabled}`);
        state.enabled = body.enabled;
        state.previewsEnabled = body.previews_enabled;
      }
      return jsonResponse(envelope({
        enabled: state.enabled,
        previews_enabled: state.previewsEnabled,
      }));
    }
    if (url.endsWith("/workers/subdomain")) {
      return jsonResponse(envelope({ subdomain: "nakanishisoya" }));
    }
    if (url.includes("/workers/scripts-search?")) {
      return jsonResponse(envelope([{
        script_name: workerName,
        ...(scriptsSearchRoutes === undefined ? {} : { routes: scriptsSearchRoutes }),
      }]));
    }
    if (url.includes("/workers/domains?")) {
      return jsonResponse(envelope(domains));
    }
    if (url.endsWith(`/workers/scripts/${workerName}/deployments`)) {
      events.push("deployment:get");
      return jsonResponse(envelope({
        deployments: [{
          id: activeDeploymentId,
          strategy: "percentage",
          versions: [{ version_id: activeVersionId, percentage: 100 }],
        }],
      }));
    }
    if (url.endsWith(`/workers/scripts/${workerName}/versions/${activeVersionId}`)) {
      events.push("version:get");
      return jsonResponse(envelope({
        id: activeVersionId,
        resources: {
          bindings: versionBindings ?? [{
            type: "d1",
            name: "DB",
            id: activeDatabaseId,
            database_id: activeDatabaseId,
          }],
        },
      }));
    }
    if (url.endsWith(`/d1/database/${activeDatabaseId}`)) {
      events.push("d1:get");
      return jsonResponse(envelope({
        uuid: databaseDetailId,
        name: databaseDetailName,
        version: "production",
      }));
    }
    if (url.startsWith("https://api.cloudflare.com/client/v4/zones?")) {
      const page = Number(new URL(url).searchParams.get("page"));
      const ids = zonePages[page - 1];
      if (!Array.isArray(ids)) throw new Error(`unexpected zone page: ${page}`);
      const totalCount = zonePages.reduce((sum, value) => sum + value.length, 0);
      return jsonResponse({
        ...envelope(ids.map((id) => ({ id, account: { id: accountId } }))),
        result_info: {
          count: ids.length,
          page,
          per_page: 50,
          total_count: totalCount,
          total_pages: zonePages.length,
        },
      });
    }
    const routeMatch = url.match(/\/client\/v4\/zones\/([0-9a-f]{32})\/workers\/routes$/u);
    if (routeMatch !== null) {
      return jsonResponse(envelope(routesByZone[routeMatch[1]] ?? []));
    }
    throw new Error(`unexpected request: ${method} ${url}`);
  };
  return { calls, events, fetchImpl, state };
}

function environment(id = accountId) {
  return {
    CLOUDFLARE_ACCOUNT_ID: id,
    CLOUDFLARE_API_TOKEN: token,
    CLOUDFLARE_ALL_ZONES_SCOPE_ATTESTED: zoneScopeAttestation,
  };
}

test("plan validates locally without credentials, files, or network I/O", async () => {
  let operations = 0;
  const forbidden = async () => {
    operations += 1;
    throw new Error("unexpected I/O");
  };
  const result = await runWorkersDevControl(["--plan"], {
    projectDirectory,
    environment: undefined,
    readFileImpl: forbidden,
    writeFileImpl: forbidden,
    renameImpl: forbidden,
    fetchImpl: forbidden,
  });
  assert.match(result, /^PASS workers\.dev control plan validated/u);
  assert.equal(operations, 0);
});

test("manifest and credentials are exact and account mismatch fails before network I/O", async () => {
  assert.deepEqual(validateWorkersDevManifest(manifest()), manifest());
  assert.deepEqual(requireWorkersDevCredentials(environment()), {
    accountId,
    token,
  });
  for (const invalid of [
    { ...manifest(), extra: true },
    manifest({ schemaVersion: 1 }),
    manifest({ accountId: accountId.toUpperCase() }),
    manifest({ workerName: "neko-window-sharing" }),
    manifest({ origin: "https://example.workers.dev" }),
    manifest({ expectedDeploymentId: "not-a-deployment" }),
    manifest({ expectedVersionId: "not-a-version" }),
    manifest({ databaseId: "not-a-database" }),
    manifest({ zoneScopeAttestation: "zone-scope-v0" }),
  ]) assert.throws(() => validateWorkersDevManifest(invalid), /invalid/u);
  for (const invalid of [
    {},
    { CLOUDFLARE_ACCOUNT_ID: "not-an-account", CLOUDFLARE_API_TOKEN: token },
    { CLOUDFLARE_ACCOUNT_ID: accountId, CLOUDFLARE_API_TOKEN: "" },
    { CLOUDFLARE_ACCOUNT_ID: accountId, CLOUDFLARE_API_TOKEN: " token" },
    { CLOUDFLARE_ACCOUNT_ID: accountId, CLOUDFLARE_API_TOKEN: "token\nsecond" },
  ]) assert.throws(() => requireWorkersDevCredentials(invalid), /invalid|unavailable/u);

  await assert.rejects(
    runWorkersDevControl(["--status"], {
      projectDirectory,
      environment: environment(otherAccountId),
      readFileImpl: async () => JSON.stringify(manifest()),
      fetchImpl: async () => { throw new Error("network must not run"); },
    }),
    /credential account does not match/u,
  );
});

test("missing or wrong all-zones attestation fails before file or network I/O", async () => {
  for (const attestation of [undefined, "", "cloudflare-one-zone-v1"]) {
    const input = environment();
    if (attestation === undefined) {
      delete input.CLOUDFLARE_ALL_ZONES_SCOPE_ATTESTED;
    } else {
      input.CLOUDFLARE_ALL_ZONES_SCOPE_ATTESTED = attestation;
    }
    let operations = 0;
    const forbidden = async () => {
      operations += 1;
      throw new Error("unexpected I/O");
    };
    assert.throws(
      () => requireWorkersDevCredentials(input),
      /All zones token scope has not been attested/u,
    );
    await assert.rejects(
      runWorkersDevControl(["--status"], {
        projectDirectory,
        environment: input,
        readFileImpl: forbidden,
        writeFileImpl: forbidden,
        renameImpl: forbidden,
        fetchImpl: forbidden,
      }),
      /All zones token scope has not been attested/u,
    );
    assert.equal(operations, 0);
  }
});

test("baseline capture performs only read requests and creates the manifest with wx", async () => {
  const writes = [];
  const cloudflare = liveCloudflare();
  const result = await runWorkersDevControl(["--capture-baseline"], {
    projectDirectory,
    environment: environment(),
    readFileImpl: async () => { throw new Error("read must not run"); },
    writeFileImpl: async (...args) => { writes.push(args); },
    renameImpl: async () => { throw new Error("rename must not run"); },
    fetchImpl: cloudflare.fetchImpl,
  });

  assert.match(result, /^PASS workers\.dev baseline captured/u);
  assert.equal(cloudflare.calls.some((call) => call.method !== "GET"), false);
  assert.equal(cloudflare.state.enabled, true);
  assert.deepEqual(cloudflare.events.filter((event) =>
    event === "deployment:get" || event === "version:get" || event === "d1:get"), [
    "deployment:get", "version:get", "d1:get", "deployment:get",
  ]);
  assert.equal(writes.length, 1);
  const [path, body, options] = writes[0];
  assert.equal(basename(path), workersDevManifestName);
  assert.deepEqual(JSON.parse(body), manifest());
  assert.deepEqual(options, { encoding: "utf8", flag: "wx", mode: 0o600 });
});

test("status fails closed when the active Worker D1 target is not exact", async (t) => {
  const cases = [
    {
      name: "manifest database differs from active binding",
      options: { activeDatabaseId: otherDatabaseId },
      pattern: /D1 binding changed/u,
    },
    {
      name: "active version has no D1 binding",
      options: { versionBindings: [] },
      pattern: /D1 binding is invalid/u,
    },
    {
      name: "active version has more than one D1 binding",
      options: {
        versionBindings: [
          { type: "d1", name: "DB", id: databaseId, database_id: databaseId },
          {
            type: "d1",
            name: "OTHER_DB",
            id: otherDatabaseId,
            database_id: otherDatabaseId,
          },
        ],
      },
      pattern: /D1 binding is invalid/u,
    },
    {
      name: "active D1 binding has an unexpected field",
      options: {
        versionBindings: [{
          type: "d1",
          name: "DB",
          id: databaseId,
          database_id: databaseId,
          extra: true,
        }],
      },
      pattern: /D1 binding is invalid/u,
    },
    {
      name: "active D1 binding IDs disagree",
      options: {
        versionBindings: [{
          type: "d1",
          name: "DB",
          id: databaseId,
          database_id: otherDatabaseId,
        }],
      },
      pattern: /D1 binding is invalid/u,
    },
    {
      name: "active D1 binding omits database_id",
      options: {
        versionBindings: [{ type: "d1", name: "DB", id: databaseId }],
      },
      pattern: /D1 binding is invalid/u,
    },
    {
      name: "D1 detail returns another database ID",
      options: { databaseDetailId: otherDatabaseId },
      pattern: /not the reviewed staging database/u,
    },
    {
      name: "D1 detail returns another database name",
      options: { databaseDetailName: "neko-window-sharing-production" },
      pattern: /not the reviewed staging database/u,
    },
  ];

  for (const entry of cases) {
    await t.test(entry.name, async () => {
      const cloudflare = liveCloudflare(entry.options);
      await assert.rejects(
        runWorkersDevControl(["--status"], {
          projectDirectory,
          environment: environment(),
          readFileImpl: async () => JSON.stringify(manifest()),
          fetchImpl: cloudflare.fetchImpl,
        }),
        entry.pattern,
      );
      assert.equal(cloudflare.calls.some((call) => call.method !== "GET"), false);
      assert.equal(cloudflare.state.enabled, true);
    });
  }
});

test("snapshot rejects deployment drift around active version and D1 reads", async () => {
  const cloudflare = liveCloudflare();
  let deploymentReads = 0;
  const fetchImpl = async (input, init = {}) => {
    const url = String(input);
    if ((init.method ?? "GET") === "GET"
        && url.endsWith(`/workers/scripts/${workerName}/deployments`)) {
      deploymentReads += 1;
      if (deploymentReads === 2) {
        return jsonResponse(envelope({
          deployments: [{
            id: otherDeploymentId,
            strategy: "percentage",
            versions: [{ version_id: versionId, percentage: 100 }],
          }],
        }));
      }
    }
    return cloudflare.fetchImpl(input, init);
  };

  await assert.rejects(
    runWorkersDevControl(["--status"], {
      projectDirectory,
      environment: environment(),
      readFileImpl: async () => JSON.stringify(manifest()),
      fetchImpl,
    }),
    /deployment changed while the D1 binding was attested/u,
  );
  assert.deepEqual(cloudflare.events.filter((event) =>
    event === "deployment:get" || event === "version:get" || event === "d1:get"), [
    "deployment:get", "version:get", "d1:get",
  ]);
  assert.equal(cloudflare.calls.some((call) => call.method !== "GET"), false);
});

test("snapshot completes D1 detail before requesting deployment-after", async () => {
  const cloudflare = liveCloudflare();
  let deploymentReads = 0;
  let databaseDetailCompleted = false;
  const fetchImpl = async (input, init = {}) => {
    const url = String(input);
    if (url.endsWith(`/d1/database/${databaseId}`)) {
      const response = await cloudflare.fetchImpl(input, init);
      await Promise.resolve();
      databaseDetailCompleted = true;
      return response;
    }
    if ((init.method ?? "GET") === "GET"
        && url.endsWith(`/workers/scripts/${workerName}/deployments`)) {
      deploymentReads += 1;
      if (deploymentReads === 2) {
        assert.equal(databaseDetailCompleted, true);
      }
    }
    return cloudflare.fetchImpl(input, init);
  };

  const result = await runWorkersDevControl(["--status"], {
    projectDirectory,
    environment: environment(),
    readFileImpl: async () => JSON.stringify(manifest()),
    fetchImpl,
  });
  assert.match(result, /status ON/u);
  assert.equal(deploymentReads, 2);
  assert.equal(databaseDetailCompleted, true);
  assert.equal(cloudflare.calls.some((call) => call.method !== "GET"), false);
});

test("successful Cloudflare envelopes accept only null or empty diagnostics", async () => {
  const cloudflare = liveCloudflare();
  const fetchImpl = async (input, init = {}) => {
    const url = String(input);
    if (url.includes("/workers/domains?")) {
      return jsonResponse({
        success: true,
        errors: null,
        messages: null,
        result: [],
        result_info: { page: 1, per_page: 0, count: 0, total_count: 0 },
      });
    }
    if (url.startsWith("https://api.cloudflare.com/client/v4/zones?")) {
      return jsonResponse({
        success: true,
        errors: null,
        messages: null,
        result: [{ id: zoneId, account: { id: accountId } }],
        result_info: {
          count: 1,
          page: 1,
          per_page: 50,
          total_count: 1,
          total_pages: 1,
        },
      });
    }
    if (url.endsWith(`/zones/${zoneId}/workers/routes`)) {
      return jsonResponse({ success: true, errors: null, messages: null, result: [] });
    }
    return cloudflare.fetchImpl(input, init);
  };

  const result = await runWorkersDevControl(["--status"], {
    projectDirectory,
    environment: environment(),
    readFileImpl: async () => JSON.stringify(manifest()),
    fetchImpl,
  });
  assert.match(result, /status ON/u);
  assert.equal(cloudflare.calls.some((call) => call.method !== "GET"), false);
});

test("successful envelopes reject non-empty or wrongly typed diagnostics", async (t) => {
  const validDomainsResultInfo = { page: 1, per_page: 0, count: 0, total_count: 0 };
  const cases = [
    {
      name: "non-empty errors",
      endpoint: "domains",
      errors: [{ code: 1000, message: "fixture" }],
      messages: null,
    },
    {
      name: "non-empty messages",
      endpoint: "domains",
      errors: null,
      messages: [{ code: 1001, message: "fixture" }],
    },
    { name: "object errors", endpoint: "domains", errors: {}, messages: null },
    { name: "string messages", endpoint: "domains", errors: null, messages: "" },
    { name: "paginated object errors", endpoint: "zones", errors: {}, messages: null },
  ];

  for (const entry of cases) {
    await t.test(entry.name, async () => {
      const cloudflare = liveCloudflare();
      const fetchImpl = async (input, init = {}) => {
        const url = String(input);
        if (entry.endpoint === "domains" && url.includes("/workers/domains?")) {
          return jsonResponse({
            success: true,
            errors: entry.errors,
            messages: entry.messages,
            result: [],
            result_info: validDomainsResultInfo,
          });
        }
        if (entry.endpoint === "zones"
            && url.startsWith("https://api.cloudflare.com/client/v4/zones?")) {
          return jsonResponse({
            success: true,
            errors: entry.errors,
            messages: entry.messages,
            result: [{ id: zoneId, account: { id: accountId } }],
            result_info: {
              count: 1,
              page: 1,
              per_page: 50,
              total_count: 1,
              total_pages: 1,
            },
          });
        }
        return cloudflare.fetchImpl(input, init);
      };
      await assert.rejects(
        runWorkersDevControl(["--status"], {
          projectDirectory,
          environment: environment(),
          readFileImpl: async () => JSON.stringify(manifest()),
          writeFileImpl: async () => { throw new Error("write must not run"); },
          renameImpl: async () => { throw new Error("rename must not run"); },
          fetchImpl,
        }),
        /response is invalid/u,
      );
      assert.equal(cloudflare.calls.some((call) => call.method !== "GET"), false);
    });
  }
});

test("status rejects preview ON and proves OFF with three consecutive unavailable checks", async () => {
  const previewCloudflare = liveCloudflare({ previewsEnabled: true });
  await assert.rejects(
    runWorkersDevControl(["--status"], {
      projectDirectory,
      environment: environment(),
      readFileImpl: async () => JSON.stringify(manifest()),
      fetchImpl: previewCloudflare.fetchImpl,
    }),
    /active deployment.*changed/u,
  );
  assert.equal(previewCloudflare.calls.some((call) => call.method !== "GET"), false);

  const events = [];
  let waits = 0;
  const offCloudflare = liveCloudflare({ enabled: false, events });
  const result = await runWorkersDevControl(["--status"], {
    projectDirectory,
    environment: environment(),
    readFileImpl: async () => JSON.stringify(manifest()),
    fetchImpl: offCloudflare.fetchImpl,
    waitImpl: async (milliseconds) => {
      assert.equal(milliseconds, 750);
      waits += 1;
    },
  });
  assert.match(result, /status OFF/u);
  assert.equal(events.filter((event) => event === "health:off").length, 3);
  assert.equal(waits, 2);
  assert.equal(offCloudflare.calls.some((call) => call.method !== "GET"), false);
});

test("status accepts scripts-search without routes after authoritative zone inventory", async () => {
  const cloudflare = liveCloudflare();
  const result = await runWorkersDevControl(["--status"], {
    projectDirectory,
    environment: environment(),
    readFileImpl: async () => JSON.stringify(manifest()),
    writeFileImpl: async () => { throw new Error("write must not run"); },
    renameImpl: async () => { throw new Error("rename must not run"); },
    fetchImpl: cloudflare.fetchImpl,
  });
  assert.match(result, /status ON/u);
  assert.equal(cloudflare.calls.some((call) =>
    call.url.startsWith("https://api.cloudflare.com/client/v4/zones?")), true);
  assert.equal(cloudflare.calls.some((call) =>
    call.url.endsWith(`/zones/${zoneId}/workers/routes`)), true);
  assert.equal(cloudflare.calls.some((call) => call.method !== "GET"), false);
  assert.equal(cloudflare.state.enabled, true);
});

test("route inventory reads every zone page and detects the target Worker on the last page", async (t) => {
  const zoneIds = Array.from(
    { length: 51 },
    (_, index) => (index + 1).toString(16).padStart(32, "0"),
  );
  const zonePages = [zoneIds.slice(0, 50), zoneIds.slice(50)];

  await t.test("complete multi-page inventory passes", async () => {
    const cloudflare = liveCloudflare({ zonePages });
    const result = await runWorkersDevControl(["--status"], {
      projectDirectory,
      environment: environment(),
      readFileImpl: async () => JSON.stringify(manifest()),
      fetchImpl: cloudflare.fetchImpl,
    });
    assert.match(result, /status ON/u);
    const zonePageCalls = cloudflare.calls.filter((call) =>
      call.url.startsWith("https://api.cloudflare.com/client/v4/zones?"));
    assert.deepEqual(zonePageCalls.map((call) =>
      Number(new URL(call.url).searchParams.get("page"))), [1, 2]);
    assert.equal(cloudflare.calls.filter((call) =>
      /\/zones\/[0-9a-f]{32}\/workers\/routes$/u.test(call.url)).length, 51);
  });

  await t.test("target route on a zone from the last page fails closed", async () => {
    const lastZone = zoneIds.at(-1);
    const cloudflare = liveCloudflare({
      zonePages,
      routesByZone: {
        [lastZone]: [{ pattern: "late.example.test/*", script: workerName }],
      },
    });
    await assert.rejects(
      runWorkersDevControl(["--status"], {
        projectDirectory,
        environment: environment(),
        readFileImpl: async () => JSON.stringify(manifest()),
        fetchImpl: cloudflare.fetchImpl,
      }),
      /unexpected custom route/u,
    );
    assert.equal(cloudflare.calls.some((call) =>
      call.url.endsWith(`/zones/${lastZone}/workers/routes`)), true);
    assert.equal(cloudflare.calls.some((call) => call.method !== "GET"), false);
  });
});

test("missing, malformed, incomplete, or unavailable route inventory fails closed", async (t) => {
  const cases = [
    {
      name: "missing pagination",
      intercept: (url) => url.startsWith("https://api.cloudflare.com/client/v4/zones?")
        ? jsonResponse(envelope([{ id: zoneId, account: { id: accountId } }]))
        : null,
      pattern: /account zones response is invalid/u,
    },
    {
      name: "malformed pagination",
      intercept: (url) => url.startsWith("https://api.cloudflare.com/client/v4/zones?")
        ? jsonResponse({
          ...envelope([{ id: zoneId, account: { id: accountId } }]),
          result_info: {
            count: 2,
            page: 1,
            per_page: 50,
            total_count: 1,
            total_pages: 1,
          },
        })
        : null,
      pattern: /pagination is invalid/u,
    },
    {
      name: "incomplete pagination",
      intercept: (url) => url.startsWith("https://api.cloudflare.com/client/v4/zones?")
        ? jsonResponse({
          ...envelope([{ id: zoneId, account: { id: accountId } }]),
          result_info: {
            count: 1,
            page: 1,
            per_page: 50,
            total_count: 2,
            total_pages: 1,
          },
        })
        : null,
      pattern: /response is incomplete/u,
    },
    {
      name: "route inventory unavailable",
      intercept: (url) => url.endsWith(`/zones/${zoneId}/workers/routes`)
        ? new Response("unavailable", {
          status: 503,
          headers: { "Content-Type": "text/plain" },
        })
        : null,
      pattern: /Cloudflare request failed/u,
    },
  ];

  for (const entry of cases) {
    await t.test(entry.name, async () => {
      const cloudflare = liveCloudflare();
      const fetchImpl = async (input, init = {}) =>
        entry.intercept(String(input)) ?? cloudflare.fetchImpl(input, init);
      await assert.rejects(
        runWorkersDevControl(["--status"], {
          projectDirectory,
          environment: environment(),
          readFileImpl: async () => JSON.stringify(manifest()),
          writeFileImpl: async () => { throw new Error("write must not run"); },
          renameImpl: async () => { throw new Error("rename must not run"); },
          fetchImpl,
        }),
        entry.pattern,
      );
      assert.equal(cloudflare.calls.some((call) => call.method !== "GET"), false);
      assert.equal(cloudflare.state.enabled, true);
    });
  }
});

test("OFF takes two unchanged snapshots, writes recovery first, disables ingress, and proves it unreachable", async () => {
  const events = [];
  const writes = [];
  let waits = 0;
  const cloudflare = liveCloudflare({ events });
  const result = await runWorkersDevControl(["--confirm-off"], {
    projectDirectory,
    environment: environment(),
    readFileImpl: async (path) => {
      assert.equal(basename(path), workersDevManifestName);
      return JSON.stringify(manifest());
    },
    writeFileImpl: async (path, body, options) => {
      events.push("receipt:write");
      writes.push({ path, body, options });
    },
    renameImpl: async () => { throw new Error("rename must not run"); },
    fetchImpl: cloudflare.fetchImpl,
    now: () => new Date("2030-01-02T03:04:05.000Z"),
    waitImpl: async (milliseconds) => {
      assert.equal(milliseconds, 750);
      waits += 1;
    },
  });

  assert.match(result, /origin is OFF/u);
  assert.equal(events.filter((event) => event === "deployment:get").length, 6);
  assert.equal(events.filter((event) => event === "health:off").length, 3);
  assert.equal(waits, 2);
  assert.ok(events.indexOf("receipt:write") < events.indexOf("post:false"));
  assert.ok(events.indexOf("post:false") < events.indexOf("health:off"));
  const posts = cloudflare.calls.filter((call) => call.method === "POST");
  assert.equal(posts.length, 1);
  assert.deepEqual(JSON.parse(posts[0].init.body), {
    enabled: false,
    previews_enabled: false,
  });
  assert.equal(cloudflare.state.enabled, false);
  assert.equal(writes.length, 1);
  assert.equal(basename(writes[0].path), workersDevRecoveryName);
  assert.deepEqual(JSON.parse(writes[0].body), recovery());
  assert.deepEqual(writes[0].options, { encoding: "utf8", flag: "wx", mode: 0o600 });
});

test("recovery takes two unchanged snapshots, enables ingress, proves health, and archives the receipt", async () => {
  const events = [];
  const renames = [];
  const cloudflare = liveCloudflare({ enabled: false, events });
  const result = await runWorkersDevControl(["--confirm-recover"], {
    projectDirectory,
    environment: environment(),
    readFileImpl: async (path) => {
      if (basename(path) === workersDevManifestName) return JSON.stringify(manifest());
      if (basename(path) === workersDevRecoveryName) return JSON.stringify(recovery());
      throw new Error("unexpected file");
    },
    writeFileImpl: async () => { throw new Error("write must not run"); },
    renameImpl: async (...args) => {
      events.push("receipt:archive");
      renames.push(args);
    },
    fetchImpl: cloudflare.fetchImpl,
    now: () => new Date("2030-01-02T03:04:06.000Z"),
  });

  assert.match(result, /origin recovered/u);
  assert.equal(events.filter((event) => event === "deployment:get").length, 8);
  assert.ok(events.indexOf("post:true") < events.indexOf("health:on"));
  assert.ok(events.indexOf("health:on") < events.indexOf("receipt:archive"));
  const posts = cloudflare.calls.filter((call) => call.method === "POST");
  assert.equal(posts.length, 1);
  assert.deepEqual(JSON.parse(posts[0].init.body), {
    enabled: true,
    previews_enabled: false,
  });
  assert.equal(cloudflare.state.enabled, true);
  assert.equal(renames.length, 1);
  assert.equal(basename(renames[0][0]), workersDevRecoveryName);
  assert.match(
    basename(renames[0][1]),
    /^personal-staging-workers-dev-recovery\.completed-2030-01-02T03-04-06\.000Z\.json$/u,
  );
});

test("recovery reconciles a lost enable response, archives once, and never enables twice", async () => {
  const events = [];
  const renames = [];
  const cloudflare = liveCloudflare({ enabled: false, events });
  const fetchImpl = async (input, init = {}) => {
    const response = await cloudflare.fetchImpl(input, init);
    if ((init.method ?? "GET") === "POST"
        && JSON.parse(init.body).enabled === true) {
      throw new Error("simulated lost POST response");
    }
    return response;
  };

  const result = await runWorkersDevControl(["--confirm-recover"], {
    projectDirectory,
    environment: environment(),
    readFileImpl: async (path) => {
      if (basename(path) === workersDevManifestName) return JSON.stringify(manifest());
      if (basename(path) === workersDevRecoveryName) return JSON.stringify(recovery());
      throw new Error("unexpected file");
    },
    writeFileImpl: async () => { throw new Error("write must not run"); },
    renameImpl: async (...args) => {
      events.push("receipt:archive");
      renames.push(args);
    },
    fetchImpl,
    now: () => new Date("2030-01-02T03:04:07.000Z"),
  });

  assert.match(result, /origin recovered/u);
  const enablePosts = cloudflare.calls.filter((call) => call.method === "POST"
    && JSON.parse(call.init.body).enabled === true);
  assert.equal(enablePosts.length, 1);
  assert.equal(cloudflare.state.enabled, true);
  assert.equal(events.filter((event) => event === "health:on").length, 1);
  assert.equal(renames.length, 1);
  assert.equal(basename(renames[0][0]), workersDevRecoveryName);
  assert.match(
    basename(renames[0][1]),
    /^personal-staging-workers-dev-recovery\.completed-2030-01-02T03-04-07\.000Z\.json$/u,
  );
});

test("recovery compensates when the first post-enable authoritative snapshot is unavailable", async () => {
  const events = [];
  const renames = [];
  let zoneInventoryReads = 0;
  let waits = 0;
  const cloudflare = liveCloudflare({ enabled: false, events });
  const fetchImpl = async (input, init = {}) => {
    const url = String(input);
    if ((init.method ?? "GET") === "GET"
        && url.startsWith("https://api.cloudflare.com/client/v4/zones?")) {
      zoneInventoryReads += 1;
      if (zoneInventoryReads === 3) {
        events.push("zones:unavailable-after-enable");
        return new Response("unavailable", {
          status: 503,
          headers: { "Content-Type": "text/plain" },
        });
      }
    }
    return cloudflare.fetchImpl(input, init);
  };

  await assert.rejects(
    runWorkersDevControl(["--confirm-recover"], {
      projectDirectory,
      environment: environment(),
      readFileImpl: async (path) => {
        if (basename(path) === workersDevManifestName) return JSON.stringify(manifest());
        if (basename(path) === workersDevRecoveryName) return JSON.stringify(recovery());
        throw new Error("unexpected file");
      },
      writeFileImpl: async () => { throw new Error("write must not run"); },
      renameImpl: async (...args) => { renames.push(args); },
      fetchImpl,
      waitImpl: async (milliseconds) => {
        assert.equal(milliseconds, 750);
        waits += 1;
      },
    }),
    /verification failed.*returned OFF.*receipt retained/u,
  );

  const posts = cloudflare.calls.filter((call) => call.method === "POST")
    .map((call) => JSON.parse(call.init.body));
  assert.deepEqual(posts, [
    { enabled: true, previews_enabled: false },
    { enabled: false, previews_enabled: false },
  ]);
  assert.ok(events.indexOf("post:true")
    < events.indexOf("zones:unavailable-after-enable"));
  assert.ok(events.indexOf("zones:unavailable-after-enable")
    < events.indexOf("post:false"));
  assert.equal(cloudflare.state.enabled, false);
  assert.equal(events.filter((event) => event === "health:on").length, 0);
  assert.equal(events.filter((event) => event === "health:off").length, 3);
  assert.equal(waits, 2);
  assert.equal(renames.length, 0);

  const compensationIndex = cloudflare.calls.findIndex((call) => call.method === "POST"
    && JSON.parse(call.init.body).enabled === false);
  assert.ok(compensationIndex >= 0);
  assert.equal(cloudflare.calls.slice(compensationIndex + 1).some((call) =>
    call.method === "GET"
      && call.url.endsWith(`/workers/scripts/${workerName}/subdomain`)), true);
});

test("recovery compensates post-health deployment drift, verifies OFF, and retains the receipt", async () => {
  const events = [];
  const renames = [];
  let deploymentReads = 0;
  let waits = 0;
  const cloudflare = liveCloudflare({ enabled: false, events });
  const fetchImpl = async (input, init = {}) => {
    const url = String(input);
    if ((init.method ?? "GET") === "GET"
        && url.endsWith(`/workers/scripts/${workerName}/deployments`)) {
      deploymentReads += 1;
      const response = await cloudflare.fetchImpl(input, init);
      if (deploymentReads >= 7) {
        events.push("deployment:drift");
        return jsonResponse(envelope({
          deployments: [{
            id: otherDeploymentId,
            strategy: "percentage",
            versions: [{ version_id: versionId, percentage: 100 }],
          }],
        }));
      }
      return response;
    }
    return cloudflare.fetchImpl(input, init);
  };

  await assert.rejects(
    runWorkersDevControl(["--confirm-recover"], {
      projectDirectory,
      environment: environment(),
      readFileImpl: async (path) => {
        if (basename(path) === workersDevManifestName) return JSON.stringify(manifest());
        if (basename(path) === workersDevRecoveryName) return JSON.stringify(recovery());
        throw new Error("unexpected file");
      },
      writeFileImpl: async () => { throw new Error("write must not run"); },
      renameImpl: async (...args) => { renames.push(args); },
      fetchImpl,
      waitImpl: async (milliseconds) => {
        assert.equal(milliseconds, 750);
        waits += 1;
      },
    }),
    /drift|changed|retained|recovery verification/u,
  );

  const posts = cloudflare.calls.filter((call) => call.method === "POST")
    .map((call) => JSON.parse(call.init.body));
  assert.deepEqual(posts, [
    { enabled: true, previews_enabled: false },
    { enabled: false, previews_enabled: false },
  ]);
  assert.ok(events.indexOf("health:on") < events.indexOf("deployment:drift"));
  assert.ok(events.indexOf("deployment:drift") < events.indexOf("post:false"));
  assert.equal(events.filter((event) => event === "health:off").length, 3);
  assert.equal(waits, 2);
  assert.equal(cloudflare.state.enabled, false);
  assert.equal(renames.length, 0);

  const compensationIndex = cloudflare.calls.findIndex((call) => call.method === "POST"
    && JSON.parse(call.init.body).enabled === false);
  assert.ok(compensationIndex >= 0);
  assert.equal(cloudflare.calls.slice(compensationIndex + 1).some((call) =>
    call.method === "GET"
      && call.url.endsWith(`/workers/scripts/${workerName}/subdomain`)), true);
});

test("unverifiable recovery compensation is critical and retains the receipt", async () => {
  const events = [];
  const renames = [];
  let deploymentReads = 0;
  const cloudflare = liveCloudflare({ enabled: false, events });
  const fetchImpl = async (input, init = {}) => {
    const url = String(input);
    const method = init.method ?? "GET";
    if (method === "GET"
        && url.endsWith(`/workers/scripts/${workerName}/deployments`)) {
      deploymentReads += 1;
      const response = await cloudflare.fetchImpl(input, init);
      if (deploymentReads >= 7) {
        events.push("deployment:drift");
        return jsonResponse(envelope({
          deployments: [{
            id: otherDeploymentId,
            strategy: "percentage",
            versions: [{ version_id: versionId, percentage: 100 }],
          }],
        }));
      }
      return response;
    }
    const response = await cloudflare.fetchImpl(input, init);
    if (method === "POST" && JSON.parse(init.body).enabled === false) {
      cloudflare.state.enabled = true;
      events.push("compensation:not-applied");
    }
    return response;
  };

  await assert.rejects(
    runWorkersDevControl(["--confirm-recover"], {
      projectDirectory,
      environment: environment(),
      readFileImpl: async (path) => {
        if (basename(path) === workersDevManifestName) return JSON.stringify(manifest());
        if (basename(path) === workersDevRecoveryName) return JSON.stringify(recovery());
        throw new Error("unexpected file");
      },
      writeFileImpl: async () => { throw new Error("write must not run"); },
      renameImpl: async (...args) => { renames.push(args); },
      fetchImpl,
      waitImpl: async () => {},
    }),
    /critical/iu,
  );

  const posts = cloudflare.calls.filter((call) => call.method === "POST")
    .map((call) => JSON.parse(call.init.body));
  assert.deepEqual(posts.slice(0, 2), [
    { enabled: true, previews_enabled: false },
    { enabled: false, previews_enabled: false },
  ]);
  assert.equal(events.includes("compensation:not-applied"), true);
  assert.equal(cloudflare.state.enabled, true);
  assert.equal(renames.length, 0);
});

test("deployment drift, custom routes, and custom domains all fail closed", async (t) => {
  const cases = [
    {
      name: "deployment drift",
      options: { activeDeploymentId: otherDeploymentId },
      pattern: /active deployment.*changed/u,
    },
    {
      name: "custom route",
      options: {
        routesByZone: {
          [zoneId]: [{ pattern: "staging.example.test/*", script: workerName }],
        },
      },
      pattern: /unexpected custom route/u,
    },
    {
      name: "custom domain",
      options: { domains: [{ service: workerName, hostname: "staging.example.test" }] },
      pattern: /custom domain/u,
    },
  ];
  for (const entry of cases) {
    await t.test(entry.name, async () => {
      const cloudflare = liveCloudflare(entry.options);
      await assert.rejects(
        runWorkersDevControl(["--status"], {
          projectDirectory,
          environment: environment(),
          readFileImpl: async () => JSON.stringify(manifest()),
          writeFileImpl: async () => { throw new Error("write must not run"); },
          renameImpl: async () => { throw new Error("rename must not run"); },
          fetchImpl: cloudflare.fetchImpl,
        }),
        entry.pattern,
      );
      assert.equal(cloudflare.calls.some((call) => call.method !== "GET"), false);
      assert.equal(cloudflare.state.enabled, true);
    });
  }
});
