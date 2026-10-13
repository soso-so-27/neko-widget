import { ServiceError } from './contracts';

export interface BodyReadPolicy {
  totalMilliseconds: number;
  idleMilliseconds: number;
  progressChunkBytes: number;
}

// Bound bytes, empty chunks and wall time; don't trust a provider to close its body.
export async function readBoundedBody(body: ReadableStream<Uint8Array> | null, maximum: number,
  error: () => ServiceError, signal?: AbortSignal, tooLarge = error,
  maximumChunks = 4096, policy?: BodyReadPolicy): Promise<Uint8Array> {
  if (!body || !Number.isSafeInteger(maximum) || maximum < 1 || signal?.aborted
    || !Number.isSafeInteger(maximumChunks) || maximumChunks < 1 || maximumChunks > 16_384
    || (policy && (!Number.isSafeInteger(policy.totalMilliseconds) || policy.totalMilliseconds < 1
      || policy.totalMilliseconds > 60_000 || !Number.isSafeInteger(policy.idleMilliseconds)
      || policy.idleMilliseconds < 1 || policy.idleMilliseconds > policy.totalMilliseconds
      || !Number.isSafeInteger(policy.progressChunkBytes) || policy.progressChunkBytes < 512))) throw error();
  const reader = body.getReader(); const chunks: Uint8Array[] = [];
  let size = 0; let count = 0; let emptyChunks = 0; let timer: ReturnType<typeof setTimeout> | undefined;
  let abort: (() => void) | undefined;
  const until = performance.now() + (policy?.totalMilliseconds ?? 5000);
  let idleUntil = policy ? performance.now() + policy.idleMilliseconds : until;
  const arm = () => {
    clearTimeout(timer);
    timer = setTimeout(() => abort?.(), Math.max(0, Math.min(until, idleUntil) - performance.now()));
  };
  const expired = new Promise<never>((_, reject) => {
    abort = () => { void reader.cancel().catch(() => {}); reject(error()); };
    arm(); signal?.addEventListener('abort', abort, { once: true });
  });
  try {
    while (true) {
      if (signal?.aborted || performance.now() >= Math.min(until, idleUntil)) throw error();
      const { value, done } = await Promise.race([reader.read(), expired]);
      if (signal?.aborted || performance.now() >= Math.min(until, idleUntil)) throw error();
      if (done) break;
      if (!(value instanceof Uint8Array)) throw error();
      // Transport fragmentation is not a size limit. Permit additional pieces
      // only in proportion to actual byte progress; tiny/empty floods stay finite.
      const credit = policy ? Math.floor(Math.min(maximum, size + value.length) / policy.progressChunkBytes) : 0;
      if (++count > maximumChunks + credit || (!value.length && ++emptyChunks > maximumChunks)) throw error();
      if ((size += value.length) > maximum) throw tooLarge();
      if (value.length) {
        chunks.push(value);
        if (policy) { idleUntil = performance.now() + policy.idleMilliseconds; arm(); }
      }
      if (count % 64 === 0) await Promise.race([new Promise(resolve => setTimeout(resolve, 0)), expired]);
    }
    if (signal?.aborted || performance.now() >= Math.min(until, idleUntil)) throw error();
    const result = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
    return result;
  } catch (reason) { void reader.cancel().catch(() => {}); throw reason instanceof ServiceError ? reason : error(); }
  finally { clearTimeout(timer); if (abort) signal?.removeEventListener('abort', abort); reader.releaseLock(); }
}
