import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

test('real workerd loads the frozen family modules and dispatches only billing to the private binding', { timeout: 30000 }, async () => {
  const provenance = JSON.parse(await readFile(new URL('./family-v5-frozen.json', import.meta.url), 'utf8'));
  const frozen = await readFile(new URL('./family-v5-frozen.mjs', import.meta.url));
  assert.equal(frozen.length, provenance.moduleBytes);
  assert.equal(createHash('sha256').update(frozen).digest('hex'), provenance.moduleSha256);
  const modules = ['family-entry.mjs', 'family-router.mjs', 'family-v5-frozen.mjs'].map(file => ({
    type: 'ESModule', path: fileURLToPath(new URL(file, import.meta.url)),
  }));
  const familyOptions = {
    compatibilityDate: '2026-08-17', d1Databases: { DB: 'frozen-family-fixture' },
    bindings: { ENVIRONMENT: 'staging', MOMENT_RUNTIME_ENABLED: 'YES', APNS_RUNTIME_ENABLED: 'YES', FAMILY_RECORD_RUNTIME_ENABLED: 'YES' },
  };
  const mf = new Miniflare(convertV4MiniflareOptions({ cf: false, workers: [
    { name: 'front', modules: true, compatibilityDate: '2026-08-17',
      script: `export default {fetch(r,e) {const u=new URL(r.url);const baseline=u.pathname.startsWith('/baseline/');u.pathname=u.pathname.slice(baseline?9:10);return (baseline?e.BASELINE:e.CANDIDATE).fetch(new Request(u,r));}}`,
      serviceBindings: { BASELINE: 'baseline', CANDIDATE: 'candidate' } },
    { name: 'baseline', modules: true, script: frozen.toString(), ...familyOptions },
    { name: 'candidate', modules, ...familyOptions, serviceBindings: { PRIVATE_BILLING_GATEWAY: 'private-gateway' } },
    { name: 'private-gateway', modules: true, compatibilityDate: '2026-08-17',
      script: `export default {async fetch(r){return new Response(await r.text(),{status:202,headers:{'x-private-only':'yes'}})}}` },
  ] }));
  try {
    const db = await mf.getD1Database('DB', 'candidate');
    await db.prepare('CREATE TABLE personal_staging_runtime_gate(singleton INTEGER PRIMARY KEY, generation INTEGER, media_enabled INTEGER, apns_enabled INTEGER, report_ingestion_enabled INTEGER)').run();
    await db.prepare('INSERT INTO personal_staging_runtime_gate VALUES(1,5,1,1,0)').run();
    for (const path of ['/health', '/v2/family-records', '/not-found', '/v1/billing-other']) {
      const baseline = await mf.dispatchFetch('http://local/baseline' + path);
      const candidate = await mf.dispatchFetch('http://local/candidate' + path);
      assert.equal(candidate.status, baseline.status, path);
      assert.equal(await candidate.text(), await baseline.text(), path);
      assert.deepEqual([...candidate.headers].filter(([key]) => key.startsWith('neko-')),
        [...baseline.headers].filter(([key]) => key.startsWith('neko-')), path);
      assert.equal(candidate.headers.get('x-private-only'), null);
    }
    const billing = await mf.dispatchFetch('http://local/candidate/v1/billing/transactions', { method: 'POST', body: 'exact signed bytes' });
    assert.equal(billing.status, 202); assert.equal(await billing.text(), 'exact signed bytes');
    assert.equal(billing.headers.get('x-private-only'), 'yes');
  } finally { await mf.dispose(); }
});
