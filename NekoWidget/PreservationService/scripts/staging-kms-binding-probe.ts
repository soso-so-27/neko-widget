// Local-only diagnostic entrypoint. Run with --ip 127.0.0.1 and the dedicated
// probe config; never deploy it. The remote service binding reaches the private
// KMS Worker, while that Worker still authenticates the caller token itself.
interface Env { KEY_WRAPPER: Fetcher }

const localOnly = (url: URL): boolean => ['127.0.0.1', 'localhost'].includes(url.hostname) && !url.search;
const tokenPattern = /^[A-Za-z0-9_-]{43,128}$/u;
const headers = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };

async function syntheticRoundTrip(env: Env, token: string): Promise<Response> {
  const raw = crypto.getRandomValues(new Uint8Array(32));
  const contextSHA256 = Array.from(crypto.getRandomValues(new Uint8Array(32)), byte =>
    byte.toString(16).padStart(2, '0')).join('');
  const key = btoa(String.fromCharCode(...raw));
  const call = (path: string, body: object) => env.KEY_WRAPPER.fetch(
    new Request(`https://preservation-internal${path}`, {
      method: 'POST', headers: { 'content-type': 'application/json',
        'x-neko-preservation-key-token': token }, body: JSON.stringify(body),
    }));
  try {
    const wrapped = await call('/keys/wrap', { version: 1, key, contextSHA256 });
    if (wrapped.status !== 200) return new Response(`KMS wrap failed (${wrapped.status})`, { status: 503, headers });
    const result: unknown = await wrapped.json();
    if (!result || typeof result !== 'object' || !('keyId' in result) || !('wrappedKey' in result)
      || typeof result.keyId !== 'string' || typeof result.wrappedKey !== 'string') throw new Error();
    const opened = await call('/keys/unwrap', { version: 1, keyId: result.keyId,
      wrappedKey: result.wrappedKey, contextSHA256 });
    if (opened.status !== 200) return new Response(`KMS unwrap failed (${opened.status})`, { status: 503, headers });
    const roundTrip: unknown = await opened.json();
    if (!roundTrip || typeof roundTrip !== 'object' || !('key' in roundTrip)
      || roundTrip.key !== key) throw new Error();
    return new Response('KMS_SYNTHETIC_ROUND_TRIP_PASS', { headers });
  } catch { return new Response('KMS_SYNTHETIC_ROUND_TRIP_FAIL', { status: 503, headers }); }
  finally { raw.fill(0); }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (!localOnly(url)) return new Response(null, { status: 404 });
    if (request.method === 'GET' && url.pathname === '/') {
      return new Response('<!doctype html><meta charset="utf-8"><title>KMS staging probe</title>'
        + '<form method="post" action="/run" autocomplete="off">'
        + '<label>One-time caller token <input name="token" type="password" required></label>'
        + '<button type="submit">Run synthetic KMS round trip</button></form>',
      { headers: { ...headers, 'content-type': 'text/html; charset=utf-8',
        'content-security-policy': "default-src 'none'; form-action 'self'" } });
    }
    if (request.method === 'POST' && url.pathname === '/run') {
      if (request.headers.get('content-type')?.split(';')[0] !== 'application/x-www-form-urlencoded'
        || Number(request.headers.get('content-length') ?? 0) > 1024) return new Response(null, { status: 400 });
      const token = new URLSearchParams(await request.text()).get('token') ?? '';
      if (!tokenPattern.test(token)) return new Response(null, { status: 400 });
      return syntheticRoundTrip(env, token);
    }
    if (request.method !== 'POST'
      || !['/keys/wrap', '/keys/unwrap'].includes(url.pathname)) {
      return new Response(null, { status: 404 });
    }
    const token = request.headers.get('x-neko-preservation-key-token') ?? '';
    if (!tokenPattern.test(token)) {
      return new Response(null, { status: 503 });
    }
    return env.KEY_WRAPPER.fetch(new Request(`https://preservation-internal${url.pathname}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json',
        'x-neko-preservation-key-token': token },
      body: request.body,
      duplex: 'half',
    }));
  },
};
