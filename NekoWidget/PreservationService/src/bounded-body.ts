import { ServiceError } from './contracts';

// Bound bytes, empty chunks and wall time; don't trust a provider to close its body.
export async function readBoundedBody(body: ReadableStream<Uint8Array> | null, maximum: number,
  error: () => ServiceError, signal?: AbortSignal, tooLarge = error): Promise<Uint8Array> {
  if (!body || !Number.isSafeInteger(maximum) || maximum < 1 || signal?.aborted) throw error();
  const reader = body.getReader(); const chunks: Uint8Array[] = [];
  let size = 0; let count = 0; let timer: ReturnType<typeof setTimeout> | undefined;
  let abort: (() => void) | undefined;
  const until = performance.now() + 5000;
  const expired = new Promise<never>((_, reject) => {
    abort = () => { void reader.cancel().catch(() => {}); reject(error()); };
    timer = setTimeout(abort, 5000); signal?.addEventListener('abort', abort, { once: true });
  });
  try {
    while (true) {
      if (signal?.aborted || performance.now() >= until) throw error();
      const { value, done } = await Promise.race([reader.read(), expired]);
      if (done) break;
      if (++count > 4096 || !(value instanceof Uint8Array)) throw error();
      if ((size += value.length) > maximum) throw tooLarge();
      if (value.length) chunks.push(value);
      if (count % 64 === 0) await Promise.race([new Promise(resolve => setTimeout(resolve, 0)), expired]);
    }
    if (signal?.aborted || performance.now() >= until) throw error();
    const result = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
    return result;
  } catch (reason) { void reader.cancel().catch(() => {}); throw reason instanceof ServiceError ? reason : error(); }
  finally { clearTimeout(timer); if (abort) signal?.removeEventListener('abort', abort); reader.releaseLock(); }
}
