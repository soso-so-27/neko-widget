// Readiness contract for an open production Worker. Accept settings and cron
// readback plus the singleton D1 gate rows. Do not deploy a configuration.
const cronTriggers = [
  '* * * * *',
  '*/5 * * * *',
  '2,7,12,17,22,27,32,37,42,47,52,57 * * * *',
  '3,8,13,18,23,28,33,38,43,48,53,58 * * * *',
];
const enabledSettings = [
  'INTAKE_ENABLED', 'GROUP_RUNTIME_ENABLED', 'GROUP_WINDOW_MANAGEMENT_RUNTIME_ENABLED',
  'GROUP_RECOVERY_CATALOG_ENABLED', 'GROUP_APNS_RUNTIME_ENABLED',
  'GROUP_MODERATION_RUNTIME_ENABLED', 'GROUP_REPORT_RUNTIME_ENABLED', 'REPORT_INGESTION_RUNTIME_ENABLED',
  'GROUP_IDENTITY_ERASURE_ENABLED',
  'FAMILY_NOTEBOOK_API_RUNTIME_ENABLED', 'FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED',
  'FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED', 'FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED',
  'WINDOW_DELIVERY_MEMBERSHIP_ENFORCED',
  'BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED', 'BILLING_ACCOUNT_RECOVERY_RUNTIME_ENABLED',
  'BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED', 'BILLING_APPLE_NOTIFICATION_RUNTIME_ENABLED',
  'BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED', 'BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED',
  'BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED', 'BILLING_TRANSACTION_RETENTION_REQUIRED',
];
const billingLimiters = ['BILLING_RATE_LIMITER', 'BILLING_APPLE_NOTIFICATION_RATE_LIMITER'];
const verifierSecrets = [
  'BILLING_VERIFIER_SHARED_SECRET', 'BILLING_VERIFIER_ACCESS_CLIENT_ID', 'BILLING_VERIFIER_ACCESS_CLIENT_SECRET',
];
const databaseGates = {
  rollout: ['media_enabled', 'apns_enabled', 'report_ingestion_enabled'],
  quota: ['enabled'],
  billing: [
    'account_bootstrap_enabled', 'account_recovery_enabled', 'transaction_ingestion_enabled',
    'apple_notification_ingestion_enabled', 'subscription_reconciliation_enabled',
    'effective_entitlement_enabled', 'window_sponsorship_enabled',
  ],
};

function isHTTPSOrigin(value) {
  if (typeof value !== 'string' || value !== value.trim()) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password
      && url.pathname === '/' && !url.search && !url.hash;
  } catch {
    return false;
  }
}

// Issues contain only fixed policy labels. Never return origins, resource
// IDs, secret values or provider responses.
export function productionOpenConfigIssues({ bindings = [], crons = [], gates = {} }) {
  const issues = [];
  const byName = new Map(bindings.map(binding => [binding.name, binding]));
  const text = name => {
    const binding = byName.get(name);
    return binding?.type === 'plain_text' ? binding.text : undefined;
  };
  if (byName.size !== bindings.length) issues.push('bindings:duplicate_names');
  if (text('ENVIRONMENT') !== 'production') issues.push('setting:ENVIRONMENT');
  if (text('BILLING_STORE_ENVIRONMENT') !== 'Production') issues.push('setting:BILLING_STORE_ENVIRONMENT');
  for (const name of enabledSettings) if (text(name) !== 'YES') issues.push('setting:' + name);
  if (text('LEGACY_SHARING_RUNTIME_ENABLED') !== 'NO') issues.push('setting:LEGACY_SHARING_RUNTIME_ENABLED');

  for (const cron of cronTriggers) if (!crons.includes(cron)) issues.push('cron:' + cron);
  for (const [name, type] of [['DB', 'd1'], ['MEDIA', 'r2_bucket'], ['MODERATION_MEDIA', 'r2_bucket']]) {
    if (byName.get(name)?.type !== type) issues.push('binding:' + name);
  }
  for (const name of billingLimiters) {
    const binding = byName.get(name);
    if (binding?.type !== 'ratelimit' || binding.simple?.period !== 60 || binding.simple?.limit !== 10) {
      issues.push('binding:' + name);
    }
  }
  if (byName.get(billingLimiters[0])?.namespace_id === byName.get(billingLimiters[1])?.namespace_id) {
    issues.push('binding:billing_limiter_namespaces');
  }

  // Production verifies over HTTPS through Access. The private billing
  // gateway in the staging config serves a different purpose.
  if (text('BILLING_VERIFIER_TRANSPORT') !== 'https-access') issues.push('setting:BILLING_VERIFIER_TRANSPORT');
  if (!isHTTPSOrigin(text('BILLING_VERIFIER_ORIGIN'))) issues.push('setting:BILLING_VERIFIER_ORIGIN');
  for (const name of verifierSecrets) if (byName.get(name)?.type !== 'secret_text') issues.push('binding:' + name);
  if (byName.has('BILLING_VERIFIER_SERVICE')) issues.push('binding:BILLING_VERIFIER_SERVICE');

  for (const [group, required] of Object.entries(databaseGates)) {
    for (const name of required) if (gates[group]?.[name] !== 1) issues.push('gate:' + group + '.' + name);
  }
  return issues;
}
