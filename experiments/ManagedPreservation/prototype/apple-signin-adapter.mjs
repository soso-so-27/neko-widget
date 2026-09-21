// Prepared server adapter, not an exposed endpoint. Disabled by default.
// Never imported by the app/SharingService. Live credentials and services are not configured.
import { createHash } from 'node:crypto';
import { SignJWT, createRemoteJWKSet, customFetch, jwtVerify } from 'jose';

export const APPLE_ISSUER = 'https://appleid.apple.com';
export const APPLE_KEYS_URL = `${APPLE_ISSUER}/auth/keys`;
export const APPLE_TOKEN_URL = `${APPLE_ISSUER}/auth/token`;
const MAX_RESPONSE_BYTES = 65_536;
const MAX_TOKEN = 16_384;
const MAX_FLOW_MS = 300_000;
export class AppleSigninError extends Error {
  constructor(code) { super(code); this.name = 'AppleSigninError'; this.code = code; }
}
const fail = (code) => { throw new AppleSigninError(code); };
const bounded = (value, max) => typeof value === 'string' && value.length > 0 && value.length <= max;
const clientIDValid = (value) => bounded(value, 255) && /^[a-zA-Z0-9][a-zA-Z0-9.-]+$/.test(value);
const timeValue = (now) => {
  const value = now();
  if (!Number.isSafeInteger(value) || value < 0) fail('APPLE_CONFIGURATION_ERROR');
  return value;
};

// Only a server-held Sign in with Apple signing key may be passed here.
// 5 minutes is our short client-secret lifetime, not Apple's maximum lifetime.
export async function createAppleClientSecret({ teamId, keyId, clientId, privateKey, now = () => Date.now() }) {
  if (!/^[A-Z0-9]{10}$/.test(teamId ?? '') || !/^[A-Z0-9]{10}$/.test(keyId ?? '') || !clientIDValid(clientId)) {
    fail('APPLE_CONFIGURATION_ERROR');
  }
  const issuedAt = Math.floor(timeValue(now) / 1000);
  try {
    return await new SignJWT({})
      .setProtectedHeader({ alg: 'ES256', kid: keyId })
      .setIssuer(teamId).setSubject(clientId).setAudience(APPLE_ISSUER)
      .setIssuedAt(issuedAt).setExpirationTime(issuedAt + 300).sign(privateKey);
  } catch { fail('APPLE_CONFIGURATION_ERROR'); }
}

async function boundedBody(response) {
  if (!response.body) fail('APPLE_RESPONSE_INVALID');
  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > MAX_RESPONSE_BYTES) {
        await reader.cancel();
        fail('APPLE_RESPONSE_INVALID');
      }
      chunks.push(value);
    }
    return Buffer.concat(chunks).toString('utf8');
  } finally { reader.releaseLock(); }
}

export class PreparedAppleSigninAdapter {
  #enabled; #clientId; #secret; #takeChallenge; #fetch; #now; #keys;

