// Local-only diagnostic entrypoint. Run with --ip 127.0.0.1 and the dedicated
// probe config; never deploy it. The remote service binding reaches the private
// KMS Worker, while that Worker still authenticates the caller token itself.
interface Env { KEY_WRAPPER: Fetcher }

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (!['127.0.0.1', 'localhost'].includes(url.hostname)
      || request.method !== 'POST' || url.search
      || !['/keys/wrap', '/keys/unwrap'].includes(url.pathname)) {
      return new Response(null, { status: 404 });
    }
    const token = request.headers.get('x-neko-preservation-key-token') ?? '';
    if (!/^[A-Za-z0-9_-]{43,128}$/u.test(token)) {
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
