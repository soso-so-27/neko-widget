import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes, randomUUID, sign } from 'node:crypto';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { readdir, readFile } from 'node:fs/promises';
import { DatabaseSync } from 'node:sqlite';

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
  const { billingSignedRequestTranscript, billingAccountCreationTranscript } = await import('data:text/javascript;base64,'
    + Buffer.from(protocolBundle.outputFiles[0].text).toString('base64'));
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const rawPublicKey = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
  const enrollmentId = randomUUID();
  const ownerPolicy = JSON.stringify({ version: 1, bootstrapClientRequestId: enrollmentId, initialPublicKeySHA256: createHash('sha256').update(rawPublicKey).digest('hex'), startsAtMs: Date.now() - 1000, expiresAtMs: Date.now() + 3600000 });
  const mf = new Miniflare(convertV4MiniflareOptions({
    cf: false,
    workers: [{
      name: 'front', modules: true, compatibilityDate: '2026-08-17',
      script: `export default { fetch(request, env) {
        const path = new URL(request.url).pathname;
        if (path === '/retention') return env.RETENTION.fetch(new Request('https://private.invalid/internal/retention/refresh', request));
        return (path.startsWith('/expired/') ? env.EXPIRED : path.startsWith('/malformed/') ? env.MALFORMED : path === '/default' ? env.PUBLIC : path === '/production' ? env.PRODUCTION
          : path.startsWith('/enabled/') ? env.ENABLED : env.GATEWAY).fetch(
            path.startsWith('/expired/') || path.startsWith('/malformed/')
              ? new Request('https://private.invalid/v1/billing/' + path.split('/').slice(2).join('/'), request)
              : path === '/production'
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
        EXPIRED: { name: 'expired', entrypoint: 'BillingGateway' },
        MALFORMED: { name: 'malformed', entrypoint: 'BillingGateway' },
        RETENTION: { name: 'expired', entrypoint: 'RetentionBillingObserver' },
      },
    }, ...['gateway', 'production', 'enabled', 'expired', 'malformed'].map(name => ({
      name, modules: true, script: outputFiles[0].text,
      compatibilityDate: '2026-08-17', compatibilityFlags: ['nodejs_compat'],
      d1Databases: { DB: 'billing-gateway-fixture' },
      serviceBindings: { BILLING_VERIFIER_SERVICE: 'front' }, // Never called for fresh observations.
      bindings: {
        ENVIRONMENT: 'local',
        BILLING_STORE_ENVIRONMENT: name === 'production' ? 'Production' : 'Sandbox',
        BILLING_SUBSCRIPTION_GROUP_ID: '20999999', BILLING_VERIFIER_TRANSPORT: 'private-binding',
        PRESERVATION_RETENTION_REFRESH_ENABLED: 'YES', BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED: 'YES',
        ...(['enabled', 'expired', 'malformed'].includes(name) ? {
          BILLING_SANDBOX_OWNER_ADMISSION: name === 'expired' ? JSON.stringify({ ...JSON.parse(ownerPolicy), startsAtMs: Date.now() - 2000, expiresAtMs: Date.now() - 1000 }) : name === 'malformed' ? JSON.stringify({ ...JSON.parse(ownerPolicy), bootstrapClientRequestId: [enrollmentId] }) : ownerPolicy,
          BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED: 'YES',
          BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED: 'YES',
        } : {}),
      },
    }))],
  }));
  const front = await mf.getWorker('front');
  let lastRequestPath = '';
  const fetch = (path, init = {}) => { lastRequestPath = path; return front.fetch('http://private' + path, {
    ...init, signal: AbortSignal.timeout(5000),
  }); };
  try {
    await mf.ready; // Startup is outside the per-request service deadline.
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
    for (const variant of ['expired', 'malformed']) {
      const closedHealth = await fetch('/' + variant + '/health');
      assert.equal(closedHealth.status, 200);
      assert.equal(closedHealth.headers.get('neko-runtime-billing-owner-admission'), 'CLOSED');
      assert.equal(closedHealth.headers.get('neko-runtime-billing-transaction-ingestion'), 'OFF');
      const refused = await fetch('/' + variant + '/accounts', { method: 'POST', body: 'x'.repeat(2049) });
      assert.equal(refused.status, 503, 'closed policy precedes reads even with upper and lower gates ON');
      assert.equal((await refused.json()).error.code, 'billing_owner_admission_unavailable');
    }
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
      assert.equal((await response.json()).error.code, 'billing_owner_admission_unavailable');
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
      id TEXT PRIMARY KEY, billing_account_id TEXT, signing_public_key TEXT, state TEXT, created_at INTEGER)`).run();
    await db.prepare(`CREATE TABLE billing_request_nonces (
      billing_key_id TEXT, nonce TEXT, created_at INTEGER, expires_at INTEGER,
      PRIMARY KEY (billing_key_id, nonce))`).run();
    await db.prepare('CREATE TABLE billing_accounts (id TEXT PRIMARY KEY, created_at INTEGER)').run();
    await db.prepare('CREATE TABLE billing_account_bootstrap_requests (client_request_id TEXT PRIMARY KEY, request_hash TEXT, billing_account_id TEXT, billing_key_id TEXT, created_at INTEGER)').run();
    const enrollmentRequest = clientRequestId => ({ method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ protocolVersion: 1, clientRequestId, signingPublicKey: rawPublicKey.toString('base64url'), creationSignature: sign(null, billingAccountCreationTranscript({ clientRequestId, signingPublicKey: rawPublicKey.toString('base64url') }), privateKey).toString('base64url') }) });
    const wrongEnrollment = await fetch('/enabled/accounts', enrollmentRequest(randomUUID()));
    assert.equal(wrongEnrollment.status, 403, 'valid bootstrap proof with another request ID must fail');
    assert.equal((await db.prepare('SELECT COUNT(*) AS count FROM billing_accounts').first()).count, 0);
    const created = await fetch('/enabled/accounts', enrollmentRequest(enrollmentId));
    assert.equal(created.status, 201);
    const { billingAccountId: accountId, billingKeyId: keyId } = await created.json();
    const repeated = await fetch('/enabled/accounts', enrollmentRequest(enrollmentId));
    assert.equal(repeated.status, 201);
    assert.equal((await repeated.json()).billingAccountId, accountId);
    assert.equal((await db.prepare('SELECT COUNT(*) AS count FROM billing_accounts').first()).count, 1, 'only one enrolled account');
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
    const otherAccount = randomUUID();
    const otherKey = randomBytes(16).toString('base64url');
    await db.prepare('INSERT INTO billing_account_keys VALUES(?,?,?,?,?)').bind(otherKey, otherAccount, rawPublicKey.toString('base64url'), 'active', timestamp).run();
    const otherNonce = randomBytes(16).toString('base64url');
    const otherTranscript = billingSignedRequestTranscript({ billingAccountId: otherAccount, billingKeyId: otherKey, timestamp, nonce: otherNonce, method: 'POST', pathname: '/v1/billing/transactions', bodySHA256: createHash('sha256').update(body).digest('base64url') });
    const other = await fetch('/enabled/transactions', { ...signedRequest, headers: { ...signedRequest.headers, 'neko-billing-account-id': otherAccount, 'neko-billing-key-id': otherKey, 'neko-billing-nonce': otherNonce, 'neko-billing-signature': sign(null, otherTranscript, privateKey).toString('base64url') } });
    assert.equal(other.status, 403, 'valid signature on another account must not reach verification');
    assert.equal((await other.json()).error.code, 'billing_owner_admission_required');
    assert.equal((await db.prepare('SELECT COUNT(*) AS count FROM billing_request_nonces WHERE billing_key_id=?').bind(otherKey).first()).count, 0, 'denied account does not consume nonce or write state');
    const replay = await fetch('/enabled/transactions', signedRequest);
    assert.equal(replay.status, 409);
    assert.equal((await replay.json()).error.code, 'replayed_billing_request');
    await db.prepare('UPDATE billing_runtime_gate SET generation=-1 WHERE singleton=1').run();
    assert.equal((await fetch('/v1/billing/health')).status, 503);
    await db.prepare('UPDATE billing_runtime_gate SET generation=7 WHERE singleton=1').run();
    await db.prepare('CREATE TABLE billing_transaction_lineages(original_transaction_id TEXT,billing_account_id TEXT,environment TEXT,subscription_group_id TEXT)').run();
    await db.prepare('CREATE TABLE billing_effective_entitlement_current(original_transaction_id TEXT,billing_account_id TEXT,environment TEXT,subscription_group_id TEXT,source_fetched_at_ms INTEGER,authority_stale_at_ms INTEGER,materialized_grants_plus INTEGER)').run();
    await db.prepare('INSERT INTO billing_transaction_lineages VALUES(?,?,?,?)').bind('210000000012345',accountId,'Sandbox','20999999').run();
    await db.prepare('INSERT INTO billing_effective_entitlement_current VALUES(?,?,?,?,?,?,?)').bind('210000000012345',accountId,'Sandbox','20999999',Date.now(),Date.now()+3600000,0).run();
    assert.equal((await fetch('/retention', { method: 'POST', body: JSON.stringify({ billingAccountId: accountId }) })).status, 204,
      'actual named retention binding operates while purchase admission is expired');
  } catch (error) {
    throw new Error('gateway fixture last request: ' + lastRequestPath, { cause: error });
  } finally {
    await mf.dispose();
  }
});

