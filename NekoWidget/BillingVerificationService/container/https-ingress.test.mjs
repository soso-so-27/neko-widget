// Actual Worker entrypoints in local workerd. Container lookup is replaced
// with a counting service; no Container, Apple request or real HTTPS is used.
import assert from 'node:assert/strict';
import { createHmac, createHash, randomBytes } from 'node:crypto';
import { createRequire } from 'node:module';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
const require = createRequire(import.meta.url);
const { build } = require('esbuild');
const { Miniflare, convertV4MiniflareOptions } = createRequire(new URL('../../PreservationService/package.json', import.meta.url))('miniflare');
const directory = dirname(fileURLToPath(import.meta.url));
const { outputFiles } = await build({ bundle: true, write: false, format: 'esm', platform: 'browser',
  external: ['cloudflare:*'], plugins: [{ name: 'no-container', setup(builder) {
    builder.onResolve({ filter: /^@cloudflare\/containers$/ }, () => ({ path: 'fake', namespace: 'no-container' }));
    builder.onLoad({ filter: /.*/, namespace: 'no-container' }, () => ({ contents: `
      import { DurableObject } from 'cloudflare:workers';
      export class Container extends DurableObject {}
      export class ContainerProxy extends DurableObject {}
      export function getContainer(binding) { return binding; }
    ` }));
  } }], stdin: { resolveDir: directory, contents: `
    export { default, BillingVerificationService } from './worker.mjs';
  ` } });
const pair = await generateKeyPair('RS256');
const otherPair = await generateKeyPair('RS256');
const jwks = { keys: [{ ...await exportJWK(pair.publicKey), kid: 'synthetic-access', alg: 'RS256', use: 'sig' }] };
const issuer = 'https://synthetic-billing.cloudflareaccess.com';
const origin = 'https://verifier-production.test';
const audience = 'a'.repeat(64);
const sharedSecret = randomBytes(32).toString('base64url');
const base = { BILLING_VERIFIER_CONTAINER_ENABLED: 'YES', BILLING_VERIFIER_HTTPS_ENABLED: 'YES',
  BILLING_STORE_ENVIRONMENT: 'Production', BILLING_VERIFIER_HTTPS_ORIGIN: origin,
  BILLING_VERIFIER_ACCESS_ISSUER: issuer, BILLING_VERIFIER_ACCESS_AUD: audience,
  BILLING_VERIFIER_SHARED_SECRET: sharedSecret };
const paths = ['/internal/v1/apple-transactions/verify', '/internal/v1/apple-notifications/verify',
  '/internal/v1/apple-notifications/history', '/internal/v1/apple-subscriptions/status',
  '/internal/v1/apple-billing-recoveries/verify'];
const now = Math.floor(Date.now() / 1000);
const token = async (claims = {}, signingKey = pair.privateKey, header = {}) => new SignJWT({
  iss: issuer, aud: [audience], iat: now, exp: now + 300, ...claims,
}).setProtectedHeader({ alg: 'RS256', kid: 'synthetic-access', ...header }).sign(signingKey);
const validToken = await token();
const hash = bytes => createHash('sha256').update(bytes).digest('base64url');
const signature = (key, body, timestamp, nonce) => createHmac('sha256', Buffer.from(key, 'base64url'))
  .update(['NWB1.VERIFIER.REQUEST', timestamp, nonce, hash(body)].join('\n')).digest('base64url');
