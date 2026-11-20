import { test } from 'node:test';
import assert from 'node:assert/strict';
import { productionOpenConfigIssues } from '../scripts/production-open-config.mjs';

function openProduction() {
  const switches = [
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
  const vars = {
    ...Object.fromEntries(switches.map(name => [name, 'YES'])),
    ENVIRONMENT: 'production', BILLING_STORE_ENVIRONMENT: 'Production',
    LEGACY_SHARING_RUNTIME_ENABLED: 'NO',
    BILLING_VERIFIER_TRANSPORT: 'https-access', BILLING_VERIFIER_ORIGIN: 'https://verifier.example.invalid',
  };
  return {
    crons: [
      '* * * * *', '*/5 * * * *',
      '2,7,12,17,22,27,32,37,42,47,52,57 * * * *',
      '3,8,13,18,23,28,33,38,43,48,53,58 * * * *',
    ],
    bindings: [
      ...Object.entries(vars).map(([name, text]) => ({name, type: 'plain_text', text})),
      {name: 'DB', type: 'd1'}, {name: 'MEDIA', type: 'r2_bucket'}, {name: 'MODERATION_MEDIA', type: 'r2_bucket'},
      {name: 'BILLING_RATE_LIMITER', type: 'ratelimit', namespace_id: '1', simple: {limit: 10, period: 60}},
      {name: 'BILLING_APPLE_NOTIFICATION_RATE_LIMITER', type: 'ratelimit', namespace_id: '2', simple: {limit: 10, period: 60}},
      {name: 'BILLING_VERIFIER_SHARED_SECRET', type: 'secret_text'},
      {name: 'BILLING_VERIFIER_ACCESS_CLIENT_ID', type: 'secret_text'},
      {name: 'BILLING_VERIFIER_ACCESS_CLIENT_SECRET', type: 'secret_text'},
    ],
    gates: {
      rollout: {media_enabled: 1, apns_enabled: 1, report_ingestion_enabled: 1},
      quota: {enabled: 1},
      billing: {
        account_bootstrap_enabled: 1, account_recovery_enabled: 1, transaction_ingestion_enabled: 1,
        apple_notification_ingestion_enabled: 1, subscription_reconciliation_enabled: 1,
        effective_entitlement_enabled: 1, window_sponsorship_enabled: 1,
      },
    },
  };
}

test('open production accepts separate cron lanes and the HTTPS Access verifier', () => {
  assert.deepEqual(productionOpenConfigIssues(openProduction()), []);
});

test('observed production gaps remain visible even when reporting and both billing limiters are configured', () => {
  const config = openProduction();
  config.crons = [config.crons[0], config.crons[3]];
  config.bindings.find(binding => binding.name === 'GROUP_IDENTITY_ERASURE_ENABLED').text = 'NO';
  assert.deepEqual(productionOpenConfigIssues(config), [
    'setting:GROUP_IDENTITY_ERASURE_ENABLED',
    'cron:*/5 * * * *',
    'cron:2,7,12,17,22,27,32,37,42,47,52,57 * * * *',
  ]);
});

test('invalid gates, verifier and rate limit bindings are signaled without private values', () => {
  const config = openProduction();
  config.gates.quota.enabled = 0;
  config.gates.billing.subscription_reconciliation_enabled = 0;
  config.bindings.find(binding => binding.name === 'BILLING_RATE_LIMITER').simple.limit = 0;
  config.bindings.find(binding => binding.name === 'BILLING_VERIFIER_ORIGIN').text = 'https://sensitive@example.invalid/path';
  config.bindings.find(binding => binding.name === 'BILLING_VERIFIER_SHARED_SECRET').type = 'plain_text';
  assert.deepEqual(productionOpenConfigIssues(config), [
    'binding:BILLING_RATE_LIMITER', 'setting:BILLING_VERIFIER_ORIGIN', 'binding:BILLING_VERIFIER_SHARED_SECRET',
    'gate:quota.enabled', 'gate:billing.subscription_reconciliation_enabled',
  ]);
});
