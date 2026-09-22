import { createHash } from 'node:crypto';
import { SignJWT, createRemoteJWKSet, customFetch, importPKCS8, jwtVerify } from 'jose';
import { type Challenge, type IdentityVerifier, type VerifiedIdentity, ServiceError } from './contracts';

export const APPLE_ISSUER = 'https://appleid.apple.com';
export const APPLE_KEYS_URL = `${APPLE_ISSUER}/auth/keys`;
export const APPLE_TOKEN_URL = `${APPLE_ISSUER}/auth/token`;
const MAX_RESPONSE_BYTES = 65_536;
const MAX_TOKEN = 16_384;
const MAX_FLOW_MS = 300_000;
const fail = (code: string): never => {
  const status = code === 'APPLE_CONFIGURATION_ERROR' || code === 'APPLE_UNAVAILABLE' || code === 'APPLE_SIGNIN_DISABLED'
    ? 503 : code === 'APPLE_RESPONSE_INVALID' ? 502 : 401;
  throw new ServiceError(code, status);
};
const bounded = (value: unknown, max: number): value is string =>
  typeof value === 'string' && value.length > 0 && value.length <= max;
const clientIDValid = (value: unknown): value is string =>
  bounded(value, 255) && /^[a-zA-Z0-9][a-zA-Z0-9.-]+$/u.test(value);
const timeValue = (now: () => number): number => {
  try {
    const value = now();
    if (!Number.isSafeInteger(value) || value < 0 || value > 8_640_000_000_000_000 - MAX_FLOW_MS) throw new Error();
    return value;
  } catch { return fail('APPLE_CONFIGURATION_ERROR'); }
};

// Only server configuration may supply this key. Our secret lives five minutes, not Apple's maximum.
export async function createAppleClientSecret({ teamId, keyId, clientId, privateKey, now = () => Date.now() }: {
  teamId: string; keyId: string; clientId: string; privateKey: CryptoKey | string; now?: () => number;
}): Promise<string> {
  if (!/^[A-Z0-9]{10}$/u.test(teamId) || !/^[A-Z0-9]{10}$/u.test(keyId) || !clientIDValid(clientId)) {
    return fail('APPLE_CONFIGURATION_ERROR');
  }
  const issuedAt = Math.floor(timeValue(now) / 1000);
  try {
    const key = typeof privateKey === 'string' ? await importPKCS8(privateKey, 'ES256') : privateKey;
    return await new SignJWT({}).setProtectedHeader({ alg: 'ES256', kid: keyId })
      .setIssuer(teamId).setSubject(clientId).setAudience(APPLE_ISSUER)
      .setIssuedAt(issuedAt).setExpirationTime(issuedAt + 300).sign(key);
  } catch { return fail('APPLE_CONFIGURATION_ERROR'); }
}

async function boundedBody(response: Response): Promise<string> {
  if (!response.body) return fail('APPLE_RESPONSE_INVALID');
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > MAX_RESPONSE_BYTES) {
        await reader.cancel();
        return fail('APPLE_RESPONSE_INVALID');
      }
      chunks.push(value);
    }
    return Buffer.concat(chunks).toString('utf8');
  } finally { reader.releaseLock(); }
}

interface AppleOptions {
  enabled?: boolean;
  clientId: string;
  getClientSecret: () => Promise<string>;
  takeChallenge: (input: { challengeId: string; challengeProof: string }) => Promise<Challenge>;
  fetchImpl?: (url: string, init: RequestInit) => Promise<Response>;
  now?: () => number;
}
interface TokenResponse { id_token: string; refresh_token: string; }

// Dedicated service adapter. No experiment imports, client-selected endpoints, or implicit activation.
export class AppleIdentityVerifier implements IdentityVerifier {
  private readonly enabled: boolean;
  private readonly now: () => number;
  private readonly fetchImpl: (url: string, init: RequestInit) => Promise<Response>;
  private readonly keys: ReturnType<typeof createRemoteJWKSet>;

  constructor(private readonly options: AppleOptions) {
    this.enabled = options.enabled === true;
    if (!clientIDValid(options.clientId) || typeof options.getClientSecret !== 'function'
        || typeof options.takeChallenge !== 'function') fail('APPLE_CONFIGURATION_ERROR');
    this.now = options.now ?? (() => Date.now());
    this.fetchImpl = options.fetchImpl ?? ((url, init) => globalThis.fetch(url, init));
    if (typeof this.now !== 'function' || typeof this.fetchImpl !== 'function') fail('APPLE_CONFIGURATION_ERROR');
    this.keys = createRemoteJWKSet(new URL(APPLE_KEYS_URL), {
      timeoutDuration: 5000, cooldownDuration: 30_000, cacheMaxAge: 600_000,
      [customFetch]: async (url, init) => {
        if (url !== APPLE_KEYS_URL) return fail('APPLE_CONFIGURATION_ERROR');
        const response = await this.fetchImpl(url, { ...init, redirect: 'error', cache: 'no-store' });
        if (response.status !== 200) return fail('APPLE_IDENTITY_UNCONFIRMED');
        return new Response(await boundedBody(response), { status: 200,
          headers: { 'content-type': 'application/json' } });
      },
    });
  }