  constructor({ enabled = false, clientId, getClientSecret, takeChallenge,
    fetchImpl = globalThis.fetch, now = () => Date.now() }) {
    this.#enabled = enabled === true;
    if (!clientIDValid(clientId) || typeof getClientSecret !== 'function' || typeof takeChallenge !== 'function'
      || typeof fetchImpl !== 'function' || typeof now !== 'function') fail('APPLE_CONFIGURATION_ERROR');
    this.#clientId = clientId;
    this.#secret = getClientSecret;
    this.#takeChallenge = takeChallenge;
    this.#fetch = fetchImpl;
    this.#now = now;
    // Fixed origin; never follow a token's jku/x5u or a client-provided key URL.
    this.#keys = createRemoteJWKSet(new URL(APPLE_KEYS_URL), {
      timeoutDuration: 5000, cooldownDuration: 30_000, cacheMaxAge: 600_000,
      [customFetch]: async (url, options) => {
        if (url !== APPLE_KEYS_URL) fail('APPLE_CONFIGURATION_ERROR');
        const response = await this.#fetch(url, { ...options, redirect: 'error', cache: 'no-store' });
        if (response.status !== 200) fail('APPLE_IDENTITY_UNCONFIRMED');
        return new Response(await boundedBody(response), { status: 200, headers: { 'content-type': 'application/json' } });
      },
    });
  }

  async #verifyToken(idToken, nonce, authorizationCode) {
    if (!bounded(idToken, MAX_TOKEN)) fail('APPLE_IDENTITY_UNCONFIRMED');
    try {
      const { payload } = await jwtVerify(idToken, this.#keys, {
        algorithms: ['RS256'], issuer: APPLE_ISSUER, audience: this.#clientId,
        requiredClaims: ['iss', 'aud', 'sub', 'exp', 'iat', 'nonce'],
        maxTokenAge: MAX_FLOW_MS / 1000, clockTolerance: 0, currentDate: new Date(timeValue(this.#now)),
      });
      if (payload.aud !== this.#clientId || !bounded(payload.sub, 255) || !payload.sub.trim()
        || payload.nonce !== nonce || !Number.isSafeInteger(payload.iat) || !Number.isSafeInteger(payload.exp)
        || payload.exp <= payload.iat || payload.exp * 1000 <= timeValue(this.#now)) fail('APPLE_IDENTITY_UNCONFIRMED');
      // OIDC code binding for RS256. The token endpoint may omit c_hash.
      if (payload.c_hash !== undefined) {
        const expected = createHash('sha256').update(authorizationCode, 'ascii').digest().subarray(0, 16).toString('base64url');
        if (payload.c_hash !== expected) fail('APPLE_IDENTITY_UNCONFIRMED');
      }
      return payload;
    } catch { fail('APPLE_IDENTITY_UNCONFIRMED'); }
  }

  async #exchangeCode(authorizationCode) {
    let clientSecret;
    try { clientSecret = await this.#secret(); } catch { fail('APPLE_CONFIGURATION_ERROR'); }
    if (!bounded(clientSecret, MAX_TOKEN)) fail('APPLE_CONFIGURATION_ERROR');
    const form = new URLSearchParams({ client_id: this.#clientId, client_secret: clientSecret,
      grant_type: 'authorization_code', code: authorizationCode });
    // Native app flow only: no redirect_uri unless the initial authorization used it.
    let response; let body;
    try {
      response = await this.#fetch(APPLE_TOKEN_URL, { method: 'POST', redirect: 'error', cache: 'no-store',
        headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
        body: form.toString(), signal: AbortSignal.timeout(5000) });
      if (response.status >= 500 || response.status === 429) fail('APPLE_UNAVAILABLE');
      body = JSON.parse(await boundedBody(response));
    } catch (error) {
      if (error instanceof AppleSigninError) throw error;
      fail('APPLE_UNAVAILABLE');
    }
    if (response.status === 400 && body?.error === 'invalid_grant') fail('APPLE_AUTHORIZATION_REJECTED');
    if (response.status === 400 && body?.error === 'invalid_client') fail('APPLE_CONFIGURATION_ERROR');
    if (response.status !== 200 || !body || body.error || body.token_type !== 'Bearer'
      || !bounded(body.id_token, MAX_TOKEN) || !bounded(body.refresh_token, MAX_TOKEN)
      || !bounded(body.access_token, MAX_TOKEN) || !Number.isSafeInteger(body.expires_in) || body.expires_in <= 0) {
      fail('APPLE_RESPONSE_INVALID');
    }
    return body;
  }

  async verifyNativeAuthorization({ challengeId, challengeProof, identityToken, authorizationCode }) {
    if (!this.#enabled) fail('APPLE_SIGNIN_DISABLED');
    if (!bounded(challengeId, 256) || !bounded(challengeProof, 256) || !bounded(identityToken, MAX_TOKEN)
      || !bounded(authorizationCode, 4096) || !/^[\x21-\x7e]+$/.test(authorizationCode)) fail('APPLE_AUTHORIZATION_REJECTED');
    let challenge;
    // Store contract: verify proof/flow binding and atomically consume even on a failed attempt.
    // No nonce, issuer, owner or callback URL is trusted from the client request.
    try { challenge = await this.#takeChallenge({ challengeId, challengeProof }); }
    catch { fail('APPLE_AUTHORIZATION_REJECTED'); }
    const started = timeValue(this.#now);
    if (!challenge || !bounded(challenge.nonce, 256) || !Number.isSafeInteger(challenge.createdAt)
      || !Number.isSafeInteger(challenge.expiresAt) || challenge.createdAt > started || challenge.createdAt < 0
      || challenge.expiresAt <= started || challenge.expiresAt <= challenge.createdAt
      || challenge.expiresAt - challenge.createdAt > MAX_FLOW_MS) fail('APPLE_AUTHORIZATION_REJECTED');
    const initial = await this.#verifyToken(identityToken, challenge.nonce, authorizationCode);
    const exchanged = await this.#exchangeCode(authorizationCode);
    const confirmed = await this.#verifyToken(exchanged.id_token, challenge.nonce, authorizationCode);
    if (confirmed.sub !== initial.sub) fail('APPLE_IDENTITY_MISMATCH');
    if (timeValue(this.#now) >= challenge.expiresAt) fail('APPLE_AUTHORIZATION_REJECTED');
    // Server-internal only. Encrypt/persist the refresh credential before issuing any session.
    // This result is NOT an HTTP response, a storage consent, or a subscription entitlement.
    return { issuer: APPLE_ISSUER, subject: confirmed.sub, refreshToken: exchanged.refresh_token };
  }
}
