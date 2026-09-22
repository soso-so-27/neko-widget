import { setImmediate } from 'node:timers/promises';
import { validateJPEG } from './decoder.js';
import { BODY_TIMEOUT_MS, MAX_BASE64_LENGTH, MAX_BODY_CHUNKS, MAX_PHOTO_BYTES, MAX_REQUEST_BYTES } from './limits.js';

class InvalidRequest extends Error {}
const json = (value: unknown, status = 200) => Response.json(value, {
  status, headers: { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' },
});
const unavailable = () => json({ error: { code: 'DEPENDENCY_UNAVAILABLE' } }, 503);

async function readPhoto(request: Request, signal: AbortSignal, deadline: number): Promise<Uint8Array> {
  if (!request.body || !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers.get('content-type') ?? '')
    || request.headers.has('content-encoding')) throw new InvalidRequest();
  const declared = request.headers.get('content-length');
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_REQUEST_BYTES)) throw new InvalidRequest();
  const reader = request.body.getReader();
  const cancel = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener('abort', cancel, { once: true });
  const parts: Uint8Array[] = [];
  let length = 0, chunks = 0;
  try {
    if (signal.aborted) throw new Error('aborted');
    while (true) {
      const part = await reader.read();
      // Ready streams can starve timers with a chain of resolved promises.
      if (signal.aborted || performance.now() >= deadline) { cancel(); throw new Error('aborted'); }
      if (part.done) break;
      length += part.value.length;
      if (++chunks > MAX_BODY_CHUNKS || length > MAX_REQUEST_BYTES) { cancel(); throw new InvalidRequest(); }
      if (part.value.length) parts.push(part.value);
      if (chunks % 64 === 0) await setImmediate();
    }
    const bytes = new Uint8Array(length);
    let at = 0;
    for (const part of parts) { bytes.set(part, at); at += part.length; }
    let value: unknown;
    try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
    catch { throw new InvalidRequest(); }
    if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 1
      || !('photoBase64' in value) || typeof value.photoBase64 !== 'string') throw new InvalidRequest();
    const encoded = value.photoBase64;
    if (encoded.length < 4 || encoded.length > MAX_BASE64_LENGTH || encoded.length % 4 !== 0
      || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) throw new InvalidRequest();
    const photo = Buffer.from(encoded, 'base64');
    if (photo.length > MAX_PHOTO_BYTES || photo.toString('base64') !== encoded) throw new InvalidRequest();
    return photo;
  } finally {
    signal.removeEventListener('abort', cancel);
    reader.releaseLock();
  }
}

/** Private-node provider contract; not a public endpoint or a deployed Worker. */
export function createImageValidator({ enabled = false }: { enabled?: boolean } = {}) {
  // No waiting queue: this includes request-body reads, not only native decoding.
  let busy = false;
  return {
    async fetch(request: Request): Promise<Response> {
      if (!enabled || busy || request.signal.aborted) return unavailable();
      const url = new URL(request.url);
      if (url.pathname !== '/images/validate-jpeg' || url.search) return json({ error: { code: 'NOT_FOUND' } }, 404);
      if (request.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405);
      busy = true;
      const bodyController = new AbortController();
      const cancelBody = () => bodyController.abort();
      request.signal.addEventListener('abort', cancelBody, { once: true });
      const timer = setTimeout(cancelBody, BODY_TIMEOUT_MS);
      try {
        const photo = await readPhoto(request, bodyController.signal, performance.now() + BODY_TIMEOUT_MS);
        clearTimeout(timer);
        const valid = await validateJPEG(photo, request.signal);
        return json(valid ? { valid: true, mediaType: 'image/jpeg', frames: 1 } : { valid: false });
      } catch (error) {
        return error instanceof InvalidRequest
          ? json({ error: { code: 'INVALID_REQUEST' } }, 400) : unavailable();
      } finally {
        clearTimeout(timer);
        request.signal.removeEventListener('abort', cancelBody);
        busy = false;
      }
    },
  };
}
