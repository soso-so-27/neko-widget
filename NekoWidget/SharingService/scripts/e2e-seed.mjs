// Generate a disposable, loopback-only Worker configuration and seed local D1.
import { spawnSync } from 'node:child_process';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { realpathSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = process.argv[2];
if (process.argv.length !== 3 || !directory || !path.isAbsolute(directory)) {
  throw new Error('Usage: node scripts/e2e-seed.mjs <absolute empty scratch directory>');
}
const scratch = realpathSync(directory);
if (!statSync(scratch).isDirectory()) throw new Error('Expected a scratch directory');
const service = fileURLToPath(new URL('../', import.meta.url));
const config = path.join(scratch, 'wrangler.json');
const persist = path.join(scratch, 'state');
const database = 'neko-sharing-two-device-e2e';
const token = randomBytes(32).toString('hex');
const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const moderation = generateKeyPairSync('x25519');
const moderationKeys = {
  publicKey: moderation.publicKey.export({ format: 'jwk' }).x,
  privateKey: moderation.privateKey.export({ format: 'jwk' }).d,
};
const vars = {
  ENVIRONMENT: 'local',
  E2E_TOKEN: token,
  GROUP_RUNTIME_ENABLED: 'YES',
  MOMENT_RUNTIME_ENABLED: 'YES',
  APNS_RUNTIME_ENABLED: 'YES',
  FAMILY_NOTEBOOK_API_RUNTIME_ENABLED: 'YES',
  FAMILY_NOTEBOOK_PAYER_RUNTIME_ENABLED: 'YES',
  FAMILY_NOTEBOOK_APNS_RUNTIME_ENABLED: 'YES',
  FAMILY_REPRESENTATIVE_PHOTO_RUNTIME_ENABLED: 'YES',
  GROUP_RECOVERY_CATALOG_ENABLED: 'YES',
  GROUP_REPORT_RUNTIME_ENABLED: 'YES',
  GROUP_MODERATION_RUNTIME_ENABLED: 'YES',
  REPORT_INGESTION_RUNTIME_ENABLED: 'YES',
  GROUP_REPORT_EMAIL_ENABLED: 'NO',
  BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED: 'YES',
  BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED: 'YES',
  BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: 'YES',
  BILLING_STORE_ENVIRONMENT: 'Sandbox',
  APNS_PROVIDER_CREDENTIAL_JSON: JSON.stringify({
    keyId: 'A1B2C3D4E5', teamId: 'Z9Y8X7W6V5', bundleId: 'jp.nekowidget.app',
    environment: 'production', privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }),
  }),
  APNS_TOKEN_KEYRING_JSON: JSON.stringify({ current: 'test', keys: { test: randomBytes(32).toString('base64url') } }),
};
writeFileSync(config, JSON.stringify({
  name: database,
  main: path.join(service, 'scripts/e2e-worker.ts'),
  compatibility_date: '2026-08-17',
  workers_dev: false,
  preview_urls: false,
  vars,
  d1_databases: [{
    binding: 'DB', database_name: database, database_id: '00000000-0000-0000-0000-000000000000',
    migrations_dir: path.join(service, 'migrations'),
  }],
  r2_buckets: [
    { binding: 'MEDIA', bucket_name: 'neko-sharing-two-device-e2e-media' },
    { binding: 'MODERATION_MEDIA', bucket_name: 'neko-sharing-two-device-e2e-moderation' },
  ],
}, null, 2), { flag: 'wx', mode: 0o600 });
writeFileSync(path.join(scratch, 'fixtures.json'), JSON.stringify({ token, moderationKeys }), {
  flag: 'wx', mode: 0o600,
});
function d1(args) {
  const result = spawnSync(process.execPath, [
    path.join(service, 'node_modules/wrangler/bin/wrangler.js'), 'd1', ...args,
    '--config', config, '--local', '--persist-to', persist,
  ], { cwd: scratch, stdio: 'inherit', env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error('Local D1 preparation failed');
}
d1(['migrations', 'apply', database]);
d1(['execute', database, '--command', [
  'UPDATE family_notebook_runtime_gate SET enabled=1,generation=generation+1 WHERE singleton=1',
  'UPDATE personal_staging_runtime_gate SET media_enabled=1,apns_enabled=1,report_ingestion_enabled=1,generation=generation+1,updated_at=unixepoch() WHERE singleton=1',
  'UPDATE billing_runtime_gate SET account_bootstrap_enabled=1,effective_entitlement_enabled=1,subscription_reconciliation_enabled=1,generation=generation+1,updated_at=unixepoch() WHERE singleton=1',
].join('; ')]);
