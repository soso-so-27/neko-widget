import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes, randomUUID, sign } from 'node:crypto';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

test('private billing gateway: real named binding, bounded routes and authoritative gates', { timeout: 30000 }, async () => {
  const { outputFiles } = await build({
    entryPoints: [fileURLToPath(new URL('../src/billing-gateway.ts', import.meta.url))],
    bundle: true, write: false, format: 'esm', platform: 'neutral', target: 'es2022',
    conditions: ['workerd', 'worker', 'browser'], external: ['cloudflare:workers', 'node:*'],
  });
  const protocolBundle = await build({
    entryPoints: [fileURLToPath(new URL('../src/billing-protocol.ts', import.meta.url))],
    bundle: true, write: false, format: 'esm', platform: 'neutral', target: 'es2022',
  });
  const { billingSignedRequestTranscript } = await import('data:text/javascript;base64,'
    + Buffer.from(protocolBundle.outputFiles[0].text).toString('base64'));
  const mf = new Miniflare(convertV4MiniflareOptions({
    cf: false,
    workers: [{
      name: 'front', modules: true, compatibilityDate: '2026-08-17',
      script: `export default { fetch(request, env) {
        const path = new URL(request.url).pathname;
        return (path === '/default' ? env.PUBLIC : path === '/production' ? env.PRODUCTION
          : path.startsWith('/enabled/') ? env.ENABLED : env.GATEWAY).fetch(
            path === '/production'
              ? new Request('https://private.invalid/v1/billing/transactions', request)
              : path.startsWith('/enabled/')
                ? new Request('https://private.invalid/v1/billing/' + path.slice('/enabled/'.length), request)
                : request);
      }};`,
      serviceBindings: {
        GATEWAY: { name: 'gateway', entrypoint: 'BillingGateway' },
        PUBLIC: 'gateway',
        PRODUCTION: { name: 'production', entrypoint: 'BillingGateway' },
        ENABLED: { name: 'enabled', entrypoint: 'BillingGateway' },
      },
    }, ...['gateway', 'production', 'enabled'].map(name => ({
      name, modules: true, script: outputFiles[0].text,
      compatibilityDate: '2026-08-17', compatibilityFlags: ['nodejs_compat'],
      d1Databases: { DB: 'billing-gateway-fixture' },
      bindings: {
        ENVIRONMENT: 'local',
        BILLING_STORE_ENVIRONMENT: name === 'production' ? 'Production' : 'Sandbox',
        ...(name === 'enabled' ? {
          BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED: 'YES',
          BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED: 'YES',
        } : {}),
      },
    }))],
  }));
  const fetch = (path, init = {}) => mf.dispatchFetch('http://private' + path, {
    ...init, signal: AbortSignal.timeout(5000),
  });
  try {
    const publicResponse = await fetch('/default');
    assert.equal(publicResponse.status, 404, 'public default must not reach the named entrypoint');
    assert.equal((await fetch('/v1/billing/health')).status, 503, 'missing gate snapshot is not healthy');
    const db = await mf.getD1Database('DB', 'gateway');
    await db.prepare(`CREATE TABLE billing_runtime_gate (
      singleton INTEGER PRIMARY KEY, generation INTEGER,
      account_bootstrap_enabled INTEGER, transaction_ingestion_enabled INTEGER,
      apple_notification_ingestion_enabled INTEGER, apple_notification_history_recovery_enabled INTEGER,
      subscription_reconciliation_enabled INTEGER, effective_entitlement_enabled INTEGER,
      account_recovery_enabled INTEGER, window_sponsorship_enabled INTEGER)`).run();
    await db.prepare('INSERT INTO billing_runtime_gate VALUES(1,7,1,1,1,1,1,1,1,1)').run();
    const health = await fetch('/v1/billing/health');
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { status: 'ok', protocolVersion: 1 });
    assert.equal(health.headers.get('neko-runtime-billing-gate-generation'), '7');
    assert.equal(health.headers.get('neko-runtime-billing-transaction-ingestion'), 'OFF', 'DB alone cannot activate billing');
    assert.equal(health.headers.get('neko-runtime-billing-apple-notification-rate-limiter'), 'MISSING');
    assert.equal(health.headers.get('neko-runtime-media'), null, 'do not invent family/media state');
    assert.equal(health.headers.get('neko-runtime-apns'), null);
    assert.match(health.headers.get('cache-control'), /no-store/);
    for (const path of ['/health', '/v2/family-records', '/v1/spaces', '/v1/sharing/sources',
      '/v1/window-sponsorship', '/v1/billing/unknown', '/v1/billing/accounts/extra',
      '/v1/billing/window-sponsorships/short', '/v1/billing/../spaces']) {
      assert.equal((await fetch(path)).status, 404, path);
    }
    for (const [method, path] of [['POST', '/v1/billing/health'], ['HEAD', '/v1/billing/health'],
      ['GET', '/v1/billing/accounts'], ['PATCH', '/v1/billing/transactions'], ['POST', '/v1/billing/entitlement']]) {
      assert.equal((await fetch(path, { method })).status, 404, method + ' ' + path);
    }
    assert.equal((await fetch('/v1/billing/health?debug=1')).status, 400);
    for (const path of ['/v1/billing/accounts', '/v1/billing/accounts/recover',
      '/v1/billing/transactions', '/v1/billing/apple-notifications']) {
      const response = await fetch(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
      assert.equal(response.status, 503, path);
      assert.equal((await response.json()).error.code, 'billing_runtime_disabled');
    }
    const disabledOversized = await fetch('/v1/billing/accounts', { method: 'POST', body: 'x'.repeat(2049) });
    assert.equal(disabledOversized.status, 503, 'runtime refusal must precede body reads');
    const unclosed = new ReadableStream({
      start(controller) { controller.enqueue(new Uint8Array(1)); },
    });
    const disabledStream = await fetch('/v1/billing/accounts', { method: 'POST', body: unclosed, duplex: 'half' });
    assert.equal(disabledStream.status, 503, 'OFF must not wait for the request stream to close');
    const oversized = await fetch('/enabled/accounts', { method: 'POST', body: 'x'.repeat(2049) });
    assert.equal(oversized.status, 413);
    assert.equal((await oversized.json()).error.code, 'body_too_large');
    const streaming = new ReadableStream({
      start(controller) { controller.enqueue(new Uint8Array(1024)); controller.enqueue(new Uint8Array(1025)); controller.close(); },
    });
    assert.equal((await fetch('/enabled/accounts', { method: 'POST', body: streaming, duplex: 'half' })).status, 413);
    const production = await fetch('/production', { method: 'POST', body: '{}' });
    assert.equal(production.status, 503);
    assert.equal((await production.json()).error.code, 'billing_gateway_unavailable');
    const unauthenticated = await fetch('/enabled/transactions', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
    assert.equal(unauthenticated.status, 401, 'enabled route must still run main authentication');
    assert.equal((await unauthenticated.json()).error.code, 'invalid_billing_authentication');
    await db.prepare(`CREATE TABLE billing_account_keys (
      id TEXT PRIMARY KEY, billing_account_id TEXT, signing_public_key TEXT, state TEXT)`).run();
    await db.prepare(`CREATE TABLE billing_request_nonces (
      billing_key_id TEXT, nonce TEXT, created_at INTEGER, expires_at INTEGER,
      PRIMARY KEY (billing_key_id, nonce))`).run();
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const accountId = randomUUID();
    const keyId = randomBytes(16).toString('base64url');
    await db.prepare('INSERT INTO billing_account_keys VALUES(?,?,?,?)').bind(
      keyId, accountId, publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64url'), 'active',
    ).run();
    const timestamp = Math.floor(Date.now() / 1000);
    const nonce = randomBytes(16).toString('base64url');
    const body = '{ "protocolVersion": 1, "signedTransactionInfo":"\\u0068eader.payload.signature" }\n';
    const transcript = billingSignedRequestTranscript({
      billingAccountId: accountId, billingKeyId: keyId, timestamp, nonce, method: 'POST',
      pathname: '/v1/billing/transactions', bodySHA256: createHash('sha256').update(body).digest('base64url'),
    });
    const signedRequest = { method: 'POST', body, headers: {
      'content-type': 'application/json', 'neko-billing-protocol-version': '1',
      'neko-billing-account-id': accountId, 'neko-billing-key-id': keyId,
      'neko-billing-timestamp': String(timestamp), 'neko-billing-nonce': nonce,
      'neko-billing-signature': sign(null, transcript, privateKey).toString('base64url'),
    }};
    const authenticated = await fetch('/enabled/transactions', signedRequest);
    assert.equal(authenticated.status, 503);
    assert.equal((await authenticated.json()).error.code, 'billing_configuration_unavailable',
      'signed original bytes must authenticate before reaching missing verifier configuration');
    const replay = await fetch('/enabled/transactions', signedRequest);
    assert.equal(replay.status, 409);
    assert.equal((await replay.json()).error.code, 'replayed_billing_request');
    await db.prepare('UPDATE billing_runtime_gate SET generation=-1 WHERE singleton=1').run();
    assert.equal((await fetch('/v1/billing/health')).status, 503);
  } finally {
    await mf.dispose();
  }
});
