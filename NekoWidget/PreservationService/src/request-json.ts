/// <reference lib="es2024.arraybuffer" />
import { ServiceError } from './contracts';
import { readBoundedBody, type BodyReadPolicy } from './bounded-body';

export async function readRequestJSON(request: Request, maximum: number): Promise<Record<string, unknown>> {
  return parseRequestJSON(request, maximum);
}

// Only authenticated photo PUTs use this transfer budget. Provider responses
// and small control requests keep their existing five-second/chunk limits.
export async function readPhotoUploadJSON(request: Request, maximum: number): Promise<Record<string, unknown>> {
  return parseRequestJSON(request, maximum,
    { totalMilliseconds: 60_000, idleMilliseconds: 5000, progressChunkBytes: 512 });
}

async function parseRequestJSON(request: Request, maximum: number, policy?: BodyReadPolicy): Promise<Record<string, unknown>> {
  if (request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/json' || !request.body) {
    throw new ServiceError('INVALID_REQUEST');
  }
  try {
    const merged = await readBoundedBody(request.body, maximum, () => new ServiceError('INVALID_REQUEST'), request.signal,
      () => new ServiceError('REQUEST_TOO_LARGE', 413), 4096, policy);
    const text = new TextDecoder('utf-8', { fatal: true }).decode(merged);
    // readBoundedBody creates a dedicated buffer. Release it before JSON.parse allocates
    // the photo's base64 string; never detach buffers owned by the incoming stream.
    (merged.buffer as ArrayBuffer).transfer(0);
    const parsed: unknown = JSON.parse(text);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error();
    return parsed as Record<string, unknown>;
  } catch (error) {
    if (error instanceof ServiceError) throw error;
    throw new ServiceError('INVALID_REQUEST');
  }
}
