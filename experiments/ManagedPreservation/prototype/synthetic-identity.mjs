import { randomUUID } from 'node:crypto';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';

// TEST ONLY. Fresh synthetic RSA keys, not Apple keys or real Sign in with Apple.
export const SYNTHETIC_ISSUER = 'https://synthetic-identity.invalid';
export const SYNTHETIC_AUDIENCE = 'neko-preservation-offline-test';

export async function createSyntheticIdentity({
  issuer = SYNTHETIC_ISSUER, audience = SYNTHETIC_AUDIENCE, now = () => Date.now(),
} = {}) {
  const { privateKey, publicKey } = await generateKeyPair('RS256', { modulusLength: 2048 });
  const kid = `synthetic-${randomUUID()}`;
  const jwks = { keys: [{ ...await exportJWK(publicKey), kid, alg: 'RS256', use: 'sig' }] };
  const identity = {
    issuer, audience, jwks,
    // Overrides intentionally permit invalid claims for negative tests.
    signToken(claims = {}) {
      const issuedAt = Math.floor(now() / 1_000);
      return new SignJWT({ iss: issuer, aud: audience, iat: issuedAt, exp: issuedAt + 300,
        sub: 'synthetic-owner', ...claims })
        .setProtectedHeader({ alg: 'RS256', kid, typ: 'JWT' }).sign(privateKey);
    },
    login(verifier, claims = {}) { return login(verifier, identity, claims); },
  };
  return identity;
}

export async function login(verifier, identity, claims = {}) {
  const { challengeId, nonce } = verifier.beginLogin();
  const idToken = await identity.signToken({ ...claims, nonce });
  return verifier.completeLogin({ challengeId, idToken });
}
