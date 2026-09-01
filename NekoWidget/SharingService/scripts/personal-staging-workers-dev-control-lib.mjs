import { readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

const apiOrigin = "https://api.cloudflare.com";
const expectedWorkerName = "neko-window-sharing-staging";
const expectedAccountSubdomain = "nakanishisoya";
const expectedOrigin =
  "https://neko-window-sharing-staging.nakanishisoya.workers.dev";
const requiredZoneScopeAttestation = "cloudflare-all-zones-v1";
const maximumResponseBytes = 512 * 1024;
const defaultTimeoutMilliseconds = 15_000;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const accountPattern = /^[0-9a-f]{32}$/u;

export const workersDevManifestName =
  "personal-staging-workers-dev-control-manifest.json";
export const workersDevRecoveryName =
  "personal-staging-workers-dev-recovery.json";

function fail(message = "personal staging workers.dev control failed") {
  throw new Error(message);
}

function record(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, expected, label) {
  if (!record(value)) fail(`${label} is invalid`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length
      || actual.some((key, index) => key !== wanted[index])) {
    fail(`${label} is invalid`);
  }
}

function exactString(value, pattern, label) {
  if (typeof value !== "string" || !pattern.test(value)) fail(`${label} is invalid`);
  return value;
}

function parseJSON(text, label) {
  if (typeof text !== "string" || Buffer.byteLength(text, "utf8") > 64 * 1024) {
    fail(`${label} is invalid`);
  }
  try {
    return JSON.parse(text);
  } catch {
    fail(`${label} is invalid`);
  }
}

export function validateWorkersDevManifest(value) {
  exactKeys(value, [
    "schemaVersion", "accountId", "workerName", "origin",
    "expectedDeploymentId", "expectedVersionId", "zoneScopeAttestation",
  ], "workers.dev control manifest");
  if (value.schemaVersion !== 1
      || value.workerName !== expectedWorkerName
      || value.origin !== expectedOrigin
      || value.zoneScopeAttestation !== requiredZoneScopeAttestation) {
    fail("workers.dev control manifest is invalid");
  }
  return Object.freeze({
    schemaVersion: 1,
    accountId: exactString(value.accountId, accountPattern, "account ID"),
    workerName: expectedWorkerName,
    origin: expectedOrigin,
    expectedDeploymentId: exactString(
      value.expectedDeploymentId, uuidPattern, "expected deployment ID",
    ),
    expectedVersionId: exactString(
      value.expectedVersionId, uuidPattern, "expected version ID",
    ),
    zoneScopeAttestation: requiredZoneScopeAttestation,
  });
}

export function parseWorkersDevManifest(text) {
  return validateWorkersDevManifest(parseJSON(text, "workers.dev control manifest"));
}

export function validateWorkersDevRecovery(value) {
  exactKeys(value, [
    "schemaVersion", "accountId", "workerName", "origin",
    "expectedDeploymentId", "expectedVersionId", "zoneScopeAttestation", "disabledAt",
  ], "workers.dev recovery receipt");
  const manifest = validateWorkersDevManifest({
    schemaVersion: value.schemaVersion,
    accountId: value.accountId,
    workerName: value.workerName,
    origin: value.origin,
    expectedDeploymentId: value.expectedDeploymentId,
    expectedVersionId: value.expectedVersionId,
    zoneScopeAttestation: value.zoneScopeAttestation,
  });
  if (typeof value.disabledAt !== "string"
      || !Number.isFinite(Date.parse(value.disabledAt))) {
    fail("workers.dev recovery receipt is invalid");
  }
  return Object.freeze({ ...manifest, disabledAt: value.disabledAt });
}

export function requireWorkersDevCredentials(environment) {
  const accountId = exactString(
    environment?.CLOUDFLARE_ACCOUNT_ID,
    accountPattern,
    "CLOUDFLARE_ACCOUNT_ID",
  );
  const token = environment?.CLOUDFLARE_API_TOKEN;
  if (typeof token !== "string" || token.length < 1 || token.length > 2_048
      || token.trim() !== token || !/^[\x21-\x7e]+$/u.test(token)) {
    fail("CLOUDFLARE_API_TOKEN is unavailable");
  }
  if (environment?.CLOUDFLARE_ALL_ZONES_SCOPE_ATTESTED
      !== requiredZoneScopeAttestation) {
    fail("Cloudflare All zones token scope has not been attested");
  }
  return Object.freeze({ accountId, token });
}

function envelope(value, label) {
  if (!record(value)) fail(`${label} is invalid`);
  const allowed = new Set(["success", "errors", "messages", "result", "result_info"]);
  if (Object.keys(value).some((key) => !allowed.has(key))
      || value.success !== true || !Array.isArray(value.errors)
      || value.errors.length !== 0 || !Array.isArray(value.messages)
      || !Object.hasOwn(value, "result")) {
    fail(`${label} is invalid`);
  }
  if (record(value.result_info)
      && Number.isSafeInteger(value.result_info.total_pages)
      && value.result_info.total_pages !== 1) {
    fail(`${label} is not bounded to one page`);
  }
  return value.result;
}

function paginatedEnvelope(value, label, expectedPage, expectedPerPage) {
  if (!record(value)) fail(`${label} is invalid`);
  const allowed = new Set(["success", "errors", "messages", "result", "result_info"]);
  if (Object.keys(value).some((key) => !allowed.has(key))
      || value.success !== true || !Array.isArray(value.errors)
      || value.errors.length !== 0 || !Array.isArray(value.messages)
      || !Array.isArray(value.result) || !record(value.result_info)) {
    fail(`${label} is invalid`);
  }
  exactKeys(value.result_info, [
    "count", "page", "per_page", "total_count", "total_pages",
  ], `${label} pagination`);
  const { count, page, per_page: perPage, total_count: totalCount,
    total_pages: totalPages } = value.result_info;
  if (!Number.isSafeInteger(count) || count !== value.result.length
      || page !== expectedPage || perPage !== expectedPerPage
      || !Number.isSafeInteger(totalCount) || totalCount < 0 || totalCount > 5_000
      || !Number.isSafeInteger(totalPages) || totalPages < 0 || totalPages > 100
      || (totalPages === 0
        ? totalCount !== 0 || page !== 1
        : page > totalPages)) {
    fail(`${label} pagination is invalid`);
  }
  return Object.freeze({
    result: value.result,
    totalCount,
    totalPages,
  });
}

async function boundedJSON(response, label) {
  if (!(response instanceof Response) || response.redirected
      || response.status < 200 || response.status >= 300 || response.body === null
      || response.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase()
        !== "application/json") {
    fail(`${label} failed`);
  }
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumResponseBytes) {
      await reader.cancel();
      fail(`${label} is invalid`);
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
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    fail(`${label} is invalid`);
  }
}

