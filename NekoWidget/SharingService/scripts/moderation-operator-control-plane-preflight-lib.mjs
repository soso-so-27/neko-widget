const failureCode = "operator_control_plane_preflight_failed";
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const accountIdPattern = /^[0-9a-f]{32}$/u;
const audiencePattern = /^[0-9a-f]{64}$/u;
const domainLabelPattern = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u;
const accessIssuerPattern =
  /^https:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.cloudflareaccess\.com$/u;
const limiterIdPattern = /^[A-Z][A-Z0-9_]{2,63}$/u;
const namespaceIdPattern = /^(?:[1-9][0-9]{0,15})$/u;

export class ModerationOperatorControlPlanePreflightError extends Error {
  constructor() {
    super("Moderation operator control-plane preflight failed.");
    this.name = "ModerationOperatorControlPlanePreflightError";
    this.code = failureCode;
  }
}

function fail() {
  throw new ModerationOperatorControlPlanePreflightError();
}

function assertPlainData(value, seen = new WeakSet(), depth = 0) {
  if (depth > 12) fail();
  if (value === null || typeof value === "boolean") return;
  if (typeof value === "string") {
    if (value.length > 4_096 || value.includes("\0")) fail();
    return;
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) fail();
    return;
  }
  if (typeof value !== "object" || seen.has(value)) fail();
  seen.add(value);

  const prototype = Object.getPrototypeOf(value);
  if (Array.isArray(value)) {
    if (prototype !== Array.prototype || value.length > 256) fail();
    const ownKeys = Reflect.ownKeys(value);
    if (ownKeys.some((key) => typeof key !== "string")
        || ownKeys.length !== value.length + 1) {
      fail();
    }
    for (let index = 0; index < value.length; index += 1) {
      if (!Object.hasOwn(value, index)) fail();
      const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
      if (descriptor === undefined || descriptor.get !== undefined
          || descriptor.set !== undefined || !descriptor.enumerable) {
        fail();
      }
      assertPlainData(descriptor.value, seen, depth + 1);
    }
    return;
  }

  if (prototype !== Object.prototype && prototype !== null) fail();
  const ownKeys = Reflect.ownKeys(value);
  if (ownKeys.length > 64 || ownKeys.some((key) => typeof key !== "string")) {
    fail();
  }
  for (const key of ownKeys) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (descriptor === undefined || descriptor.get !== undefined
        || descriptor.set !== undefined || !descriptor.enumerable) {
      fail();
    }
    assertPlainData(descriptor.value, seen, depth + 1);
  }
}

function object(value) {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    fail();
  }
  return value;
}

function exactKeys(value, keys) {
  const actual = Object.keys(value);
  if (actual.length !== keys.length
      || keys.some((key) => !Object.hasOwn(value, key))) {
    fail();
  }
}

function exactString(value, pattern, maximumLength = 256) {
  if (typeof value !== "string" || value.length < 1
      || value.length > maximumLength || value.trim() !== value
      || !pattern.test(value)) {
    fail();
  }
  return value;
}

function uuid(value) {
  return exactString(value, uuidPattern, 36);
}

function limiterId(value) {
  return exactString(value, limiterIdPattern, 64);
}

function namespaceId(value) {
  const id = exactString(value, namespaceIdPattern, 16);
  const parsed = Number(id);
  if (!Number.isSafeInteger(parsed) || parsed < 1) fail();
  return id;
}

function domain(value) {
  if (typeof value !== "string" || value.length < 3 || value.length > 253
      || value !== value.toLowerCase() || value.endsWith(".")
      || value.includes("*") || value.includes(":") || value.includes("/")
      || value.endsWith(".cloudflareaccess.com")) {
    fail();
  }
  const labels = value.split(".");
  if (labels.length < 2 || labels.some((label) => !domainLabelPattern.test(label))) {
    fail();
  }
  return value;
}

function origin(value, expectedDomain) {
  if (value !== `https://${expectedDomain}`) fail();
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    fail();
  }
  if (parsed.protocol !== "https:" || parsed.hostname !== expectedDomain
      || parsed.username !== "" || parsed.password !== ""
      || parsed.port !== "" || parsed.pathname !== "/"
      || parsed.search !== "" || parsed.hash !== "") {
    fail();
  }
  return value;
}

function positiveInteger(value, maximum = Number.MAX_SAFE_INTEGER) {
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) fail();
  return value;
}

function exactDistinctIds(value, { minimum = 1 } = {}) {
  if (!Array.isArray(value) || value.length < minimum || value.length > 32) {
    fail();
  }
  const ids = value.map(limiterId);
  if (new Set(ids).size !== ids.length) fail();
  return ids;
}

