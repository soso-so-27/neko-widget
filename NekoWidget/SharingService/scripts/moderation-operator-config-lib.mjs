const reviewedKeys = [
  "$schema",
  "name",
  "main",
  "compatibility_date",
  "workers_dev",
  "preview_urls",
  "observability",
  "vars",
];

function requireCondition(value, message) {
  if (!value) throw new Error(message);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireExactKeys(actual, expectedKeys, label) {
  requireCondition(isRecord(actual), `${label} must be an object.`);
  const actualKeys = Object.keys(actual).sort();
  const expected = [...expectedKeys].sort();
  requireCondition(
    actualKeys.length === expected.length
      && actualKeys.every((key, index) => key === expected[index]),
    `${label} contains an unreviewed field.`,
  );
}

function requireExactObject(actual, expected, label) {
  requireCondition(isRecord(actual), `${label} must be an object.`);
  requireCondition(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} does not match the reviewed disabled policy.`,
  );
}

export function validateDisabledModerationOperatorConfig(config) {
  requireExactKeys(config, reviewedKeys, "moderation operator configuration");
  requireCondition(
    config.$schema === "node_modules/wrangler/config-schema.json",
    "The Wrangler schema reference changed.",
  );
  requireCondition(
    config.name === "neko-window-moderation-operator-disabled",
    "The disabled moderation operator Worker name changed.",
  );
  requireCondition(
    config.main === "src/moderation-operator-worker.ts",
    "The disabled moderation operator entry point changed.",
  );
  requireCondition(
    config.compatibility_date === "2026-08-17",
    "The compatibility date must match the reviewed release.",
  );
  requireCondition(
    config.workers_dev === false,
    "The moderation operator Worker must not have a workers.dev endpoint.",
  );
  requireCondition(
    config.preview_urls === false,
    "The moderation operator Worker must not have preview URLs.",
  );
  requireExactObject(
    config.observability,
    { enabled: false, logs: { enabled: false } },
    "observability",
  );
  requireExactObject(
    config.vars,
    { OPERATOR_RUNTIME_ENABLED: "NO" },
    "vars",
  );
  return config;
}
