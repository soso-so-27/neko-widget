import { createHash } from 'node:crypto';
import { env } from 'cloudflare:workers';
import { beforeAll, describe, expect, it } from 'vitest';
import { exportJWK, exportPKCS8, generateKeyPair, jwtVerify, SignJWT, type JSONWebKeySet, type JWTPayload } from 'jose';
import { APPLE_ISSUER, APPLE_KEYS_URL, APPLE_TOKEN_URL, AppleIdentityVerifier, createAppleClientSecret } from '../src/apple';
import { DurableAuth } from '../src/auth';
import { type AuthDependencies, randomToken } from '../src/contracts';

// Synthetic keys and injected transport only. These tests never contact Apple.
const START = Date.UTC(2026, 8, 22);
const clientId = 'invalid.synthetic.neko';
const db = (env as unknown as { DB: D1Database }).DB;
let signingKey: CryptoKey;
let jwks: JSONWebKeySet;
beforeAll(async () => {
  const pair = await generateKeyPair('RS256');
  signingKey = pair.privateKey;
  jwks = { keys: [{ ...await exportJWK(pair.publicKey), kid: 'synthetic-rsa', alg: 'RS256', use: 'sig' }] };
});
const signToken = (claims: JWTPayload): Promise<string> => new SignJWT({ iss: APPLE_ISSUER, aud: clientId,
  iat: START / 1000, exp: START / 1000 + 3600, sub: 'synthetic-person', ...claims })
  .setProtectedHeader({ alg: 'RS256', kid: 'synthetic-rsa' }).sign(signingKey);

interface Overrides {
  enabled?: boolean;
  nativeClaims?: JWTPayload;
  exchangeClaims?: JWTPayload;
  status?: number;
  oauthError?: string;
  huge?: 'keys' | 'token';
  responseFields?: Record<string, unknown>;
  throwTransport?: boolean;
  advanceDuringExchange?: number;
}
async function setup(overrides: Overrides = {}) {
  let time = START;
  const dependencies: AuthDependencies = { db, identityIndexSecret: 'B'.repeat(42) + 'A', now: () => time,
    keys: { seal: async () => { throw new Error('not used'); }, open: async () => { throw new Error('not used'); } } };
  const auth = new DurableAuth(dependencies);
  const challenge = await auth.issueChallenge();
  const authorizationCode = `synthetic-code-${randomToken()}`;
  const codeHash = Buffer.from(createHash('sha256').update(authorizationCode, 'ascii').digest()).subarray(0, 16).toString('base64url');
  const request = { challengeId: challenge.challengeId, challengeProof: challenge.challengeProof, authorizationCode,
    identityToken: await signToken({ nonce: challenge.nonce, c_hash: codeHash, ...overrides.nativeClaims }) };
  const calls: string[] = [];
  const adapter = new AppleIdentityVerifier({ clientId, ...(overrides.enabled === undefined ? {} : { enabled: overrides.enabled }),
    now: () => time, takeChallenge: (value) => auth.takeChallenge(value), getClientSecret: async () => 'synthetic-client-secret',
    fetchImpl: async (url, init) => {
      calls.push(url);
      expect(init.redirect).toBe('error');
      expect(init.cache).toBe('no-store');
      expect(init.signal).toBeDefined();
      if (url === APPLE_KEYS_URL) {
        expect(init.method).toBe('GET');
        return overrides.huge === 'keys' ? new Response('x'.repeat(65_537)) : Response.json(jwks);
      }
      expect(url).toBe(APPLE_TOKEN_URL);
      expect(init.method).toBe('POST');
      expect(new Headers(init.headers).get('content-type')).toBe('application/x-www-form-urlencoded');
      const form = new URLSearchParams(String(init.body));
      expect([...form.keys()].sort()).toEqual(['client_id', 'client_secret', 'code', 'grant_type']);
      expect(Object.fromEntries(form)).toEqual({ client_id: clientId, client_secret: 'synthetic-client-secret',
        code: authorizationCode, grant_type: 'authorization_code' });
      if (overrides.throwTransport) throw new Error('secret-provider-detail-must-not-escape');
      time += overrides.advanceDuringExchange ?? 0;
      if (overrides.status) return Response.json({ error: overrides.oauthError }, { status: overrides.status });
      if (overrides.huge === 'token') return new Response('x'.repeat(65_537));
      return Response.json({ token_type: 'Bearer', expires_in: 3600, access_token: 'synthetic-access',
        refresh_token: 'synthetic-refresh', id_token: await signToken({ nonce: challenge.nonce, ...overrides.exchangeClaims }),
        ...overrides.responseFields });
    },
  });
  return { adapter, auth, challenge, request, calls, advance: (ms: number) => { time += ms; } };
}

