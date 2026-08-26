const expectedWorkerName = "neko-window-sharing-staging";
const expectedDatabaseName = "neko-window-sharing-staging";
const expectedMediaBucket = "neko-window-sharing-staging-media-private";
const expectedModerationBucket = "neko-window-sharing-staging-moderation-private";

const replacements = new Map([
  ["__NEKO_STAGING_D1_DATABASE_ID__", "NEKO_STAGING_D1_DATABASE_ID"],
  [
    "__NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID__",
    "NEKO_STAGING_CREATE_RATE_LIMIT_NAMESPACE_ID",
  ],
  [
    "__NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID__",
    "NEKO_STAGING_INVITE_RATE_LIMIT_NAMESPACE_ID",
  ],
  [
    "__NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID__",
    "NEKO_STAGING_MEMBER_RATE_LIMIT_NAMESPACE_ID",
  ],
]);

function requireCondition(value, message) {
  if (!value) throw new Error(message);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requirePositiveIntegerString(value, label) {
  requireCondition(
    typeof value === "string" && /^[1-9][0-9]*$/u.test(value),
    `${label} must be a positive integer encoded as a string.`,
  );
}

function requireUUID(value, label) {
  requireCondition(
    typeof value === "string"
      && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value),
    `${label} must be a lowercase UUID.`,
  );
}

