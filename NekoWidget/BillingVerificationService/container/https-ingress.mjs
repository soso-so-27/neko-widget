import { createRemoteJWKSet, customFetch, jwtVerify } from 'jose';
import { readBoundedBytes } from './nonce-ledger.mjs';

const issuerPattern = /^https:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.cloudflareaccess\.com$/u;
const audiencePattern = /^[a-f0-9]{64}$/u;
const deny = () => new Response(null, { status: 403, headers: { 'cache-control': 'no-store' } });
const resolvers = new Map();

function configuration(env) {
  if (env.BILLING_VERIFIER_HTTPS_ENABLED !== 'YES'
      || env.BILLING_VERIFIER_CONTAINER_ENABLED !== 'YES'
      || !['Production', 'Sandbox'].includes(env.BILLING_STORE_ENVIRONMENT)
      || !issuerPattern.test(env.BILLING_VERIFIER_ACCESS_ISSUER ?? '')
      || !audiencePattern.test(env.BILLING_VERIFIER_ACCESS_AUD ?? '')) throw new Error();
  const origin = new URL(env.BILLING_VERIFIER_HTTPS_ORIGIN);
  if (origin.protocol !== 'https:' || origin.origin !== env.BILLING_VERIFIER_HTTPS_ORIGIN
      || origin.username || origin.password || origin.port
      || !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$/u.test(origin.hostname)) throw new Error();
  return { origin: origin.origin, issuer: env.BILLING_VERIFIER_ACCESS_ISSUER,
    audience: env.BILLING_VERIFIER_ACCESS_AUD, environment: env.BILLING_STORE_ENVIRONMENT };
}

function keysFor(config) {
  // Trusted deployment configuration only. Never select issuer/JWKS from JWT.
  const cacheKey = JSON.stringify(config);
  if (resolvers.has(cacheKey)) return resolvers.get(cacheKey);
  if (resolvers.size >= 4) resolvers.delete(resolvers.keys().next().value);
  const url = `${config.issuer}/cdn-cgi/access/certs`;
  const keys = createRemoteJWKSet(new URL(url), {
    timeoutDuration: 3000, cooldownDuration: 30_000, cacheMaxAge: 300_000,
    [customFetch]: async (input, init) => {
      if (input !== url) throw new Error();
      const response = await fetch(input, { ...init, redirect: 'manual', cache: 'no-store' });
      if (response.status !== 200) throw new Error();
      const bytes = await readBoundedBytes(response, 65_536);
      const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
      if (!Array.isArray(value?.keys) || value.keys.length < 1 || value.keys.length > 8) throw new Error();
      return new Response(bytes, { headers: { 'content-type': 'application/json' } });
    },
  });
  resolvers.set(cacheKey, keys);
  return keys;
}

/** Public ingress authenticates Access before reading the billing body or
 * reaching HMAC/nonce/Container work. Nothing here authorizes a purchase. */
export async function authenticatedHTTPSFetch(request, env, paths, forward) {
  try {
    const config = configuration(env);
    const url = new URL(request.url);
    if (url.origin !== config.origin || request.method !== 'POST' || url.href.includes('?') || url.hash
        || url.username || url.password || !paths.has(url.pathname) || request.signal.aborted) return deny();
    const token = request.headers.get('cf-access-jwt-assertion');
    if (!token || token.length > 16_384 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u.test(token)) return deny();
    const { payload, protectedHeader } = await jwtVerify(token, keysFor(config), {
      algorithms: ['RS256'], issuer: config.issuer, audience: config.audience,
      requiredClaims: ['iss', 'aud', 'iat', 'exp'], clockTolerance: 0,
    });
    const now = Math.floor(Date.now() / 1000);
    if (typeof protectedHeader.kid !== 'string' || !protectedHeader.kid
        || !Number.isSafeInteger(payload.iat) || !Number.isSafeInteger(payload.exp)
        || payload.iat > now || payload.exp <= now || payload.exp <= payload.iat
        || !(payload.aud === config.audience
          || (Array.isArray(payload.aud) && payload.aud.length === 1 && payload.aud[0] === config.audience))) return deny();
    // Access credentials/assertions terminate here; the private hop uses HMAC.
    const headers = new Headers(request.headers);
    for (const name of ['cf-access-jwt-assertion', 'cf-access-client-id', 'cf-access-client-secret', 'cookie', 'authorization']) headers.delete(name);
    return await forward(new Request(request, { headers }), env);
  } catch { return deny(); }
}
