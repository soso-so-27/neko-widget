import { createHash, timingSafeEqual } from 'node:crypto';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { Readable } from 'node:stream';
import { createImageValidator } from './provider.js';

const secretPattern = /^[A-Za-z0-9_-]{43,128}$/u;
const errorBody = JSON.stringify({ error: { code: 'DEPENDENCY_UNAVAILABLE' } });

function unavailable(response: ServerResponse): void {
  if (response.destroyed) return;
  response.writeHead(503, { 'content-type': 'application/json', 'cache-control': 'no-store',
    'x-content-type-options': 'nosniff', connection: 'close' });
  response.end(errorBody);
}

function authorized(input: string | string[] | undefined, expectedDigest: Buffer): boolean {
  if (typeof input !== 'string' || !secretPattern.test(input)) return false;
  const digest = createHash('sha256').update(input, 'ascii').digest();
  return timingSafeEqual(digest, expectedDigest);
}

/** Container-local HTTP bridge. The Worker service binding is the only intended caller. */
export function createValidatorHTTPServer(secret: string) {
  if (!secretPattern.test(secret)) throw new Error('validator configuration invalid');
  const expectedDigest = createHash('sha256').update(secret, 'ascii').digest();
  const validator = createImageValidator({ enabled: true });
  const server = createServer(async (input: IncomingMessage, output: ServerResponse) => {
    output.shouldKeepAlive = false;
    if (!authorized(input.headers['x-neko-validator-secret'], expectedDigest)
        || input.url !== '/images/validate-jpeg' || input.method !== 'POST') {
      unavailable(output);
      return;
    }
    const abort = new AbortController();
    const onAbort = () => abort.abort();
    input.once('aborted', onAbort);
    output.once('close', onAbort);
    try {
      const headers = new Headers();
      for (const [name, value] of Object.entries(input.headers)) {
        if (name === 'x-neko-validator-secret' || value === undefined) continue;
        headers.set(name, Array.isArray(value) ? value.join(',') : value);
      }
      const body = Readable.toWeb(input) as ReadableStream<Uint8Array>;
      const request = new Request('http://validator.internal/images/validate-jpeg', {
        method: 'POST', headers, body, duplex: 'half', signal: abort.signal,
      } as RequestInit & { duplex: 'half' });
      const result = await validator.fetch(request);
      if (output.destroyed) return;
      output.statusCode = result.status;
      result.headers.forEach((value, name) => output.setHeader(name, value));
      output.setHeader('connection', 'close');
      output.end(Buffer.from(await result.arrayBuffer()));
    } catch {
      unavailable(output);
    } finally {
      input.removeListener('aborted', onAbort);
      output.removeListener('close', onAbort);
    }
  });
  server.headersTimeout = 5_000;
  server.requestTimeout = 12_000;
  server.maxRequestsPerSocket = 1;
  return server;
}