function reviewedRateLimits(value) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 32) fail();
  const limits = new Map();
  for (const rawSpec of value) {
    const spec = object(rawSpec);
    exactKeys(spec, ["limiterId", "periodSeconds", "limit"]);
    const id = limiterId(spec.limiterId);
    if ((spec.periodSeconds !== 10 && spec.periodSeconds !== 60)
        || limits.has(id)) {
      fail();
    }
    positiveInteger(spec.limit);
    limits.set(id, {
      periodSeconds: spec.periodSeconds,
      limit: spec.limit,
    });
  }
  return limits;
}

function reviewedPolicy(value) {
  const policy = object(value);
  exactKeys(policy, [
    "schemaVersion",
    "accountId",
    "applicationId",
    "applicationDomain",
    "applicationOrigin",
    "applicationAudience",
    "accessIssuer",
    "allowPolicyId",
    "identityProviderId",
    "webAuthnRpId",
    "runtimeVerifierIssuer",
    "runtimeVerifierAudience",
    "operatorRateLimits",
    "publicLimiterIds",
  ]);
  if (policy.schemaVersion !== 1) fail();
  const operatorRateLimits = reviewedRateLimits(policy.operatorRateLimits);
  const publicLimiterIds = exactDistinctIds(policy.publicLimiterIds);
  const publicSet = new Set(publicLimiterIds);
  if ([...operatorRateLimits.keys()].some((id) => publicSet.has(id))) fail();
  const applicationDomain = domain(policy.applicationDomain);
  const applicationAudience = exactString(
    policy.applicationAudience,
    audiencePattern,
    64,
  );
  const accessIssuer = exactString(
    policy.accessIssuer,
    accessIssuerPattern,
    256,
  );
  if (policy.webAuthnRpId !== applicationDomain
      || policy.runtimeVerifierIssuer !== accessIssuer
      || policy.runtimeVerifierAudience !== applicationAudience) {
    fail();
  }
  return {
    accountId: exactString(policy.accountId, accountIdPattern, 32),
    applicationId: uuid(policy.applicationId),
    applicationDomain,
    applicationOrigin: origin(policy.applicationOrigin, applicationDomain),
    applicationAudience,
    accessIssuer,
    allowPolicyId: uuid(policy.allowPolicyId),
    identityProviderId: uuid(policy.identityProviderId),
    webAuthnRpId: domain(policy.webAuthnRpId),
    runtimeVerifierIssuer: policy.runtimeVerifierIssuer,
    runtimeVerifierAudience: policy.runtimeVerifierAudience,
    operatorRateLimits,
    publicLimiterIds,
  };
}

function applicationSnapshot(value, reviewed) {
  const application = object(value);
  exactKeys(application, [
    "id",
    "type",
    "domain",
    "origin",
    "audience",
    "accessIssuer",
    "webAuthnRpId",
    "runtimeVerifier",
    "sessionDurationSeconds",
    "policiesComplete",
    "serviceAuthEnabled",
    "warpAuthenticationEnabled",
    "policies",
  ]);
  if (uuid(application.id) !== reviewed.applicationId
      || application.type !== "self_hosted"
      || domain(application.domain) !== reviewed.applicationDomain
      || origin(application.origin, reviewed.applicationDomain)
          !== reviewed.applicationOrigin
      || exactString(application.audience, audiencePattern, 64)
          !== reviewed.applicationAudience
      || exactString(application.accessIssuer, accessIssuerPattern, 256)
          !== reviewed.accessIssuer
      || domain(application.webAuthnRpId) !== reviewed.webAuthnRpId
      || application.policiesComplete !== true
      || application.serviceAuthEnabled !== false
      || application.warpAuthenticationEnabled !== false) {
    fail();
  }
  const runtimeVerifier = object(application.runtimeVerifier);
  exactKeys(runtimeVerifier, ["issuer", "audience"]);
  if (exactString(runtimeVerifier.issuer, accessIssuerPattern, 256)
        !== reviewed.runtimeVerifierIssuer
      || exactString(runtimeVerifier.audience, audiencePattern, 64)
        !== reviewed.runtimeVerifierAudience) {
    fail();
  }
  positiveInteger(application.sessionDurationSeconds, 900);
  if (!Array.isArray(application.policies) || application.policies.length !== 1) {
    fail();
  }
  const policy = object(application.policies[0]);
  exactKeys(policy, [
    "id",
    "decision",
    "sessionDurationSeconds",
    "identityProviderIds",
    "authenticationMethods",
    "mfaReauthentication",
    "managedDevicePostureRequired",
    "everyoneIncluded",
    "serviceTokenIncluded",
    "warpAuthenticationIncluded",
  ]);
  if (uuid(policy.id) !== reviewed.allowPolicyId || policy.decision !== "allow"
      || policy.mfaReauthentication !== "every_session"
      || policy.managedDevicePostureRequired !== true
      || policy.everyoneIncluded !== false
      || policy.serviceTokenIncluded !== false
      || policy.warpAuthenticationIncluded !== false) {
    fail();
  }
  positiveInteger(policy.sessionDurationSeconds, 900);
  if (!Array.isArray(policy.identityProviderIds)
      || policy.identityProviderIds.length !== 1
      || uuid(policy.identityProviderIds[0]) !== reviewed.identityProviderId
      || !Array.isArray(policy.authenticationMethods)
      || policy.authenticationMethods.length !== 1
      || policy.authenticationMethods[0] !== "security_key") {
    fail();
  }
}