test('retention observer preserves generations, leases, backoff and closed purchase admission', { timeout: 45000 }, async () => {
  const bundle = await build({
    entryPoints: [fileURLToPath(new URL('../src/billing-gateway.ts', import.meta.url))],
    bundle: true, write: false, format: 'esm', platform: 'neutral', target: 'es2022',
    plugins: [{ name: 'node-entrypoint-adapter', setup(b) {
      b.onResolve({ filter: /^cloudflare:workers$/ }, () => ({ path: 'workers', namespace: 'test' }));
      b.onLoad({ filter: /.*/, namespace: 'test' }, () => ({ contents: 'export class WorkerEntrypoint {}' }));
    } }],
  });
  const { refreshRetentionBilling, RetentionBillingObserver, BillingGateway, default: publicWorker } = await import(
    'data:text/javascript;base64,' + Buffer.from(bundle.outputFiles[0].text).toString('base64'));
  const sqlite = new DatabaseSync(':memory:');
  for (const name of (await readdir(new URL('../migrations/', import.meta.url))).filter(n => /^00(?:0[1-9]|1[0-9]|2[0-5])_/.test(n)).sort()) {
    sqlite.exec(await readFile(new URL('../migrations/' + name, import.meta.url), 'utf8'));
  }
  const statement = (sql, args = []) => ({
    bind(...values) { return statement(sql, values); },
    async first() { return sqlite.prepare(sql).get(...args) ?? null; },
    async all() { return { results: sqlite.prepare(sql).all(...args) }; },
    async run() { return { meta: { changes: Number(sqlite.prepare(sql).run(...args).changes) } }; },
  });
  const DB = { prepare: statement, async batch(statements) {
    sqlite.exec('BEGIN');
    try { const results = []; for (const s of statements) results.push(await s.run()); sqlite.exec('COMMIT'); return results; }
    catch (e) { sqlite.exec('ROLLBACK'); throw e; }
  } };
  sqlite.exec('UPDATE billing_runtime_gate SET generation=generation+1,subscription_reconciliation_enabled=1,effective_entitlement_enabled=1,updated_at=unixepoch()');
  const env = { DB, ENVIRONMENT: 'staging', BILLING_STORE_ENVIRONMENT: 'Sandbox', BILLING_SUBSCRIPTION_GROUP_ID: '20999999',
    PRESERVATION_RETENTION_REFRESH_ENABLED: 'YES', BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED: 'YES',
    BILLING_VERIFIER_TRANSPORT: 'private-binding', BILLING_VERIFIER_ORIGIN: 'https://billing-verifier.private.invalid',
    BILLING_VERIFIER_SHARED_SECRET: randomBytes(32).toString('base64url'), BILLING_BUNDLE_ID: 'jp.nekowidget.app',
    BILLING_MONTHLY_PRODUCT_ID: 'jp.nekowidget.plus.monthly', BILLING_VERIFIER_SERVICE: { fetch() { throw new Error('not expected'); } },
    BILLING_SANDBOX_OWNER_ADMISSION: JSON.stringify({ version: 1, bootstrapClientRequestId: randomUUID(), initialPublicKeySHA256: 'a'.repeat(64), startsAtMs: Date.now()-2000, expiresAtMs: Date.now()-1000 }) };
  const originalNow = Date.now;
  let now = originalNow(); Date.now = () => now;
  const account = randomUUID(), lineage = '210000000012345';
  sqlite.prepare('INSERT INTO billing_accounts(id) VALUES(?)').run(account);
  sqlite.prepare('INSERT INTO billing_transaction_lineages(original_transaction_id,billing_account_id,environment,subscription_group_id) VALUES(?,?,?,?)').run(lineage,account,'Sandbox','20999999');
  let transactionId = lineage, renewalExpiresAt = null;
  const status = () => ({ requestedTransactionId: lineage, environment: 'Sandbox', bundleId: 'jp.nekowidget.app', fetchedAtMs: now,
    items: [{ status: 2, originalTransactionId: lineage, transaction: { transactionId, originalTransactionId: lineage, billingAccountId: account,
      productId: 'jp.nekowidget.plus.monthly', subscriptionGroupId: '20999999', bundleId: 'jp.nekowidget.app', environment: 'Sandbox', ownershipType: 'PURCHASED',
      transactionReason: 'PURCHASE', purchaseDateMs: now-10000, originalPurchaseDateMs: now-10000, expiresDateMs: renewalExpiresAt ?? now-5000, signedDateMs: now,
      revocationDateMs: null, revocationReason: null, isUpgraded: false }, renewal: { originalTransactionId: lineage, billingAccountId: account,
      productId: 'jp.nekowidget.plus.monthly', autoRenewProductId: 'jp.nekowidget.plus.monthly', autoRenewStatus: 0, isInBillingRetryPeriod: false,
      gracePeriodExpiresDateMs: null, renewalDateMs: renewalExpiresAt ?? now-5000, signedDateMs: now, environment: 'Sandbox' } }] });
  let calls = 0;
  const fetcher = async () => { calls++; return status(); };
  const request = () => new Request('https://private/internal/retention/refresh', { method: 'POST', body: JSON.stringify({ billingAccountId: account }) });
  const call = (overrides = {}, req = request()) => RetentionBillingObserver.prototype.fetch.call({ env: { ...env, ...overrides } }, req);
  try {
    sqlite.prepare('INSERT INTO billing_reconciliation_jobs(original_transaction_id,requested_at,not_before,request_generation) VALUES(?,0,0,7)').run(lineage);
    await refreshRetentionBilling(env, account, fetcher);
    assert.equal(calls, 1);
    assert.equal(sqlite.prepare('SELECT request_generation FROM billing_effective_entitlement_current').get().request_generation, 7);
    assert.equal(sqlite.prepare('SELECT count(*) AS n FROM billing_reconciliation_jobs').get().n, 0, 'terminal success removes its job');
    assert.equal((await call()).status, 204, 'fresh source needs no verifier or renewed purchase admission');
    const closed = await BillingGateway.prototype.fetch.call({ env, ctx: {} }, new Request('https://private/v1/billing/accounts', { method: 'POST', body: '{}' }));
    assert.equal(closed.status, 503, 'expired purchase admission remains closed');
    assert.equal(publicWorker.fetch().status, 404);
    assert.equal((await call({ ENVIRONMENT: 'production' })).status, 503);
    assert.equal((await call({ BILLING_STORE_ENVIRONMENT: 'Production' })).status, 503);
    assert.equal((await call({ PRESERVATION_RETENTION_REFRESH_ENABLED: 'NO' })).status, 503);
    now += 15*60*1000-1;
    await refreshRetentionBilling(env, account, fetcher);
    assert.equal(calls, 1, 'negative Sandbox observations retain the short cache before its boundary');
    now++;
    await refreshRetentionBilling(env, account, async () => {
      calls++;
      transactionId = '210000000012346';
      renewalExpiresAt = now + 60*60*1000;
      const renewed = status();
      renewed.items[0].status = 1;
      renewed.items[0].renewal.autoRenewStatus = 1;
      return renewed;
    });
    assert.equal(calls, 2, 'an expired Sandbox subscription can be observed active at the fifteen-minute boundary');
    assert.equal(sqlite.prepare('SELECT materialized_status FROM billing_effective_entitlement_current').get().materialized_status, 'active');
    assert.equal(sqlite.prepare('SELECT request_generation FROM billing_reconciliation_jobs').get().request_generation, 8, 'active renewal retains its periodic job');
    now += 15*60*1000;
    await refreshRetentionBilling(env, account, fetcher);
    assert.equal(calls, 2, 'active authority keeps its existing daily cache');
    now += 24*60*60*1000;
    let release, entered; const started = new Promise(resolve => { entered = resolve; });
    const inFlight = refreshRetentionBilling(env, account, async () => { calls++; entered(); await new Promise(resolve => { release = resolve; }); return status(); });
    await started;
    await assert.rejects(refreshRetentionBilling(env, account, fetcher), /temporarily unavailable/);
    assert.equal(calls, 3, 'concurrent invocation cannot acquire the same lease');
    release(); await inFlight;
    assert.equal(sqlite.prepare('SELECT request_generation FROM billing_effective_entitlement_current').get().request_generation, 8, 'refresh preserves the retained periodic job generation');
    now += 24*60*60*1000;
    await assert.rejects(refreshRetentionBilling(env, account, async () => { calls++; throw new Error('outage'); }), /temporarily unavailable/);
    const failed = sqlite.prepare('SELECT * FROM billing_reconciliation_jobs').get();
    assert.equal(failed.attempts, 1); assert.equal(failed.lease_token, null);
    await assert.rejects(refreshRetentionBilling(env, account, fetcher), /temporarily unavailable/);
    assert.equal(calls, 4, 'not-due backoff performs no external request');
    assert.deepEqual(sqlite.prepare('SELECT * FROM billing_reconciliation_jobs').get(), failed, 'observation never resets backoff or generation');
    assert.equal((await call()).status, 503, 'stale data remains unknown after an unsuccessful refresh');
    sqlite.prepare('UPDATE billing_reconciliation_jobs SET not_before=0').run();
    let observedAbort = false;
    let slowRequest;
    const slow = { BILLING_VERIFIER_SERVICE: { fetch(req) { return new Promise((_, reject) => {
      slowRequest = req;
      if (req.signal.aborted) { observedAbort = true; reject(req.signal.reason); return; }
      req.signal.addEventListener('abort', () => { observedAbort = true; reject(req.signal.reason); }, { once: true });
    }); } } };
    const startedAt = performance.now();
    assert.equal((await call(slow)).status, 503, 'slow verifier expires to unknown');
    assert.ok(observedAbort); assert.ok(performance.now()-startedAt >= 29000 && performance.now()-startedAt < 35000);
    const timedOut = sqlite.prepare('SELECT * FROM billing_reconciliation_jobs').get();
    assert.equal(timedOut.attempts, 2); assert.equal(timedOut.lease_token, null);
    sqlite.prepare('UPDATE billing_reconciliation_jobs SET not_before=0').run();
    observedAbort = false;
    const cancel = new AbortController();
    const canceled = call(slow, new Request(request(), { signal: cancel.signal }));
    setTimeout(() => cancel.abort(), 20);
    assert.equal((await canceled).status, 503); assert.ok(observedAbort, 'caller cancellation reaches verifier');
    assert.equal(sqlite.prepare('SELECT lease_token FROM billing_reconciliation_jobs').get().lease_token, null);
    for (let i = 0; i < 8; i++) sqlite.prepare('INSERT INTO billing_transaction_lineages(original_transaction_id,billing_account_id,environment,subscription_group_id) VALUES(?,?,?,?)').run(String(220000000012345+i),account,'Sandbox','20999999');
    await assert.rejects(refreshRetentionBilling(env, account, fetcher), /temporarily unavailable/);
    assert.equal(calls, 4, 'ninth lineage is refused before contacting Apple');
  } finally { Date.now = originalNow; sqlite.close(); }
});