const signed = (jwt = validToken, body = '{"protocolVersion":1}', options = {}) => {
  const timestamp = String(options.timestamp ?? Math.floor(Date.now() / 1000));
  const nonce = randomBytes(16).toString('base64url');
  return { method: 'POST', body, headers: { 'content-type': 'application/json',
    'cf-access-jwt-assertion': jwt, 'cf-access-client-id': 'never-forward',
    'cf-access-client-secret': 'never-forward', cookie: 'never-forward', authorization: 'never-forward',
    'neko-billing-protocol-version': '1', 'neko-billing-timestamp': timestamp,
    'neko-billing-nonce': nonce, 'neko-billing-signature': signature(options.secret ?? sharedSecret, body, timestamp, nonce) } };
};
let calls = 0; let keyFetches = 0; let received; let keysMode = 'valid';
const options = { workers: [
  { name: 'verifier', modules: true, script: outputFiles[0].text,
    compatibilityDate: '2026-08-17', compatibilityFlags: ['nodejs_compat'], bindings: base,
    serviceBindings: { BILLING_CONTAINER: async request => {
      calls++; received = { headers: new Headers(request.headers), body: await request.text() };
      return new Response('synthetic-container-response', { headers: { 'neko-billing-response-signature': 'retained' } });
    } }, outboundService: async request => {
      keyFetches++;
      assert.equal(request.url, issuer + '/cdn-cgi/access/certs');
      assert.equal(request.method, 'GET');
      assert.equal(request.headers.get('cf-access-client-secret'), null);
      if (keysMode === 'redirect') return new Response(null, { status: 302, headers: { location: 'https://never-fetch.test' } });
      if (keysMode === 'unavailable') return new Response(null, { status: 503 });
      if (keysMode === 'invalid') return new Response('not-json');
      if (keysMode === 'oversized') return new Response('x'.repeat(65_537));
      return Response.json(jwks);
    } },
  { name: 'private-caller', modules: true, script: `export default {fetch(request,env){return env.PRIVATE.fetch(request);}};`,
    compatibilityDate: '2026-08-17', serviceBindings: { PRIVATE: { name: 'verifier', entrypoint: 'BillingVerificationService' } } },
] };
const mf = new Miniflare(convertV4MiniflareOptions(options));
let assertions = 0;
async function denied(label, url, init, expected = 403, worker = 'verifier') {
  const before = calls;
  const response = await (await mf.getWorker(worker)).fetch(url, init);
  assert.equal(response.status, expected, label);
  assert.equal(calls, before, `${label}: Container must not be called`); assertions++;
}
try {
  for (const path of paths) {
    const response = await (await mf.getWorker('verifier')).fetch(origin + path, signed());
    assert.equal(response.status, 200, path); assert.equal(await response.text(), 'synthetic-container-response');
    assert.equal(response.headers.get('neko-billing-response-signature'), 'retained');
    assert.equal(received.body, '{"protocolVersion":1}');
    for (const header of ['cf-access-jwt-assertion', 'cf-access-client-id', 'cf-access-client-secret', 'cookie', 'authorization']) {
      assert.equal(received.headers.get(header), null);
    }
    assert.ok(received.headers.get('neko-billing-signature')); assertions++;
  }
  assert.equal(keyFetches, 1, 'verified keys are reused within bounded cache');
  for (const [label, jwt] of [
    ['wrong AUD / other environment', await token({ aud: ['b'.repeat(64)] })],
    ['ambiguous AUD', await token({ aud: [audience, 'b'.repeat(64)] })],
    ['wrong issuer', await token({ iss: 'https://other.cloudflareaccess.com' })],
    ['expired', await token({ exp: now - 1 })], ['not yet valid', await token({ nbf: now + 100 })],
    ['future issued', await token({ iat: now + 100 })], ['missing expiry', await token({ exp: undefined })],
    ['bad signature', await token({}, otherPair.privateKey)], ['unknown key', await token({}, pair.privateKey, { kid: 'unknown' })],
    ['unsigned', 'eyJhbGciOiJub25lIn0.e30.'], ['missing', ''], ['oversized', 'x'.repeat(16385)],
  ]) await denied(label, origin + paths[0], signed(jwt));
  for (const url of ['https://wrong-host.test' + paths[0], 'http://verifier-production.test' + paths[0],
    origin + ':8443' + paths[0], origin + '/health', origin + paths[0] + '?debug=1', origin + paths[0] + '?']) {
    await denied('unselected URL', url, signed());
  }
  await denied('wrong method', origin + paths[0], { method: 'GET', headers: signed().headers });
  await denied('HMAC remains required', origin + paths[0], signed(validToken, '{}', { secret: randomBytes(32).toString('base64url') }), 503);
  await denied('stale HMAC timestamp', origin + paths[0], signed(validToken, '{}', { timestamp: now - 301 }), 503);
  await denied('body bound remains', origin + paths[0], signed(validToken, 'x'.repeat(65537)), 503);
  await denied('recovery body bound remains', origin + paths[4], signed(validToken, 'x'.repeat(131073)), 503);
  const tampered = signed(); tampered.body = '{"protocolVersion":2}';
  await denied('body HMAC is checked after Access', origin + paths[0], tampered, 503);
  await denied('production binding cannot bypass Access', 'https://billing-verifier.private.invalid' + paths[0], signed(), 503, 'private-caller');
  // Reconfigure local workerd only; no deployed setting is changed.
  for (const overrides of [
    { BILLING_VERIFIER_HTTPS_ENABLED: 'NO' }, { BILLING_VERIFIER_CONTAINER_ENABLED: 'NO' },
    { BILLING_VERIFIER_ACCESS_ISSUER: '' }, { BILLING_VERIFIER_ACCESS_AUD: '' },
    { BILLING_VERIFIER_HTTPS_ORIGIN: 'https://wrong-host.test/path' }, { BILLING_STORE_ENVIRONMENT: '' },
    { BILLING_STORE_ENVIRONMENT: 'Sandbox', BILLING_VERIFIER_ACCESS_AUD: 'b'.repeat(64), BILLING_VERIFIER_HTTPS_ORIGIN: 'https://verifier-sandbox.test' },
  ]) {
    options.workers[0].bindings = { ...base, ...overrides };
    await mf.setOptions(convertV4MiniflareOptions(options));
    await denied('missing/off/cross-environment configuration',
      overrides.BILLING_STORE_ENVIRONMENT === 'Sandbox' ? 'https://verifier-sandbox.test' + paths[0] : origin + paths[0], signed());
  }
  options.workers[0].bindings = { ...base, BILLING_STORE_ENVIRONMENT: 'Sandbox', BILLING_VERIFIER_HTTPS_ENABLED: 'NO' };
  await mf.setOptions(convertV4MiniflareOptions(options));
  const response = await (await mf.getWorker('private-caller')).fetch('https://billing-verifier.private.invalid' + paths[0], signed(''));
  assert.equal(response.status, 200, 'existing Sandbox private binding remains available'); assertions++;
  for (const overrides of [{ BILLING_VERIFIER_HTTPS_ENABLED: 'YES' }, { ENVIRONMENT: 'production' }]) {
    options.workers[0].bindings = { ...base, BILLING_STORE_ENVIRONMENT: 'Sandbox', BILLING_VERIFIER_HTTPS_ENABLED: 'NO', ...overrides };
    await mf.setOptions(convertV4MiniflareOptions(options));
    await denied('public deployment has no private bypass even with Sandbox store',
      'https://billing-verifier.private.invalid' + paths[0], signed(), 503, 'private-caller');
  }
  for (keysMode of ['redirect', 'unavailable', 'invalid', 'oversized']) {
    options.workers[0].bindings = { ...base };
    await mf.setOptions(convertV4MiniflareOptions(options));
    await denied('JWKS ' + keysMode, origin + paths[0], signed());
  }
  console.log(JSON.stringify({ status: 'passed', assertions, authenticatedPublicPaths: 5,
    containerCalls: calls, realContainerStarts: 0, realHTTPSRequests: 0, productionBindingClosed: true }));
} finally { await mf.dispose(); }
