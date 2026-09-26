interface Env {
  ARCHIVE: R2Bucket;
}

const payload = 'neko-preservation-synthetic-r2-probe';

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (new URL(request.url).pathname === '/status' && request.method === 'GET') {
      const listed = await env.ARCHIVE.list({ limit: 1000 });
      return Response.json({ objects: listed.objects.length, truncated: listed.truncated });
    }
    if (new URL(request.url).pathname === '/purge-probe' && request.method === 'POST') {
      const ownerId = crypto.randomUUID();
      const key = `personal/${ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`;
      try {
        const stored = await env.ARCHIVE.put(key, payload);
        if (!stored) throw Error('synthetic R2 put failed');
        try {
          await requestManifestPhotoDeletion(env.ARCHIVE, ownerId,
            { key, version: 'wrong-version', bytes: stored.size });
          throw Error('changed version was accepted');
        } catch (error) {
          if (!(error instanceof Error) || !('code' in error)
            || error.code !== 'R2_PHOTO_PURGE_UNAVAILABLE') throw error;
        }
        if (!(await env.ARCHIVE.head(key))) throw Error('wrong version removed object');
        const outcome = await requestManifestPhotoDeletion(env.ARCHIVE, ownerId,
          { key, version: stored.version, bytes: stored.size });
        const remaining = await env.ARCHIVE.list({ prefix: `personal/${ownerId}/`, limit: 10 });
        if (outcome !== 'deleted' || remaining.objects.length !== 0 || remaining.truncated) {
          throw Error('synthetic R2 owner prefix not empty');
        }
        return new Response('R2 synthetic exact-object purge PASS');
      } finally {
        await env.ARCHIVE.delete(key);
      }
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
import { requestManifestPhotoDeletion } from '../src/r2-photo-purge';
