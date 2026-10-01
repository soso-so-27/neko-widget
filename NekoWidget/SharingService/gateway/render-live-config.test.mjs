import assert from 'node:assert/strict';
import { test } from 'node:test';
import { renderLiveConfigs } from './render-live-config.mjs';

const snapshot = () => ({
  settings: { compatibility_date: '2026-08-17', compatibility_flags: [], logpush: false, tail_consumers: [],
    bindings: [
      { type: 'plain_text', name: 'ENVIRONMENT', text: 'staging' },
      { type: 'plain_text', name: 'APNS_RUNTIME_ENABLED', text: 'YES' },
      { type: 'plain_text', name: 'FAMILY_RECORD_RUNTIME_ENABLED', text: 'YES' },
      { type: 'secret_text', name: 'APNS_PROVIDER_CREDENTIAL_JSON' },
      { type: 'd1', name: 'DB', id: 'cb3b2386-3a6f-4253-b918-8aafed9ff735' },
      { type: 'r2_bucket', name: 'MEDIA', bucket_name: 'original-bucket' },
      { type: 'ratelimit', name: 'MEMBER_RATE_LIMITER', namespace_id: '710003', simple: { limit: 120, period: 60 } },
    ], limits: { cpu_ms: 25000 } },
  metadata: { script: { id: 'neko-window-sharing-staging' } },
  deployments: { deployments: [{ versions: [{ version_id: 'baseline', percentage: 100 }] }] },
  routes: [], domains: [], subdomain: { enabled: true, previews_enabled: false },
  schedules: { schedules: [{ cron: '* * * * *' }, { cron: '*/5 * * * *' }] },
});

test('family resources remain identical; private billing is Sandbox-only and entirely OFF', () => {
  const original = snapshot();
  const { family, gateway } = renderLiveConfigs(original, '/workspace');
  assert.deepEqual(family.vars, { ENVIRONMENT: 'staging', APNS_RUNTIME_ENABLED: 'YES', FAMILY_RECORD_RUNTIME_ENABLED: 'YES' });
  assert.equal(family.d1_databases[0].database_id, original.settings.bindings[4].id);
  assert.equal(family.r2_buckets[0].bucket_name, 'original-bucket');
  assert.deepEqual(family.ratelimits[0].simple, { limit: 120, period: 60 });
  assert.deepEqual(family.triggers.crons, original.schedules.schedules.map(s => s.cron));
  assert.deepEqual(family.limits, { cpu_ms: 25000 });
  assert.equal(gateway.workers_dev, false); assert.equal(gateway.preview_urls, false);
  assert.equal(gateway.vars.BILLING_STORE_ENVIRONMENT, 'Sandbox');
  assert.equal(gateway.vars.BILLING_VERIFIER_TRANSPORT, 'private-binding');
  assert.equal(gateway.services[0].binding, 'BILLING_VERIFIER_SERVICE');
  assert.equal(gateway.ratelimits[0].name, 'BILLING_RATE_LIMITER');
  const gates = Object.entries(gateway.vars).filter(([key]) => key.endsWith('_RUNTIME_ENABLED'));
  assert.equal(gates.length, 8); assert.ok(gates.every(([,value]) => value === 'NO'));
  assert.equal(gateway.r2_buckets, undefined); // private billing never gains photo storage access
});

test('unknown bindings, different account resources or partial deployment require investigation', () => {
  for (const change of [s => s.settings.bindings.push({type:'queue',name:'new'}),
    s => s.settings.bindings[4].id = 'wrong-account-db', s => s.subdomain.previews_enabled = true,
    s => s.deployments.deployments[0].versions[0].percentage = 50, s => s.routes.push({pattern:'new-route'})]) {
    const state = snapshot(); change(state); assert.throws(() => renderLiveConfigs(state, '/workspace'));
  }
});
