import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

export function renderLiveConfigs(snapshot, projectDirectory) {
  const settings = snapshot.settings;
  if (snapshot.metadata?.script?.id !== 'neko-window-sharing-staging'
    || settings?.compatibility_date !== '2026-08-17'
    || snapshot.routes?.length || snapshot.domains?.length
    || snapshot.subdomain?.enabled !== true || snapshot.subdomain?.previews_enabled !== false
    || snapshot.deployments?.deployments?.[0]?.versions?.length !== 1
    || snapshot.deployments.deployments[0].versions[0].percentage !== 100) {
    throw new Error('Unexpected family deployment; inspect before generating a candidate');
  }
  const bindings = settings.bindings;
  if (!Array.isArray(bindings) || bindings.some(b => !['secret_text', 'plain_text', 'd1', 'r2_bucket', 'ratelimit'].includes(b.type))) {
    throw new Error('Unmapped binding type; never discard an existing binding');
  }
  const db = bindings.find(b => b.name === 'DB' && b.type === 'd1');
  if (db?.id !== 'cb3b2386-3a6f-4253-b918-8aafed9ff735') throw new Error('Unexpected staging database');
  const vars = Object.fromEntries(bindings.filter(b => b.type === 'plain_text').map(b => [b.name, b.text]));
  if (vars.ENVIRONMENT !== 'staging' || vars.APNS_RUNTIME_ENABLED !== 'YES') throw new Error('Family environment changed');
  const family = {
    name: 'neko-window-sharing-staging', account_id: '829a34ef925a39d81b0e9e08800d7c7f',
    main: resolve(projectDirectory, 'gateway/family-entry.mjs'),
    compatibility_date: settings.compatibility_date, compatibility_flags: settings.compatibility_flags,
    workers_dev: snapshot.subdomain.enabled, preview_urls: snapshot.subdomain.previews_enabled,
    vars, d1_databases: [{ binding: 'DB', database_id: db.id, database_name: 'neko-window-sharing-staging' }],
    r2_buckets: bindings.filter(b => b.type === 'r2_bucket').map(b => ({ binding: b.name, bucket_name: b.bucket_name })),
    ratelimits: bindings.filter(b => b.type === 'ratelimit').map(b => ({ name: b.name, namespace_id: b.namespace_id, simple: b.simple })),
    services: [{ binding: 'PRIVATE_BILLING_GATEWAY', service: 'neko-billing-gateway-staging-private', entrypoint: 'BillingGateway' }],
    triggers: { crons: snapshot.schedules.schedules.map(s => s.cron) },
    logpush: settings.logpush, tail_consumers: settings.tail_consumers, observability: settings.observability ?? { enabled: false },
  };
  if (settings.limits) family.limits = settings.limits;
  if (settings.placement && Object.keys(settings.placement).length) family.placement = settings.placement;
  const gateway = {
    name: 'neko-billing-gateway-staging-private', account_id: family.account_id,
    main: resolve(projectDirectory, 'src/billing-gateway.ts'), compatibility_date: settings.compatibility_date,
    compatibility_flags: ['nodejs_compat'], workers_dev: false, preview_urls: false,
    observability: { enabled: false }, limits: { cpu_ms: 30000, subrequests: 100 },
    vars: {
      ENVIRONMENT: 'staging', BILLING_STORE_ENVIRONMENT: 'Sandbox',
      BILLING_BUNDLE_ID: 'jp.nekowidget.app', BILLING_MONTHLY_PRODUCT_ID: 'jp.nekowidget.plus.monthly',
      BILLING_SUBSCRIPTION_GROUP_ID: '22424520',
      BILLING_VERIFIER_TRANSPORT: 'private-binding', BILLING_VERIFIER_ORIGIN: 'https://billing-verifier.private.invalid',
      ...Object.fromEntries(['ACCOUNT_BOOTSTRAP', 'TRANSACTION_INGESTION', 'APPLE_NOTIFICATION',
        'APPLE_NOTIFICATION_HISTORY_RECOVERY', 'SUBSCRIPTION_RECONCILIATION', 'EFFECTIVE_ENTITLEMENT',
        'ACCOUNT_RECOVERY', 'WINDOW_SPONSORSHIP'].map(flag => [`BILLING_${flag}_RUNTIME_ENABLED`, 'NO'])),
    },
    d1_databases: family.d1_databases,
    services: [{ binding: 'BILLING_VERIFIER_SERVICE', service: 'neko-billing-verifier-disabled', entrypoint: 'BillingVerificationService' }],
    ratelimits: [
      { name: 'BILLING_RATE_LIMITER', namespace_id: '710004', simple: { limit: 10, period: 60 } },
      { name: 'BILLING_APPLE_NOTIFICATION_RATE_LIMITER', namespace_id: '710005', simple: { limit: 120, period: 60 } },
    ],
    triggers: { crons: ['*/5 * * * *'] },
  };
  return { family, gateway };
}

if (process.argv[1] && import.meta.url === new URL('file:///' + resolve(process.argv[1]).replaceAll('\\', '/')).href) {
  const [snapshotFile, projectDirectory, outputDirectory] = process.argv.slice(2);
  const configs = renderLiveConfigs(JSON.parse(await readFile(snapshotFile, 'utf8')), resolve(projectDirectory));
  for (const [name, config] of Object.entries(configs)) {
    await writeFile(resolve(outputDirectory, `${name}-gateway-off.json`), JSON.stringify(config, null, 2) + '\n');
  }
  console.log('Generated OFF-only private gateway and family wrapper candidates; no deployment');
}