function requireExactObject(actual, expected, label) {
  requireCondition(isRecord(actual), `${label} must be an object.`);
  requireCondition(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} does not match the reviewed staging policy.`,
  );
}

function reviewedMomentRuntime(options) {
  const expectedMomentRuntime = options?.expectedMomentRuntime ?? "NO";
  requireCondition(
    expectedMomentRuntime === "NO" || expectedMomentRuntime === "YES",
    "The expected moment runtime must be exactly NO or YES.",
  );
  return expectedMomentRuntime;
}

function requireExactKeys(actual, expectedKeys, label) {
  requireCondition(isRecord(actual), `${label} must be an object.`);
  const actualKeys = Object.keys(actual).sort();
  const reviewedKeys = [...expectedKeys].sort();
  requireCondition(
    actualKeys.length === reviewedKeys.length
      && actualKeys.every((key, index) => key === reviewedKeys[index]),
    `${label} contains an unreviewed field.`,
  );
}

function reviewedAPNSRuntime(options) {
  const expectedAPNSRuntime = options?.expectedAPNSRuntime ?? "NO";
  requireCondition(
    expectedAPNSRuntime === "NO" || expectedAPNSRuntime === "YES",
    "The expected APNs runtime must be exactly NO or YES.",
  );
  return expectedAPNSRuntime;
}

function reviewedReportIngestionRuntime(options) {
  const expectedReportIngestionRuntime =
    options?.expectedReportIngestionRuntime ?? "NO";
  requireCondition(
    expectedReportIngestionRuntime === "NO"
      || expectedReportIngestionRuntime === "YES",
    "The expected report-ingestion runtime must be exactly NO or YES.",
  );
  return expectedReportIngestionRuntime;
}

export function validateStagingConfig(config, options = {}) {
  const expectedMomentRuntime = reviewedMomentRuntime(options);
  const expectedAPNSRuntime = reviewedAPNSRuntime(options);
  const expectedReportIngestionRuntime = reviewedReportIngestionRuntime(options);
  requireCondition(
    expectedAPNSRuntime !== "YES" || expectedMomentRuntime === "YES",
    "The APNs runtime requires the reviewed private media runtimes to be ON.",
  );
  requireCondition(isRecord(config), "The staging Wrangler configuration must be an object.");
  requireCondition(
    config.$schema === "node_modules/wrangler/config-schema.json",
    "The staging Wrangler schema reference changed.",
  );
  requireCondition(config.name === expectedWorkerName, "The staging Worker name is not isolated.");
  requireCondition(config.main === "src/index.ts", "The staging Worker entry point changed.");
  requireCondition(
    config.compatibility_date === "2026-08-17",
    "The staging compatibility date must match the reviewed Worker release.",
  );
  requireCondition(config.workers_dev === true, "Staging must use its workers.dev endpoint.");
  requireCondition(config.preview_urls === false, "Untracked Worker preview URLs must remain disabled.");
  requireCondition(config.route === undefined && config.routes === undefined, "Staging must not claim a custom route.");
  requireCondition(config.account_id === undefined, "Cloudflare account IDs must not be written to this file.");
  requireExactObject(
    config.observability,
    { enabled: false, logs: { enabled: false } },
    "observability",
  );
  requireCondition(
    config.limits === undefined,
    "Staging must use the account plan defaults; custom limits would require Workers Paid.",
  );
  requireExactKeys(
    config,
    [
      "$schema", "name", "main", "compatibility_date", "workers_dev",
      "preview_urls", "observability", "vars", "triggers", "d1_databases",
      "r2_buckets", "ratelimits",
    ],
    "The staging Wrangler configuration",
  );
  requireExactObject(
    config.vars,
    {
      ENVIRONMENT: "staging",
      MOMENT_RUNTIME_ENABLED: expectedMomentRuntime,
      REPORT_INGESTION_RUNTIME_ENABLED: expectedReportIngestionRuntime,
      REACTION_RUNTIME_ENABLED: expectedMomentRuntime,
      WINDOW_NAME_RUNTIME_ENABLED: expectedMomentRuntime,
      APNS_RUNTIME_ENABLED: expectedAPNSRuntime,
      LEGACY_SHARING_RUNTIME_ENABLED: "NO",
      INVITATION_TTL_SECONDS: "86400",
      CHALLENGE_TTL_SECONDS: "300",
      PENDING_TTL_SECONDS: "86400",
      IDEMPOTENCY_TTL_SECONDS: "172800",
      SPACE_INACTIVITY_TTL_SECONDS: "2592000",
    },
    "vars",
  );
  requireExactObject(
    config.triggers,
    {
      crons: [
        "* * * * *",
        "*/5 * * * *",
        "2,7,12,17,22,27,32,37,42,47,52,57 * * * *",
      ],
    },
    "triggers",
  );

  requireCondition(
    Array.isArray(config.d1_databases) && config.d1_databases.length === 1,
    "Staging must bind exactly one D1 database.",
  );
  const database = config.d1_databases[0];
  requireExactKeys(
    database,
    ["binding", "database_name", "database_id", "migrations_dir"],
    "The staging D1 binding",
  );
  requireCondition(database.binding === "DB", "The staging D1 binding must be DB.");
  requireCondition(database.database_name === expectedDatabaseName, "The staging D1 name is not isolated.");
  requireCondition(database.migrations_dir === "migrations", "The staging D1 migration directory changed.");
  requireUUID(database.database_id, "NEKO_STAGING_D1_DATABASE_ID");

  requireCondition(
    Array.isArray(config.r2_buckets) && config.r2_buckets.length === 2,
    "Staging must bind exactly two R2 buckets.",
  );
  for (const bucket of config.r2_buckets) {
    requireExactKeys(bucket, ["binding", "bucket_name"], "A staging R2 binding");
  }
  const bucketByBinding = new Map(config.r2_buckets.map((bucket) => [bucket?.binding, bucket]));
  requireCondition(bucketByBinding.size === 2, "Staging R2 bindings must be unique.");
  requireCondition(
    bucketByBinding.get("MEDIA")?.bucket_name === expectedMediaBucket,
    "The normal staging media bucket is not isolated.",
  );
  requireCondition(
    bucketByBinding.get("MODERATION_MEDIA")?.bucket_name === expectedModerationBucket,
    "The moderation staging bucket is not isolated.",
  );
  requireCondition(expectedMediaBucket !== expectedModerationBucket, "Normal and moderation buckets must differ.");

  const expectedRateLimits = new Map([
    ["CREATE_RATE_LIMITER", { limit: 5, period: 60 }],
    ["INVITE_RATE_LIMITER", { limit: 10, period: 60 }],
    ["MEMBER_RATE_LIMITER", { limit: 120, period: 60 }],
  ]);
  requireCondition(
    Array.isArray(config.ratelimits) && config.ratelimits.length === expectedRateLimits.size,
    "Staging must bind exactly three rate limiters.",
  );
  const namespaceIDs = new Set();
  for (const rateLimit of config.ratelimits) {
    requireExactKeys(
      rateLimit,
      ["name", "namespace_id", "simple"],
      "A staging rate limiter",
    );
    const expected = expectedRateLimits.get(rateLimit.name);
    requireCondition(expected !== undefined, "An unexpected staging rate limiter was configured.");
    requireExactObject(rateLimit.simple, expected, `${rateLimit.name}.simple`);
    requirePositiveIntegerString(rateLimit.namespace_id, `${rateLimit.name}.namespace_id`);
    namespaceIDs.add(rateLimit.namespace_id);
  }
  requireCondition(
    namespaceIDs.size === expectedRateLimits.size,
    "Each staging rate limiter must use a different account-unique namespace ID.",
  );

  const serialized = JSON.stringify(config);
  requireCondition(!serialized.includes("__NEKO_STAGING_"), "The staging configuration still has placeholders.");
  return config;
}

export function renderStagingConfig(template, environment, options = {}) {
  const expectedMomentRuntime = reviewedMomentRuntime(options);
  const expectedAPNSRuntime = reviewedAPNSRuntime(options);
  const expectedReportIngestionRuntime = reviewedReportIngestionRuntime(options);
  requireCondition(
    expectedAPNSRuntime !== "YES" || expectedMomentRuntime === "YES",
    "The APNs runtime requires the reviewed private media runtimes to be ON.",
  );
  let rendered = template;
  for (const [placeholder, variableName] of replacements) {
    const value = environment[variableName];
    requireCondition(
      typeof value === "string" && value.length > 0,
      `${variableName} is required in the current process environment.`,
    );
    const occurrences = rendered.split(placeholder).length - 1;
    requireCondition(occurrences === 1, `${placeholder} must occur exactly once in the template.`);
    rendered = rendered.replace(placeholder, value);
  }
  const config = JSON.parse(rendered);
  requireCondition(
    config?.vars?.MOMENT_RUNTIME_ENABLED === "NO",
    "The tracked staging template must keep the moment runtime locked OFF.",
  );
  requireCondition(
    config?.vars?.REACTION_RUNTIME_ENABLED === "NO",
    "The tracked staging template must keep the reaction runtime locked OFF.",
  );
  requireCondition(
    config?.vars?.WINDOW_NAME_RUNTIME_ENABLED === "NO",
    "The tracked staging template must keep the window-name runtime locked OFF.",
  );
  requireCondition(
    config?.vars?.APNS_RUNTIME_ENABLED === "NO",
    "The tracked staging template must keep the APNs runtime locked OFF.",
  );
  requireCondition(
    config?.vars?.REPORT_INGESTION_RUNTIME_ENABLED === "NO",
    "The tracked staging template must keep report ingestion locked OFF.",
  );
  config.vars.MOMENT_RUNTIME_ENABLED = expectedMomentRuntime;
  config.vars.REACTION_RUNTIME_ENABLED = expectedMomentRuntime;
  config.vars.WINDOW_NAME_RUNTIME_ENABLED = expectedMomentRuntime;
  config.vars.APNS_RUNTIME_ENABLED = expectedAPNSRuntime;
  config.vars.REPORT_INGESTION_RUNTIME_ENABLED = expectedReportIngestionRuntime;
  validateStagingConfig(config, {
    expectedMomentRuntime,
    expectedAPNSRuntime,
    expectedReportIngestionRuntime,
  });
  return `${JSON.stringify(config, null, 2)}\n`;
}
