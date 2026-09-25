interface Env {
  ARCHIVE: R2Bucket;
}

const payload = 'neko-preservation-synthetic-r2-probe';

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (new URL(request.url).pathname === '/status' && request.method === 'GET') {
      const listed = await env.ARCHIVE.list({ prefix: 'probes/', limit: 1000 });
      return Response.json({ probeObjects: listed.objects.length, truncated: listed.truncated });
    }
    if (new URL(request.url).pathname !== '/probe' || request.method !== 'POST') {
      return new Response('Not found', { status: 404 });
    }

    const key = `probes/${crypto.randomUUID()}`;
    try {
      await env.ARCHIVE.put(key, payload);
      const copied = await env.ARCHIVE.get(key);
      if (!copied || await copied.text() !== payload) {
        return new Response('R2 readback failed', { status: 503 });
      }
      return new Response('R2 remote binding roundtrip PASS');
    } finally {
      await env.ARCHIVE.delete(key);
    }
  },
};