function rateLimitSnapshot(value, reviewed) {
  const rateLimits = object(value);
  exactKeys(rateLimits, [
    "accountNamespaceInventoryComplete",
    "operatorBindings",
    "accountNamespaceBindings",
  ]);
  if (rateLimits.accountNamespaceInventoryComplete !== true
      || !Array.isArray(rateLimits.operatorBindings)
      || rateLimits.operatorBindings.length !== reviewed.operatorRateLimits.size
      || !Array.isArray(rateLimits.accountNamespaceBindings)
      || rateLimits.accountNamespaceBindings.length <
          reviewed.operatorRateLimits.size + reviewed.publicLimiterIds.length
      || rateLimits.accountNamespaceBindings.length > 128) {
    fail();
  }

  const operatorBindings = new Map();
  for (const rawBinding of rateLimits.operatorBindings) {
    const binding = object(rawBinding);
    exactKeys(binding, ["limiterId", "namespaceId", "periodSeconds", "limit"]);
    const id = limiterId(binding.limiterId);
    const namespace = namespaceId(binding.namespaceId);
    const expected = reviewed.operatorRateLimits.get(id);
    if (expected === undefined || binding.periodSeconds !== expected.periodSeconds
        || binding.limit !== expected.limit || operatorBindings.has(id)) {
      fail();
    }
    positiveInteger(binding.limit);
    operatorBindings.set(id, namespace);
  }
  if ([...reviewed.operatorRateLimits.keys()].some(
    (id) => !operatorBindings.has(id),
  )) {
    fail();
  }

  const accountBindings = new Map();
  const accountNamespaces = new Set();
  for (const rawBinding of rateLimits.accountNamespaceBindings) {
    const binding = object(rawBinding);
    exactKeys(binding, ["limiterId", "namespaceId"]);
    const id = limiterId(binding.limiterId);
    const namespace = namespaceId(binding.namespaceId);
    if (accountBindings.has(id) || accountNamespaces.has(namespace)) fail();
    accountBindings.set(id, namespace);
    accountNamespaces.add(namespace);
  }
  for (const [id, namespace] of operatorBindings) {
    if (accountBindings.get(id) !== namespace) fail();
  }
  if (reviewed.publicLimiterIds.some((id) => !accountBindings.has(id))) fail();
}

const acceptedResult = Object.freeze({
  snapshotAccepted: true,
  releaseReady: false,
  schemaVersion: 1,
  evidence: "caller_supplied_sanitized_snapshot_only",
  accessControl: "exact_reviewed_match",
  cloudflareRateLimiting: "approximate_only",
  d1ExactQuota: "not_validated_required_hard_boundary",
});

/**
 * Validates a complete, already-sanitized control-plane snapshot against a
 * separately reviewed non-secret policy. This function performs no I/O and
 * does not claim that the snapshot was fetched live or that Cloudflare's
 * approximate Rate Limiting binding is an exact quota.
 */
export function validateModerationOperatorControlPlanePreflight(
  reviewedValue,
  snapshotValue,
) {
  try {
    assertPlainData(reviewedValue);
    assertPlainData(snapshotValue);
    const reviewed = reviewedPolicy(reviewedValue);
    const snapshot = object(snapshotValue);
    exactKeys(snapshot, [
      "schemaVersion",
      "accountId",
      "application",
      "rateLimits",
    ]);
    if (snapshot.schemaVersion !== 1
        || exactString(snapshot.accountId, accountIdPattern, 32)
            !== reviewed.accountId) {
      fail();
    }
    applicationSnapshot(snapshot.application, reviewed);
    rateLimitSnapshot(snapshot.rateLimits, reviewed);
    return acceptedResult;
  } catch (error) {
    if (error instanceof ModerationOperatorControlPlanePreflightError) {
      throw error;
    }
    fail();
  }
}

export const MODERATION_OPERATOR_CONTROL_PLANE_PREFLIGHT_FAILURE_CODE =
  failureCode;
