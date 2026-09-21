import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { generateKeyPair, jwtVerify } from 'jose';
import { createSyntheticIdentity } from './synthetic-identity.mjs';
import { APPLE_ISSUER, APPLE_KEYS_URL, APPLE_TOKEN_URL, PreparedAppleSigninAdapter,
  createAppleClientSecret } from './apple-signin-adapter.mjs';

// These keys only impersonate Apple's protocol in an injected mock transport.
// Nothing in this test contacts Apple, the app, or a real user account.
const START = Date.UTC(2026, 8, 22, 0, 0, 0);
const clientId = 'invalid.synthetic.neko';
const signer = await createSyntheticIdentity({ issuer: APPLE_ISSUER, audience: clientId, now: () => START });
const unrelatedSigner = await createSyntheticIdentity({ issuer: APPLE_ISSUER, audience: clientId, now: () => START });
const codeHash = (code) => createHash('sha256').update(code).digest().subarray(0, 16).toString('base64url');
const errorCode = (code) => (error) => error.code === code && error.message === code;

async function setup(overrides = {}) {
  let time = START;
  let consumed = false;
  let exchangeClaims = overrides.exchangeClaims ?? {};
  const calls = [];
  const nonce = randomBytes(32).toString('base64url');
  const authorizationCode = 'synthetic-authorization-code';
  const challengeProof = randomBytes(32).toString('base64url');
  const challengeId = randomBytes(32).toString('base64url');
  const validClaims = { sub: 'person-a', nonce, c_hash: codeHash(authorizationCode) };
  const request = { challengeId, challengeProof, authorizationCode,
    identityToken: await (overrides.signer ?? signer).signToken({ ...validClaims, ...overrides.nativeClaims }) };
  const adapter = new PreparedAppleSigninAdapter({ enabled: overrides.enabled ?? true, clientId,
    now: () => time, getClientSecret: async () => 'synthetic-server-secret',
    takeChallenge: async (input) => {
      if (consumed || input.challengeId !== challengeId || input.challengeProof !== challengeProof) return null;
      consumed = true; // Simulates the atomic, durable-store contract. Not a production store.
      return { nonce, createdAt: START, expiresAt: START + 300_000 };
    },
    fetchImpl: async (url, init) => {
      calls.push({ url, method: init.method });
      assert.equal(init.redirect, 'error');
      if (url === APPLE_KEYS_URL) {
        assert.equal(init.method, 'GET');
        if (overrides.keysUnavailable) throw new Error('synthetic-key-fetch-error');
        return Response.json(signer.jwks);
      }
      assert.equal(url, APPLE_TOKEN_URL, 'the adapter must never send credentials elsewhere');
      assert.equal(init.method, 'POST');
      assert.equal(init.headers['content-type'], 'application/x-www-form-urlencoded');
      const form = new URLSearchParams(init.body);
      assert.deepEqual([...form.keys()].sort(), ['client_id', 'client_secret', 'code', 'grant_type']);
      assert.equal(form.get('client_id'), clientId);
      assert.equal(form.get('code'), authorizationCode);
      assert.equal(form.get('client_secret'), 'synthetic-server-secret');
      assert.equal(form.get('grant_type'), 'authorization_code');
      if (overrides.networkError) throw new Error('LEAK-ME-synthetic-secret');
      if (overrides.duringExchange) overrides.duringExchange((ms) => { time += ms; });
      if (overrides.status) return Response.json({ error: overrides.oauthError }, { status: overrides.status });
      if (overrides.hugeResponse) return new Response('x'.repeat(65_537));
      return Response.json({ token_type: 'Bearer', expires_in: 3600,
        access_token: 'synthetic-access', refresh_token: 'synthetic-refresh',
        id_token: await signer.signToken({ ...validClaims, c_hash: undefined, ...exchangeClaims }),
        ...overrides.responseFields });
    },
  });
  return { adapter, request, calls, advance(ms) { time += ms; }, setExchangeClaims(claims) { exchangeClaims = claims; } };
}

test('client secret uses ES256 and the app/team/key identifiers with a short expiry', async () => {
  const { privateKey, publicKey } = await generateKeyPair('ES256');
  const token = await createAppleClientSecret({ teamId: 'SYNTHETIC1', keyId: 'SYNTHETIC2', clientId, privateKey, now: () => START });
  const verified = await jwtVerify(token, publicKey, { algorithms: ['ES256'], issuer: 'SYNTHETIC1',
    audience: APPLE_ISSUER, subject: clientId, currentDate: new Date(START) });
  assert.equal(verified.protectedHeader.kid, 'SYNTHETIC2');
  assert.equal(verified.payload.exp - verified.payload.iat, 300);
  await assert.rejects(createAppleClientSecret({ teamId: 'bad', keyId: 'SYNTHETIC2', clientId, privateKey }), errorCode('APPLE_CONFIGURATION_ERROR'));
});

test('disabled adapter performs no challenge consumption or network call', async () => {
  const f = await setup({ enabled: false });
  await assert.rejects(f.adapter.verifyNativeAuthorization(f.request), errorCode('APPLE_SIGNIN_DISABLED'));
  assert.equal(f.calls.length, 0);
});