  private async verifyToken(idToken: string, nonce: string, authorizationCode: string): Promise<string> {
    if (!bounded(idToken, MAX_TOKEN)) return fail('APPLE_IDENTITY_UNCONFIRMED');
    try {
      const { payload } = await jwtVerify(idToken, this.keys, {
        algorithms: ['RS256'], issuer: APPLE_ISSUER, audience: this.options.clientId,
        requiredClaims: ['iss', 'aud', 'sub', 'exp', 'iat', 'nonce'],
        maxTokenAge: MAX_FLOW_MS / 1000, clockTolerance: 0, currentDate: new Date(timeValue(this.now)),
      });
      if (payload.aud !== this.options.clientId || !bounded(payload.sub, 255) || !payload.sub.trim()
          || payload.nonce !== nonce || typeof payload.iat !== 'number' || !Number.isSafeInteger(payload.iat)
          || typeof payload.exp !== 'number' || !Number.isSafeInteger(payload.exp)
          || payload.exp <= payload.iat || payload.exp * 1000 <= timeValue(this.now)) return fail('APPLE_IDENTITY_UNCONFIRMED');
      // Preserve the reviewed RS256 OIDC binding. c_hash may be absent; nonce never is optional here.
      if (payload.c_hash !== undefined) {
        const expected = Buffer.from(createHash('sha256').update(authorizationCode, 'ascii').digest()).subarray(0, 16).toString('base64url');
        if (payload.c_hash !== expected) return fail('APPLE_IDENTITY_UNCONFIRMED');
      }
      return payload.sub;
    } catch { return fail('APPLE_IDENTITY_UNCONFIRMED'); }
  }

  private async exchangeCode(authorizationCode: string): Promise<TokenResponse> {
    let clientSecret: string;
    try { clientSecret = await this.options.getClientSecret(); } catch { return fail('APPLE_CONFIGURATION_ERROR'); }
    if (!bounded(clientSecret, MAX_TOKEN)) return fail('APPLE_CONFIGURATION_ERROR');
    const form = new URLSearchParams({ client_id: this.options.clientId, client_secret: clientSecret,
      grant_type: 'authorization_code', code: authorizationCode });
    let response: Response;
    let body: unknown;
    try {
      response = await this.fetchImpl(APPLE_TOKEN_URL, { method: 'POST', redirect: 'error', cache: 'no-store',
        headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
        body: form.toString(), signal: AbortSignal.timeout(5000) });
      if (response.status >= 500 || response.status === 429) return fail('APPLE_UNAVAILABLE');
      body = JSON.parse(await boundedBody(response));
    } catch (error) {
      if (error instanceof ServiceError && ['APPLE_UNAVAILABLE', 'APPLE_RESPONSE_INVALID'].includes(error.code)) throw error;
      return fail('APPLE_UNAVAILABLE');
    }
    if (!body || typeof body !== 'object' || Array.isArray(body)) return fail('APPLE_RESPONSE_INVALID');
    const value = body as Record<string, unknown>;
    if (response.status === 400 && value.error === 'invalid_grant') return fail('APPLE_AUTHORIZATION_REJECTED');
    if (response.status === 400 && value.error === 'invalid_client') return fail('APPLE_CONFIGURATION_ERROR');
    if (response.status !== 200 || value.error || value.token_type !== 'Bearer'
        || !bounded(value.id_token, MAX_TOKEN) || !bounded(value.refresh_token, MAX_TOKEN)
        || !bounded(value.access_token, MAX_TOKEN) || typeof value.expires_in !== 'number'
        || !Number.isSafeInteger(value.expires_in) || value.expires_in <= 0) return fail('APPLE_RESPONSE_INVALID');
    return { id_token: value.id_token, refresh_token: value.refresh_token };
  }

  async verifyNativeAuthorization(input: {
    challengeId: string; challengeProof: string; identityToken: string; authorizationCode: string;
  }): Promise<VerifiedIdentity> {
    if (!this.enabled) return fail('APPLE_SIGNIN_DISABLED');
    const { challengeId, challengeProof, identityToken, authorizationCode } = input;
    if (!bounded(challengeId, 256) || !bounded(challengeProof, 256) || !bounded(identityToken, MAX_TOKEN)
        || !bounded(authorizationCode, 4096) || !/^[\x21-\x7e]+$/u.test(authorizationCode)) return fail('APPLE_AUTHORIZATION_REJECTED');
    let challenge: Challenge;
    try { challenge = await this.options.takeChallenge({ challengeId, challengeProof }); }
    catch { return fail('APPLE_AUTHORIZATION_REJECTED'); }
    const started = timeValue(this.now);
    if (!challenge || !bounded(challenge.nonce, 256) || !Number.isSafeInteger(challenge.createdAt)
        || !Number.isSafeInteger(challenge.expiresAt) || challenge.createdAt > started || challenge.createdAt < 0
        || challenge.expiresAt <= started || challenge.expiresAt <= challenge.createdAt
        || challenge.expiresAt - challenge.createdAt > MAX_FLOW_MS) return fail('APPLE_AUTHORIZATION_REJECTED');
    const initial = await this.verifyToken(identityToken, challenge.nonce, authorizationCode);
    const exchanged = await this.exchangeCode(authorizationCode);
    const confirmed = await this.verifyToken(exchanged.id_token, challenge.nonce, authorizationCode);
    if (confirmed !== initial) return fail('APPLE_IDENTITY_MISMATCH');
    if (timeValue(this.now) >= challenge.expiresAt) return fail('APPLE_AUTHORIZATION_REJECTED');
    // Server-internal result only; DurableAuth must seal the refresh credential before issuing a session.
    return { issuer: APPLE_ISSUER, subject: confirmed, refreshToken: exchanged.refresh_token };
  }
}
