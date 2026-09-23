import { Container, getContainer } from '@cloudflare/containers';
import { WorkerEntrypoint } from 'cloudflare:workers';

const secretPattern = /^[A-Za-z0-9_-]{43,128}$/u;
const unavailable = () => Response.json({ error: { code: 'DEPENDENCY_UNAVAILABLE' } }, {
  status: 503, headers: { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' },
});

export class JPEGValidatorContainer extends Container {
  defaultPort = 8080;
  sleepAfter = '1m';
  enableInternet = false;
  envVars = { JPEG_VALIDATOR_ENABLED: 'YES', JPEG_VALIDATOR_CALLER_SECRET: this.env.JPEG_VALIDATOR_CALLER_SECRET };
}

/** Only this named service entrypoint can reach the decoder container. */
export class JPEGValidationService extends WorkerEntrypoint {
  async fetch(request) {
    const secret = this.env.JPEG_VALIDATOR_CALLER_SECRET;
    if (this.env.JPEG_VALIDATOR_ENABLED !== 'YES' || typeof secret !== 'string'
        || !secretPattern.test(secret) || request.signal.aborted) return unavailable();
    const url = new URL(request.url);
    if (url.pathname !== '/images/validate-jpeg' || url.search || request.method !== 'POST') return unavailable();
    const headers = new Headers(request.headers);
    headers.set('x-neko-validator-secret', secret);
    try {
      const container = getContainer(this.env.VALIDATOR_CONTAINER, 'private-jpeg-validator-v1');
      const response = await container.fetch(new Request(request, { headers }));
      const safe = new Headers(response.headers);
      safe.set('cache-control', 'no-store');
      safe.set('x-content-type-options', 'nosniff');
      return new Response(response.body, { status: response.status, headers: safe });
    } catch { return unavailable(); }
  }
}

// No public URL, even if workers_dev or a route is accidentally enabled later.
export default { fetch() { return new Response(null, { status: 404 }); } };