test('native token and exchanged token bind to one verified subject without trusting email or client owner ID', async () => {
  const f = await setup({ nativeClaims: { email: 'old@invalid', ownerID: 'attacker' },
    exchangeClaims: { email: 'new@invalid' } });
  assert.deepEqual(await f.adapter.verifyNativeAuthorization({ ...f.request, ownerID: 'attacker', nonce: 'forged' }),
    { issuer: APPLE_ISSUER, subject: 'person-a', refreshToken: 'synthetic-refresh' });
  assert.deepEqual(f.calls.map((x) => x.url), [APPLE_KEYS_URL, APPLE_TOKEN_URL]);
});

for (const [name, nativeClaims] of [
  ['nonce', { nonce: 'wrong' }], ['issuer', { iss: 'https://wrong.invalid' }],
  ['audience', { aud: 'other-client' }], ['expiry', { exp: START / 1000 }],
  ['authorization code hash', { c_hash: 'wrong' }],
]) {
  test(`invalid native ${name} never reaches code exchange`, async () => {
    const f = await setup({ nativeClaims });
    await assert.rejects(f.adapter.verifyNativeAuthorization(f.request), errorCode('APPLE_IDENTITY_UNCONFIRMED'));
    assert.equal(f.calls.filter((x) => x.url === APPLE_TOKEN_URL).length, 0);
  });
}

test('untrusted signing key fails closed', async () => {
  const f = await setup({ signer: unrelatedSigner });
  await assert.rejects(f.adapter.verifyNativeAuthorization(f.request), errorCode('APPLE_IDENTITY_UNCONFIRMED'));
  assert.equal(f.calls.filter((x) => x.url === APPLE_TOKEN_URL).length, 0);
});

for (const [name, exchangeClaims, expected] of [
  ['other subject', { sub: 'person-b' }, 'APPLE_IDENTITY_MISMATCH'],
  ['other nonce', { nonce: 'other-flow' }, 'APPLE_IDENTITY_UNCONFIRMED'],
  ['missing nonce', { nonce: undefined }, 'APPLE_IDENTITY_UNCONFIRMED'],
  ['other audience', { aud: 'other-client' }, 'APPLE_IDENTITY_UNCONFIRMED'],
]) {
  test(`exchanged token with ${name} cannot authenticate the user`, async () => {
    const f = await setup({ exchangeClaims });
    await assert.rejects(f.adapter.verifyNativeAuthorization(f.request), errorCode(expected));
  });
}

test('challenge replay and concurrent completion are rejected', async () => {
  const f = await setup();
  const results = await Promise.allSettled([f.adapter.verifyNativeAuthorization(f.request), f.adapter.verifyNativeAuthorization(f.request)]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(results.find((r) => r.status === 'rejected').reason.code, 'APPLE_AUTHORIZATION_REJECTED');
  assert.equal(f.calls.filter((x) => x.url === APPLE_TOKEN_URL).length, 1);
});

test('wrong proof and expired challenge never reach Apple', async () => {
  const f = await setup();
  await assert.rejects(f.adapter.verifyNativeAuthorization({ ...f.request, challengeProof: 'wrong' }), errorCode('APPLE_AUTHORIZATION_REJECTED'));
  f.advance(300_000);
  await assert.rejects(f.adapter.verifyNativeAuthorization(f.request), errorCode('APPLE_AUTHORIZATION_REJECTED'));
  assert.equal(f.calls.length, 0);
});

test('challenge expiring during exchange cannot produce success', async () => {
  const f = await setup({ duringExchange: (advance) => advance(300_000),
    nativeClaims: { exp: START / 1000 + 3600 }, exchangeClaims: { exp: START / 1000 + 3600 } });
  await assert.rejects(f.adapter.verifyNativeAuthorization(f.request), errorCode('APPLE_AUTHORIZATION_REJECTED'));
});

for (const [status, oauthError, expected] of [
  [400, 'invalid_grant', 'APPLE_AUTHORIZATION_REJECTED'],
  [400, 'invalid_client', 'APPLE_CONFIGURATION_ERROR'],
  [429, 'rate_limited', 'APPLE_UNAVAILABLE'],
  [503, 'server_error', 'APPLE_UNAVAILABLE'],
]) {
  test(`Apple ${status}/${oauthError} is not a verified identity`, async () => {
    const f = await setup({ status, oauthError });
    await assert.rejects(f.adapter.verifyNativeAuthorization(f.request), errorCode(expected));
  });
}

test('network errors are sanitized and failed flow cannot be replayed', async () => {
  const f = await setup({ networkError: true });
  await assert.rejects(f.adapter.verifyNativeAuthorization(f.request), errorCode('APPLE_UNAVAILABLE'));
  await assert.rejects(f.adapter.verifyNativeAuthorization(f.request), errorCode('APPLE_AUTHORIZATION_REJECTED'));
});

test('unavailable public keys, incomplete token response, and oversized response do not authorize', async () => {
  for (const [overrides, expected] of [
    [{ keysUnavailable: true }, 'APPLE_IDENTITY_UNCONFIRMED'],
    [{ responseFields: { refresh_token: undefined } }, 'APPLE_RESPONSE_INVALID'],
    [{ hugeResponse: true }, 'APPLE_RESPONSE_INVALID'],
  ]) {
    const f = await setup(overrides);
    await assert.rejects(f.adapter.verifyNativeAuthorization(f.request), errorCode(expected));
  }
});
