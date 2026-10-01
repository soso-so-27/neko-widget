// Local workerd/SQLite boundary tests; debug commands never enter the deployed Worker.
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { containerEnvironment } from './runtime-config.mjs';
const credentialNames = ['APP_STORE_SERVER_API_PRIVATE_KEY', 'APP_STORE_SERVER_API_KEY_ID', 'APP_STORE_SERVER_API_ISSUER_ID'];
const configured = Object.fromEntries(credentialNames.map(key => [key, 'test-only']));
for (const gate of ['NO', undefined, 'yes']) {
  const forwarded = containerEnvironment({ ...configured, BILLING_SUBSCRIPTION_STATUS_RUNTIME_ENABLED: gate });
  for (const key of credentialNames) assert.equal(key in forwarded, false);
}
for (const gate of ['BILLING_SUBSCRIPTION_STATUS_RUNTIME_ENABLED', 'BILLING_NOTIFICATION_HISTORY_RUNTIME_ENABLED']) {
  const forwarded = containerEnvironment({ ...configured, [gate]: 'YES' });
  for (const key of credentialNames) assert.equal(forwarded[key], 'test-only');
}
const require = createRequire(import.meta.url);
const { build } = require('esbuild');
const { Miniflare, convertV4MiniflareOptions } = createRequire(new URL('../../PreservationService/package.json', import.meta.url))('miniflare');
const directory = dirname(fileURLToPath(import.meta.url));
const { outputFiles } = await build({ bundle: true, write: false, format: 'esm', platform: 'browser',
  external: ['cloudflare:*'], stdin: { resolveDir: directory, contents: `
    import { DurableObject } from 'cloudflare:workers';
    import { BillingNonceLedger } from './nonce-ledger.mjs';
    import { initializeNonceLedger, claimDurableNonce, MAX_LIVE_NONCES } from './nonce-ledger-core.mjs';
    export { BillingNonceLedger };
    export class DisabledLedger extends BillingNonceLedger {
      constructor(ctx, env) { super(ctx, { ...env, BILLING_VERIFIER_CONTAINER_ENABLED: 'NO' }); }
    }
    export class CoreHarness extends DurableObject {
      constructor(ctx, env) { super(ctx, env); initializeNonceLedger(ctx.storage); }
      async fetch(request) {
        try {
          const { digest, now, fill } = await request.json();
          if (fill) this.ctx.storage.transactionSync(() => {
            for (let i=0; i<MAX_LIVE_NONCES; i++) this.ctx.storage.sql.exec('INSERT INTO claims(digest,expires_ms) VALUES(?,?)', 'test-only-' + i, now + 601000);
          });
          return Response.json({ outcome: claimDurableNonce(this.ctx.storage, digest, now) });
        } catch { return new Response(null, { status: 503 }); }
      }
    }
    export default { fetch(request, env) {
      const path = new URL(request.url).pathname;
      if (path.startsWith('/core/')) return env.CORE.getByName(path).fetch(request);
      if (path === '/disabled') return env.DISABLED.getByName('off').fetch(new Request('http://private/ready', request));
      return env.LEDGER.getByName('billing-nonce-v1').fetch(request);
    } };
  ` } });
const persistence = await mkdtemp(join(tmpdir(), 'neko-billing-nonce-test-'));
const make = () => new Miniflare(convertV4MiniflareOptions({ name: 'billing-nonce-boundaries', modules: true,
  script: outputFiles[0].text, compatibilityDate: '2026-08-17', resourcePersistencePath: persistence,
  bindings: { BILLING_VERIFIER_CONTAINER_ENABLED: 'YES', BILLING_STORE_ENVIRONMENT: 'Sandbox', BILLING_BUNDLE_ID: 'jp.nekowidget.app' },
  durableObjects: { LEDGER: { className: 'BillingNonceLedger', useSQLite: true },
    DISABLED: { className: 'DisabledLedger', useSQLite: true }, CORE: { className: 'CoreHarness', useSQLite: true } },
}));
const hash = value => createHash('sha256').update(value).digest('base64url');
const scope = hash('nwb:verifier:v1:Sandbox:jp.nekowidget.app');
const digest = hash(randomBytes(32));
const headers = { 'content-type': 'application/json', 'neko-nonce-scope': scope };
let mf;
const started = performance.now();
try {
  mf = make();
  assert.deepEqual(await (await mf.dispatchFetch('http://private/ready', { headers })).json(), { ready: true });
  const claim = () => mf.dispatchFetch('http://private/claim', { method: 'POST', headers, body: JSON.stringify({ digest }) });
  const concurrent = await Promise.all(Array.from({ length: 32 }, async () => {
    const response = await claim(); assert.equal(response.status, 200); return response.json();
  }));
  assert.equal(concurrent.filter(value => value.outcome === 'claimed').length, 1);
  assert.equal(concurrent.filter(value => value.outcome === 'replayed').length, 31);
  await mf.dispose();
  mf = make();
  assert.deepEqual(await (await claim()).json(), { outcome: 'replayed' });
  for (const [path, options] of [
    ['/disabled', { headers }],
    ['/ready', { headers: { ...headers, 'neko-nonce-scope': hash('nwb:verifier:v1:Production:jp.nekowidget.app') } }],
    ['/claim', { method: 'POST', headers, body: JSON.stringify({ digest, now: 0 }) }],
    ['/claim', { method: 'POST', headers, body: 'x'.repeat(129) }],
    ['/claim', { method: 'POST', headers, body: JSON.stringify({ digest: 'A'.repeat(42) + 'B' }) }],
    ['/claim?debug=true', { method: 'POST', headers, body: JSON.stringify({ digest }) }],
  ]) {
    try { assert.equal((await mf.dispatchFetch('http://private' + path, options)).status, 503); }
    catch (error) { error.message = path + ' ' + JSON.stringify(options.body?.length) + ': ' + error.message; throw error; }
  }
  const core = async (path, now, extra = {}) => mf.dispatchFetch('http://private/core/' + path, {
    method: 'POST', headers, body: JSON.stringify({ digest, now, ...extra }),
  });
  assert.deepEqual(await (await core('clock', 1000)).json(), { outcome: 'claimed' });
  assert.equal((await core('clock', 999)).status, 503);
  assert.deepEqual(await (await core('clock', 601999)).json(), { outcome: 'replayed' });
  assert.deepEqual(await (await core('clock', 602000)).json(), { outcome: 'claimed' });
  assert.equal((await core('capacity', 1000, { fill: true })).status, 503);
  assert.deepEqual(await (await core('capacity', 602000)).json(), { outcome: 'claimed' });
  console.log(JSON.stringify({ status: 'passed', durationSeconds: (performance.now() - started) / 1000,
    concurrentClaims: 32, accepted: 1, replays: 31, restartPersistent: true, scopeAndOffGates: true,
    retention601Seconds: true, backwardsClockRejected: true, capacityFailClosed: true }));
} finally { await mf?.dispose(); }