async function apiRequest(path, { token, method = "GET", body, fetchImpl, timeoutMilliseconds }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMilliseconds);
  try {
    const response = await fetchImpl(`${apiOrigin}${path}`, {
      method,
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${token}`,
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      redirect: "manual",
      signal: controller.signal,
    });
    return await boundedJSON(response, "Cloudflare request");
  } catch (error) {
    if (error instanceof Error && error.message.includes("Cloudflare")) throw error;
    fail("Cloudflare request failed");
  } finally {
    clearTimeout(timer);
  }
}

function deploymentFrom(value) {
  const result = envelope(value, "deployment response");
  if (!record(result) || !Array.isArray(result.deployments)
      || result.deployments.length < 1) fail("active deployment is invalid");
  const active = result.deployments[0];
  if (!record(active) || active.strategy !== "percentage"
      || !Array.isArray(active.versions) || active.versions.length !== 1) {
    fail("active deployment is invalid");
  }
  const version = active.versions[0];
  if (!record(version) || version.percentage !== 100) fail("active deployment is invalid");
  return Object.freeze({
    deploymentId: exactString(active.id, uuidPattern, "active deployment ID"),
    versionId: exactString(version.version_id, uuidPattern, "active version ID"),
  });
}

function subdomainFrom(value) {
  const result = envelope(value, "Worker subdomain response");
  exactKeys(result, ["enabled", "previews_enabled"], "Worker subdomain state");
  if (typeof result.enabled !== "boolean" || typeof result.previews_enabled !== "boolean") {
    fail("Worker subdomain state is invalid");
  }
  return Object.freeze({ enabled: result.enabled, previewsEnabled: result.previews_enabled });
}

function sameDeployment(actual, expected) {
  return actual.deploymentId === expected.expectedDeploymentId
    && actual.versionId === expected.expectedVersionId;
}

async function readAllAccountZoneIds({
  accountId,
  token,
  fetchImpl,
  timeoutMilliseconds,
}) {
  const perPage = 50;
  const ids = [];
  const seen = new Set();
  let expectedTotalCount = null;
  let expectedTotalPages = null;

  for (let page = 1; page <= (expectedTotalPages ?? 1); page += 1) {
    const value = await apiRequest(
      `/client/v4/zones?account.id=${accountId}`
        + `&match=all&type=full%2Cpartial%2Csecondary%2Cinternal&per_page=${perPage}&page=${page}`,
      { token, fetchImpl, timeoutMilliseconds },
    );
    const parsed = paginatedEnvelope(value, "account zones response", page, perPage);
    if (expectedTotalCount === null) {
      expectedTotalCount = parsed.totalCount;
      expectedTotalPages = parsed.totalPages;
    } else if (parsed.totalCount !== expectedTotalCount
        || parsed.totalPages !== expectedTotalPages) {
      fail("account zones changed while the route inventory was read");
    }
    for (const zone of parsed.result) {
      if (!record(zone) || !record(zone.account) || zone.account.id !== accountId) {
        fail("account zones response is invalid");
      }
      const id = exactString(zone.id, accountPattern, "zone ID");
      if (seen.has(id)) fail("account zones response contains a duplicate zone");
      seen.add(id);
      ids.push(id);
    }
  }
  if (ids.length !== expectedTotalCount) fail("account zones response is incomplete");
  return Object.freeze(ids);
}

async function assertNoCustomRoutes({
  accountId,
  token,
  fetchImpl,
  timeoutMilliseconds,
}) {
  const zoneIds = await readAllAccountZoneIds({
    accountId, token, fetchImpl, timeoutMilliseconds,
  });
  for (const zoneId of zoneIds) {
    const value = await apiRequest(`/client/v4/zones/${zoneId}/workers/routes`, {
      token, fetchImpl, timeoutMilliseconds,
    });
    const routes = envelope(value, "Worker routes response");
    if (!Array.isArray(routes)) fail("Worker routes response is invalid");
    for (const route of routes) {
      if (!record(route) || typeof route.pattern !== "string"
          || (Object.hasOwn(route, "script") && route.script !== null
            && typeof route.script !== "string")) {
        fail("Worker routes response is invalid");
      }
      if (route.script === expectedWorkerName) {
        fail("reviewed staging Worker has an unexpected custom route");
      }
    }
  }
}

async function readLiveSnapshot({ accountId, token, fetchImpl, timeoutMilliseconds }) {
  const accountBase = `/client/v4/accounts/${accountId}`;
  const worker = encodeURIComponent(expectedWorkerName);
  const scriptBase = `${accountBase}/workers/scripts/${worker}`;
  const [accountSubdomainValue, searchValue, domainsValue, deploymentsValue, subdomainValue] =
    await Promise.all([
      apiRequest(`${accountBase}/workers/subdomain`, {
        token, fetchImpl, timeoutMilliseconds,
      }),
      apiRequest(`${accountBase}/workers/scripts-search?name=${worker}&per_page=100&page=1`, {
        token, fetchImpl, timeoutMilliseconds,
      }),
      apiRequest(`${accountBase}/workers/domains?service=${worker}`, {
        token, fetchImpl, timeoutMilliseconds,
      }),
      apiRequest(`${scriptBase}/deployments`, {
        token, fetchImpl, timeoutMilliseconds,
      }),
      apiRequest(`${scriptBase}/subdomain`, {
        token, fetchImpl, timeoutMilliseconds,
      }),
    ]);

  const accountSubdomain = envelope(accountSubdomainValue, "account subdomain response");
  exactKeys(accountSubdomain, ["subdomain"], "account subdomain");
  if (accountSubdomain.subdomain !== expectedAccountSubdomain) {
    fail("Cloudflare account does not own the reviewed staging origin");
  }

  const scripts = envelope(searchValue, "Worker search response");
  if (!Array.isArray(scripts)) fail("Worker search response is invalid");
  const exact = scripts.filter((item) => record(item) && item.script_name === expectedWorkerName);
  if (exact.length !== 1) fail("reviewed staging Worker identity is ambiguous");

  await assertNoCustomRoutes({ accountId, token, fetchImpl, timeoutMilliseconds });

  const domains = envelope(domainsValue, "Worker domains response");
  if (!Array.isArray(domains)
      || domains.some((item) => !record(item) || item.service !== expectedWorkerName)) {
    fail("Worker domains response is invalid");
  }
  if (domains.length !== 0) fail("reviewed staging Worker has a custom domain");

  return Object.freeze({
    deployment: deploymentFrom(deploymentsValue),
    subdomain: subdomainFrom(subdomainValue),
  });
}

async function setSubdomain({ accountId, token, enabled, fetchImpl, timeoutMilliseconds }) {
  const worker = encodeURIComponent(expectedWorkerName);
  const value = await apiRequest(
    `/client/v4/accounts/${accountId}/workers/scripts/${worker}/subdomain`,
    {
      token,
      method: "POST",
      body: { enabled, previews_enabled: false },
      fetchImpl,
      timeoutMilliseconds,
    },
  );
  const state = subdomainFrom(value);
  if (state.enabled !== enabled || state.previewsEnabled) {
    fail("Cloudflare did not apply the reviewed workers.dev state");
  }
}

async function originIsHealthy(fetchImpl, timeoutMilliseconds) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMilliseconds);
  try {
    const response = await fetchImpl(`${expectedOrigin}/health`, {
      method: "GET",
      headers: { Accept: "application/json" },
      cache: "no-store",
      redirect: "manual",
      signal: controller.signal,
    });
    const body = await boundedJSON(response, "staging health request");
    return record(body) && body.status === "ok" && body.protocolVersion === 1;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function verifyOriginUnavailable(fetchImpl, timeoutMilliseconds, waitImpl) {
  let consecutiveUnavailable = 0;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    if (await originIsHealthy(fetchImpl, timeoutMilliseconds)) {
      consecutiveUnavailable = 0;
    } else {
      consecutiveUnavailable += 1;
      if (consecutiveUnavailable === 3) return;
    }
    if (attempt < 4) await waitImpl(750);
  }
  fail("reviewed staging origin is still serving the application");
}

async function compensateRecoveryToOff({
  accountId,
  token,
  fetchImpl,
  timeoutMilliseconds,
  waitImpl,
}) {
  try {
    await setSubdomain({
      accountId,
      token,
      enabled: false,
      fetchImpl,
      timeoutMilliseconds,
    });
  } catch {
    // The disable request may have been applied before its response was lost.
    // Reconcile the authoritative state below instead of replaying the POST.
  }

  try {
    const snapshot = await readLiveSnapshot({
      accountId,
      token,
      fetchImpl,
      timeoutMilliseconds,
    });
    if (snapshot.subdomain.enabled || snapshot.subdomain.previewsEnabled) {
      fail("compensating workers.dev OFF state was not applied");
    }
    await verifyOriginUnavailable(fetchImpl, timeoutMilliseconds, waitImpl);
  } catch {
    fail("CRITICAL: recovery failed and the reviewed staging ingress could not be verified OFF; recovery receipt retained");
  }
}

async function archiveRecoveryReceipt(projectDirectory, recoveryPath, now, renameImpl) {
  const archivePath = join(
    projectDirectory,
    `personal-staging-workers-dev-recovery.completed-${now().toISOString().replaceAll(":", "-")}.json`,
  );
  await renameImpl(recoveryPath, archivePath);
}

function manifestFor(accountId, snapshot) {
  return Object.freeze({
    schemaVersion: 1,
    accountId,
    workerName: expectedWorkerName,
    origin: expectedOrigin,
    expectedDeploymentId: snapshot.deployment.deploymentId,
    expectedVersionId: snapshot.deployment.versionId,
    zoneScopeAttestation: requiredZoneScopeAttestation,
  });
}

function parseArguments(argv) {
  const mapping = new Map([
    ["--plan", "plan"],
    ["--capture-baseline", "capture"],
    ["--status", "status"],
    ["--confirm-off", "off"],
    ["--confirm-recover", "recover"],
  ]);
  if (!Array.isArray(argv) || argv.length !== 1 || !mapping.has(argv[0])) {
    fail("use exactly --plan, --capture-baseline, --status, --confirm-off, or --confirm-recover");
  }
  return mapping.get(argv[0]);
}

export async function runWorkersDevControl(argv, {
  projectDirectory,
  environment,
  readFileImpl = readFile,
  writeFileImpl = writeFile,
  renameImpl = rename,
  fetchImpl = fetch,
  now = () => new Date(),
  waitImpl = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  timeoutMilliseconds = defaultTimeoutMilliseconds,
} = {}) {
  const action = parseArguments(argv);
  if (typeof projectDirectory !== "string" || projectDirectory.length === 0
      || typeof fetchImpl !== "function" || !Number.isSafeInteger(timeoutMilliseconds)
      || timeoutMilliseconds < 1 || timeoutMilliseconds > 60_000) {
    fail("workers.dev control options are invalid");
  }
  if (action === "plan") {
    return "PASS workers.dev control plan validated; no file or network operation was performed.";
  }

  const { accountId, token } = requireWorkersDevCredentials(environment);
  const manifestPath = join(projectDirectory, workersDevManifestName);
  const recoveryPath = join(projectDirectory, workersDevRecoveryName);

  if (action === "capture") {
    const snapshot = await readLiveSnapshot({
      accountId, token, fetchImpl, timeoutMilliseconds,
    });
    if (!snapshot.subdomain.enabled || snapshot.subdomain.previewsEnabled
        || !await originIsHealthy(fetchImpl, timeoutMilliseconds)) {
      fail("reviewed staging origin is not at the expected healthy baseline");
    }
    await writeFileImpl(
      manifestPath,
      `${JSON.stringify(manifestFor(accountId, snapshot), null, 2)}\n`,
      { encoding: "utf8", flag: "wx", mode: 0o600 },
    );
    return "PASS workers.dev baseline captured for the fixed personal staging Worker; credential-visible routes are absent; no Cloudflare state was changed.";
  }

  const manifest = parseWorkersDevManifest(await readFileImpl(manifestPath, "utf8"));
  if (manifest.accountId !== accountId) fail("credential account does not match the reviewed manifest");

  if (action === "status") {
    const snapshot = await readLiveSnapshot({
      accountId, token, fetchImpl, timeoutMilliseconds,
    });
    if (!sameDeployment(snapshot.deployment, manifest)
        || snapshot.subdomain.previewsEnabled) {
      fail("active deployment changed after baseline capture");
    }
    if (snapshot.subdomain.enabled) {
      if (!await originIsHealthy(fetchImpl, timeoutMilliseconds)) {
        fail("workers.dev is enabled but the reviewed origin is not healthy");
      }
    } else {
      await verifyOriginUnavailable(fetchImpl, timeoutMilliseconds, waitImpl);
    }
    return `PASS workers.dev status ${snapshot.subdomain.enabled ? "ON" : "OFF"}; preview URLs OFF; active deployment unchanged; credential-visible routes absent.`;
  }

  if (action === "off") {
    const first = await readLiveSnapshot({ accountId, token, fetchImpl, timeoutMilliseconds });
    const second = await readLiveSnapshot({ accountId, token, fetchImpl, timeoutMilliseconds });
    if (!sameDeployment(first.deployment, manifest)
        || !sameDeployment(second.deployment, manifest)
        || !first.subdomain.enabled || first.subdomain.previewsEnabled
        || !second.subdomain.enabled || second.subdomain.previewsEnabled
        || !await originIsHealthy(fetchImpl, timeoutMilliseconds)) {
      fail("workers.dev OFF precondition failed");
    }
    const disabledAt = now().toISOString();
    await writeFileImpl(
      recoveryPath,
      `${JSON.stringify({ ...manifest, disabledAt }, null, 2)}\n`,
      { encoding: "utf8", flag: "wx", mode: 0o600 },
    );
    await setSubdomain({
      accountId, token, enabled: false, fetchImpl, timeoutMilliseconds,
    });
    const after = await readLiveSnapshot({ accountId, token, fetchImpl, timeoutMilliseconds });
    if (!sameDeployment(after.deployment, manifest)
        || after.subdomain.enabled || after.subdomain.previewsEnabled) {
      fail("workers.dev OFF verification failed; use the recovery command, not OFF again");
    }
    await verifyOriginUnavailable(fetchImpl, timeoutMilliseconds, waitImpl);
    return "PASS fixed personal staging workers.dev origin is OFF; preview URLs are OFF; active deployment is unchanged; credential-visible routes remain absent.";
  }

  const recovery = validateWorkersDevRecovery(parseJSON(
    await readFileImpl(recoveryPath, "utf8"),
    "workers.dev recovery receipt",
  ));
  for (const key of [
    "accountId", "workerName", "origin", "expectedDeploymentId", "expectedVersionId",
    "zoneScopeAttestation",
  ]) {
    if (recovery[key] !== manifest[key]) fail("recovery receipt does not match the reviewed manifest");
  }
  const first = await readLiveSnapshot({ accountId, token, fetchImpl, timeoutMilliseconds });
  const second = await readLiveSnapshot({ accountId, token, fetchImpl, timeoutMilliseconds });
  if (!sameDeployment(first.deployment, manifest)
      || !sameDeployment(second.deployment, manifest)
      || first.subdomain.previewsEnabled || second.subdomain.previewsEnabled) {
    if (first.subdomain.enabled || second.subdomain.enabled
        || first.subdomain.previewsEnabled || second.subdomain.previewsEnabled) {
      await compensateRecoveryToOff({
        accountId, token, fetchImpl, timeoutMilliseconds, waitImpl,
      });
      fail("workers.dev recovery precondition failed; ingress returned OFF and recovery receipt retained");
    }
    fail("workers.dev recovery precondition failed; recovery receipt retained");
  }
  if (first.subdomain.enabled || second.subdomain.enabled) {
    try {
      if (!first.subdomain.enabled || !second.subdomain.enabled
          || !await originIsHealthy(fetchImpl, timeoutMilliseconds)) {
        fail("workers.dev recovery precondition is ambiguous");
      }
      const finalSnapshot = await readLiveSnapshot({
        accountId, token, fetchImpl, timeoutMilliseconds,
      });
      if (!sameDeployment(finalSnapshot.deployment, manifest)
          || !finalSnapshot.subdomain.enabled
          || finalSnapshot.subdomain.previewsEnabled) {
        fail("workers.dev recovery verification failed");
      }
      await archiveRecoveryReceipt(projectDirectory, recoveryPath, now, renameImpl);
      return "PASS fixed personal staging workers.dev origin was already recovered; preview URLs are OFF; the same deployment is healthy; credential-visible routes remain absent.";
    } catch {
      await compensateRecoveryToOff({
        accountId, token, fetchImpl, timeoutMilliseconds, waitImpl,
      });
      fail("workers.dev recovery verification failed; ingress returned OFF and recovery receipt retained");
    }
  }

  try {
    try {
      await setSubdomain({ accountId, token, enabled: true, fetchImpl, timeoutMilliseconds });
    } catch {
      // The request may have been applied before its response was lost. The
      // authoritative state is reconciled below instead of replaying the POST.
    }
    const after = await readLiveSnapshot({ accountId, token, fetchImpl, timeoutMilliseconds });
    const healthy = after.subdomain.enabled
      && !after.subdomain.previewsEnabled
      && await originIsHealthy(fetchImpl, timeoutMilliseconds);
    if (!sameDeployment(after.deployment, manifest) || !healthy) {
      fail("workers.dev recovery verification failed");
    }
    const finalSnapshot = await readLiveSnapshot({
      accountId, token, fetchImpl, timeoutMilliseconds,
    });
    if (!sameDeployment(finalSnapshot.deployment, manifest)
        || !finalSnapshot.subdomain.enabled
        || finalSnapshot.subdomain.previewsEnabled) {
      fail("workers.dev recovery verification failed");
    }
    await archiveRecoveryReceipt(projectDirectory, recoveryPath, now, renameImpl);
    return "PASS fixed personal staging workers.dev origin recovered; preview URLs are OFF; the same deployment is healthy; credential-visible routes remain absent.";
  } catch {
    await compensateRecoveryToOff({
      accountId, token, fetchImpl, timeoutMilliseconds, waitImpl,
    });
    fail("workers.dev recovery verification failed; ingress returned OFF and recovery receipt retained");
  }
}
