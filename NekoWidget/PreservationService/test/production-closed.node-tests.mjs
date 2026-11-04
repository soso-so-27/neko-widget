import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { renderProductionKmsPolicy } from '../deploy/render-production-kms-policy.mjs';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

const files = ['wrangler.production-closed.jsonc', 'wrangler.kms.production-closed.jsonc',
  'wrangler.billing.production-closed.jsonc',
  'wrangler.owner-deletion.production-closed.jsonc', '../PreservationImageValidator/wrangler.production-closed.jsonc'];
const configs = await Promise.all(files.map(async file => JSON.parse(await readFile(new URL('../' + file, import.meta.url), 'utf8'))));

test('production closed deployment has isolated storage, no public routes or timers, and no open gates', () => {
  for (const config of configs) {
    assert.equal(config.vars.ENVIRONMENT, 'production');
    assert.equal(config.workers_dev, false); assert.equal(config.preview_urls, false);
    assert.deepEqual(config.triggers.crons, []); assert.ok(!config.routes?.length);
    for (const [key, value] of Object.entries(config.vars)) {
      if (/_ENABLED$|_MODE$|_REQUIRED$|_IN_PRODUCTION$/.test(key)) assert.equal(value, 'NO', key);
      assert.ok(!/staging|Sandbox/.test(value), key);
    }
    for (const binding of config.services ?? []) assert.match(binding.service, /-production$/);
    for (const db of config.d1_databases ?? []) assert.ok([
      'e1f34d4a-dcb4-472b-9cbc-37233a52c5b1', 'f0622d76-41d5-4af2-87c4-54f0ebc4015f',
    ].includes(db.database_id));
    for (const bucket of config.r2_buckets ?? []) assert.equal(bucket.bucket_name, 'neko-preservation-production-private');
  }
  assert.ok(configs[0].compatibility_flags.includes('enable_request_signal'));
  assert.equal(configs[4].containers[0].max_instances, 1);
  assert.match(configs[4].containers[0].image, /@sha256:[0-9a-f]{64}$/);
  assert.equal(configs[4].vars.JPEG_VALIDATOR_ENABLED, 'NO');
});

test('AWS writer, version eraser, and key wrapper have disjoint production permissions', async () => {
  const policies = await Promise.all(['recovery-writer', 'version-eraser', 'kms'].map(async name =>
    JSON.parse(await readFile(new URL(`../deploy/production-${name}-policy.json`, import.meta.url), 'utf8'))));
  const actions = policy => policy.Statement.flatMap(statement => [statement.Action].flat()).sort();
  assert.deepEqual(actions(policies[0]), ['s3:GetObject', 's3:GetObject', 's3:GetObjectVersion',
    's3:GetObjectVersion', 's3:ListBucketVersions', 's3:PutObject'].sort());
  assert.deepEqual(actions(policies[1]), ['s3:DeleteObjectVersion']);
  assert.deepEqual(actions(policies[2]), ['kms:Decrypt', 'kms:Encrypt']);
  for (const policy of policies.slice(0, 2)) for (const statement of policy.Statement) {
    assert.equal(statement.Effect, 'Allow');
    assert.match(statement.Resource, /^arn:aws:s3:::neko-preservation-production-recovery-164892691568(?:\/(?:recovery|purge)\/v1\/\*)?$/);
    if (statement.Action === 's3:ListBucketVersions') {
      assert.deepEqual(statement.Condition.StringLike['s3:prefix'], ['recovery/v1/*', 'purge/v1/*']);
    }
  }
  const kms = policies[2].Statement[0];
  assert.equal(kms.Resource, '${PRODUCTION_PRESERVATION_KMS_KEY_ARN}');
  const syntheticArn = 'arn:aws:kms:ap-northeast-1:123456789012:key/12345678-1234-4234-8234-123456789abc';
  const rendered = renderProductionKmsPolicy(policies[2], syntheticArn);
  assert.deepEqual(rendered, { ...policies[2], Statement: [{ ...kms, Resource: syntheticArn }] });
  assert.match(rendered.Statement[0].Resource, /^arn:aws:kms:ap-northeast-1:\d{12}:key\/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/);
  for (const invalid of ['*', [syntheticArn], syntheticArn + ',*', syntheticArn.replace('ap-northeast-1', 'us-east-1'), syntheticArn.replace('key/', 'alias/'), undefined]) {
    assert.throws(() => renderProductionKmsPolicy(policies[2], invalid));
  }
  assert.throws(() => renderProductionKmsPolicy({ ...policies[2], Statement: [...policies[2].Statement, kms] }, syntheticArn));
  assert.throws(() => renderProductionKmsPolicy({ ...policies[2], Statement: [{ ...kms, Condition: {} }] }, syntheticArn));
  assert.equal(kms.Condition.Null['kms:EncryptionContextKeys'], false);
  assert.equal(kms.Condition['ForAllValues:StringEquals']['kms:EncryptionContextKeys'], 'neko-preservation-context-sha256');
});

