import { randomBytes } from 'node:crypto';
import { createLocalJWKSet, jwtVerify } from 'jose';

// Offline experiment only: no Apple login, remote JWKS, or persistent sessions.
const CHALLENGE_MS = 5 * 60_000;
const SESSION_MS = 15 * 60_000;
const opaque = () => randomBytes(32).toString('base64url');

export class OfflineIdentityVerifier {
  #issuer; #audience; #keys; #now;
  #challenges = new Map();
  #sessions = new Map();

  constructor({ issuer, audience, jwks, now = () => Date.now() }) {
    if (typeof issuer !== 'string' || !issuer || typeof audience !== 'string' || !audience
        || typeof now !== 'function') throw new Error('Invalid verifier configuration');
    this.#issuer = issuer;
    this.#audience = audience;
    this.#keys = createLocalJWKSet(jwks);
    this.#now = now;
  }

  #time() {
    const time = this.#now();
    if (!Number.isSafeInteger(time) || time < 0) throw new Error('Invalid clock');
    for (const entries of [this.#challenges, this.#sessions]) {
      for (const [id, value] of entries) if (value.expiresAt <= time) entries.delete(id);
    }
    return time;
  }

  beginLogin() {
    const time = this.#time();
    if (this.#challenges.size >= 256) throw new Error('Too many pending logins');
    const challengeId = opaque();
    const nonce = opaque();
    this.#challenges.set(challengeId, { nonce, expiresAt: time + CHALLENGE_MS });
    return { challengeId, nonce };
  }

  async completeLogin({ challengeId, idToken }) {
    const time = this.#time();
    const challenge = this.#challenges.get(challengeId);
    // Consume before awaiting signature verification, including failed attempts.
    this.#challenges.delete(challengeId);
    if (!challenge || typeof idToken !== 'string' || idToken.length > 16_384) {
      throw new Error('Invalid login');
    }
    let payload;
    try {
      ({ payload } = await jwtVerify(idToken, this.#keys, {
        algorithms: ['RS256'], issuer: this.#issuer, audience: this.#audience,
        requiredClaims: ['iss', 'aud', 'exp', 'iat', 'nonce', 'sub'],
        maxTokenAge: CHALLENGE_MS / 1_000, clockTolerance: 0,
        currentDate: new Date(time),
      }));
    } catch {
      throw new Error('Invalid login');
    }
    const completedAt = this.#time();
    if (completedAt >= challenge.expiresAt
        || typeof payload.sub !== 'string' || !payload.sub.trim() || payload.sub.length > 255
        || payload.nonce !== challenge.nonce
        || !Number.isSafeInteger(payload.iat) || payload.iat < 0
        || !Number.isSafeInteger(payload.exp) || payload.exp <= payload.iat
        || payload.exp * 1_000 <= completedAt
        || this.#sessions.size >= 1_024) throw new Error('Invalid login');

    // An encoded JSON tuple is unambiguous; never concatenate iss/sub with a delimiter.
    // Email, device, billing status, and client-supplied owner IDs are NOT identity.
    const owner = `owner:v1:${Buffer.from(JSON.stringify([payload.iss, payload.sub])).toString('base64url')}`;
    const session = opaque();
    this.#sessions.set(session, { owner, expiresAt: completedAt + SESSION_MS });
    return session;
  }

  requireOwner(session) {
    this.#time();
    const entry = typeof session === 'string' ? this.#sessions.get(session) : undefined;
    if (!entry) throw new Error('Invalid session');
    return entry.owner;
  }
}