describe('Apple adapter production-candidate port', () => {
  it('imports a server PKCS8 key and creates the short ES256 client secret', async () => {
    const pair = await generateKeyPair('ES256', { extractable: true });
    const token = await createAppleClientSecret({ teamId: 'SYNTHETIC1', keyId: 'SYNTHETIC2', clientId,
      privateKey: await exportPKCS8(pair.privateKey), now: () => START });
    const result = await jwtVerify(token, pair.publicKey, { algorithms: ['ES256'], issuer: 'SYNTHETIC1',
      audience: APPLE_ISSUER, subject: clientId, currentDate: new Date(START) });
    expect(result.protectedHeader.kid).toBe('SYNTHETIC2');
    expect(result.payload.exp! - result.payload.iat!).toBe(300);
    await expect(createAppleClientSecret({ teamId: 'SYNTHETIC1', keyId: 'SYNTHETIC2', clientId,
      privateKey: 'invalid-private-material' })).rejects.toMatchObject({ code: 'APPLE_CONFIGURATION_ERROR', message: 'APPLE_CONFIGURATION_ERROR' });
  });

  it('defaults off without consuming a challenge or fetching anything', async () => {
    const f = await setup();
    await expect(f.adapter.verifyNativeAuthorization(f.request)).rejects.toMatchObject({ code: 'APPLE_SIGNIN_DISABLED', status: 503 });
    expect(f.calls).toEqual([]);
    expect((await f.auth.takeChallenge(f.challenge)).nonce).toBe(f.challenge.nonce);
  });

  it('binds native and exchanged identity with real D1 challenge consumption and fixed endpoints', async () => {
    const f = await setup({ enabled: true, nativeClaims: { email: 'old@invalid', ownerID: 'forged' }, exchangeClaims: { email: 'new@invalid' } });
    expect(await f.adapter.verifyNativeAuthorization(f.request)).toEqual({ issuer: APPLE_ISSUER,
      subject: 'synthetic-person', refreshToken: 'synthetic-refresh' });
    expect(f.calls).toEqual([APPLE_KEYS_URL, APPLE_TOKEN_URL]);
    await expect(f.adapter.verifyNativeAuthorization(f.request)).rejects.toMatchObject({ code: 'APPLE_AUTHORIZATION_REJECTED' });
  });

  it('exposes only an Apple-signed, verified email from the exchanged token', async () => {
    for (const verified of [true, 'true']) {
      const f = await setup({ enabled: true, nativeClaims: { email: 'person@privaterelay.appleid.com', email_verified: verified },
        exchangeClaims: { email: 'person@privaterelay.appleid.com', email_verified: verified } });
      expect(await f.adapter.verifyNativeAuthorization(f.request)).toMatchObject({
        subject: 'synthetic-person', verifiedEmail: 'person@privaterelay.appleid.com',
      });
    }
    for (const [nativeClaims, exchangeClaims] of [
      [{ email: 'forged@invalid', email_verified: true }, { email: 'real@example.com', email_verified: false }],
      [{ email: 'old@example.com', email_verified: true }, { email: 'new@example.com', email_verified: true }],
      [{}, { email: 'header\r\nBcc:evil@example.com', email_verified: true }],
    ] as const) {
      const f = await setup({ enabled: true, nativeClaims, exchangeClaims });
      expect(await f.adapter.verifyNativeAuthorization(f.request)).not.toHaveProperty('verifiedEmail');
    }
  });

  it('rejects native nonce/code substitution before exchange and consumes the failed attempt', async () => {
    for (const nativeClaims of [{ nonce: 'wrong-flow' }, { c_hash: 'wrong-code' }]) {
      const f = await setup({ enabled: true, nativeClaims });
      await expect(f.adapter.verifyNativeAuthorization(f.request)).rejects.toMatchObject({ code: 'APPLE_IDENTITY_UNCONFIRMED' });
      expect(f.calls).not.toContain(APPLE_TOKEN_URL);
      await expect(f.auth.takeChallenge(f.challenge)).rejects.toMatchObject({ code: 'unauthorized' });
    }
  });

  it('rejects exchanged identity or flow substitution including missing nonce', async () => {
    for (const [exchangeClaims, code] of [
      [{ sub: 'other-person' }, 'APPLE_IDENTITY_MISMATCH'],
      [{ nonce: 'other-flow' }, 'APPLE_IDENTITY_UNCONFIRMED'],
      [{ nonce: undefined }, 'APPLE_IDENTITY_UNCONFIRMED'],
      [{ aud: 'other-client' }, 'APPLE_IDENTITY_UNCONFIRMED'],
    ] as const) {
      const f = await setup({ enabled: true, exchangeClaims });
      await expect(f.adapter.verifyNativeAuthorization(f.request)).rejects.toMatchObject({ code, message: code });
    }
  });

  it('allows one concurrent completion and rejects wrong/expired proof before network', async () => {
    const f = await setup({ enabled: true });
    await expect(f.adapter.verifyNativeAuthorization({ ...f.request, challengeProof: 'wrong' })).rejects.toMatchObject({ code: 'APPLE_AUTHORIZATION_REJECTED' });
    expect(f.calls).toEqual([]);
    const outcomes = await Promise.allSettled([f.adapter.verifyNativeAuthorization(f.request), f.adapter.verifyNativeAuthorization(f.request)]);
    expect(outcomes.filter((result) => result.status === 'fulfilled')).toHaveLength(1);
    expect(f.calls.filter((url) => url === APPLE_TOKEN_URL)).toHaveLength(1);
    const expired = await setup({ enabled: true });
    expired.advance(300_000);
    await expect(expired.adapter.verifyNativeAuthorization(expired.request)).rejects.toMatchObject({ code: 'APPLE_AUTHORIZATION_REJECTED' });
    expect(expired.calls).toEqual([]);
  });

  it('keeps response size/schema and provider failure boundaries without leaking details', async () => {
    for (const [overrides, code] of [
      [{ huge: 'keys' }, 'APPLE_IDENTITY_UNCONFIRMED'],
      [{ huge: 'token' }, 'APPLE_RESPONSE_INVALID'],
      [{ responseFields: { refresh_token: null } }, 'APPLE_RESPONSE_INVALID'],
      [{ status: 400, oauthError: 'invalid_grant' }, 'APPLE_AUTHORIZATION_REJECTED'],
      [{ status: 400, oauthError: 'invalid_client' }, 'APPLE_CONFIGURATION_ERROR'],
      [{ status: 429, oauthError: 'secret-error-detail' }, 'APPLE_UNAVAILABLE'],
      [{ throwTransport: true }, 'APPLE_UNAVAILABLE'],
    ] as const) {
      const f = await setup({ enabled: true, ...overrides });
      await expect(f.adapter.verifyNativeAuthorization(f.request)).rejects.toMatchObject({ code, message: code });
    }
  });

  it('rejects a flow expiring during the code exchange rather than returning an identity', async () => {
    const f = await setup({ enabled: true, advanceDuringExchange: 300_000 });
    await expect(f.adapter.verifyNativeAuthorization(f.request)).rejects.toMatchObject({ code: 'APPLE_AUTHORIZATION_REJECTED' });
  });
});