test('actual closed entrypoints reject before database, object storage, or provider access', async () => {
  // Deliberately supply no D1/R2/provider bindings: touching them cannot succeed.
  // The front is synthetic; every target is the actual deployed entry module.
  let outbound = 0;
  const targets = [...configs.slice(0, 4), { main: '../SharingService/src/production-entry.ts',
    compatibility_date: '2026-08-17', compatibility_flags: ['nodejs_compat'],
    vars: { ENVIRONMENT: 'production', INTAKE_ENABLED: 'NO', PRESERVATION_RETENTION_REFRESH_ENABLED: 'NO' } }];
  const workers = await Promise.all(targets.map(async (config, i) => {
    const bundle = await build({ entryPoints: [config.main], bundle: true, write: false,
      format: 'esm', platform: 'browser', external: ['cloudflare:workers', 'node:*'] });
    return { name: 'closed-' + i, modules: true, script: bundle.outputFiles[0].text,
      compatibilityDate: config.compatibility_date, compatibilityFlags: config.compatibility_flags,
      outboundService: () => { outbound++; return new Response(null, { status: 599 }); },
      bindings: { ...config.vars, KEY_WRAPPER_CALLER_SECRET: 'x'.repeat(43) } };
  }));
  const bindings = {
    ARCHIVE: 'closed-0', INVENTORY: { name: 'closed-0', entrypoint: 'OwnerDeletionInventory' },
    KMS: { name: 'closed-1', entrypoint: 'PreservationKeyWrapper' },
    BILLING: { name: 'closed-2', entrypoint: 'BillingAuthority' },
    RETENTION: { name: 'closed-4', entrypoint: 'RetentionBillingObserver' }, DELETION: 'closed-3',
    KMS_PUBLIC: 'closed-1', BILLING_PUBLIC: 'closed-2', SHARING_PUBLIC: 'closed-4',
  };
  const mf = new Miniflare(convertV4MiniflareOptions({ workers: [{ name: 'front', modules: true,
    compatibilityDate: '2026-08-17', serviceBindings: bindings,
    script: `export default { fetch(request, env) {
      const url = new URL(request.url); const name = url.searchParams.get('binding');
      url.search = ''; return env[name].fetch(new Request('https://preservation-internal' + url.pathname, request));
    } }`,
  }, ...workers] }));
  try {
    await mf.ready;
    for (const [binding, path, status, body] of [
      ['ARCHIVE', '/v1/auth/challenges', 503, {}],
      ['INVENTORY', '/recovery/versions', 503, {}],
      ['KMS', '/keys/wrap', 503, { version: 1, key: Buffer.alloc(32).toString('base64'), contextSHA256: 'a'.repeat(64) }],
      ['BILLING', '/membership/verified-retention-status', 503, {}],
      ['RETENTION', '/internal/retention/refresh', 503, {}],
      ['DELETION', '/', 404, {}], ['KMS_PUBLIC', '/', 404, {}],
      ['BILLING_PUBLIC', '/', 404, {}], ['SHARING_PUBLIC', '/v3/family-notebooks', 503, {}],
    ]) {
      const result = await mf.dispatchFetch(`https://synthetic${path}?binding=${binding}`, {
        method: 'POST', body: JSON.stringify(body), headers: {
          'content-type': 'application/json', 'x-neko-preservation-key-token': 'x'.repeat(43),
        },
      });
      assert.equal(result.status, status, binding + ': ' + await result.text());
    }
    assert.equal(outbound, 0, 'closed services must not contact any provider');
  } finally { await mf.dispose(); }
});
