// Local-only browser bridge to the private remote staging Worker.
interface Env { RECOVERY_PROBE: Fetcher }
const headers = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };
const tokenPattern = /^[A-Za-z0-9_-]{43,128}$/u;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (!['127.0.0.1', 'localhost'].includes(url.hostname) || url.search) {
      return new Response(null, { status: 404 });
    }
    if (request.method === 'GET' && url.pathname === '/') {
      return new Response('<!doctype html><meta charset="utf-8"><title>S3 staging probe</title>'
        + '<form method="post" action="/run" autocomplete="off">'
        + '<label>One-time probe token <input name="token" type="password" required></label>'
        + '<button type="submit">Run synthetic S3 round trip</button></form>',
      { headers: { ...headers, 'content-type': 'text/html; charset=utf-8',
        'content-security-policy': "default-src 'none'; form-action 'self'" } });
    }
    if (request.method !== 'POST' || url.pathname !== '/run'
      || request.headers.get('content-type')?.split(';')[0] !== 'application/x-www-form-urlencoded'
      || Number(request.headers.get('content-length') ?? 0) > 1024) {
      return new Response(null, { status: 404 });
    }
    const token = new URLSearchParams(await request.text()).get('token') ?? '';
    if (!tokenPattern.test(token)) return new Response(null, { status: 400 });
    return env.RECOVERY_PROBE.fetch(new Request('https://preservation-internal/synthetic-s3-round-trip', {
      method: 'POST', headers: { 'x-neko-staging-s3-probe-token': token },
    }));
  },
};
