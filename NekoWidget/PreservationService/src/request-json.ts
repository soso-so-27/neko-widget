/// <reference lib="es2024.arraybuffer" />
import { ServiceError } from './contracts';
import { readBoundedBody } from './bounded-body';

export async function readRequestJSON(request: Request, maximum: number): Promise<Record<string, unknown>> {
  if (request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/json' || !request.body) {
    throw new ServiceError('INVALID_REQUEST');
  }
  try {
    const merged = await readBoundedBody(request.body, maximum, () => new ServiceError('INVALID_REQUEST'), request.signal,
      () => new ServiceError('REQUEST_TOO_LARGE', 413));
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
