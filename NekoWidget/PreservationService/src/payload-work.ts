import { ServiceError } from './contracts';

/** Limits simultaneous large payloads in this isolate, not owners or authority.
 * Waiting retains no decoded payload. Callers must hold the permit until every
 * in-flight read has settled and the last output chunk has been consumed.
 */
export class PayloadWork {
  private active = false;
  private readonly waiting: (() => void)[] = [];
  async acquire(signal?: AbortSignal, waitMilliseconds = 30_000): Promise<() => void> {
    const busy = () => new ServiceError('PRESERVATION_BUSY', 503);
    if (signal?.aborted || this.waiting.length >= 16) throw busy();
    if (this.active) await new Promise<void>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout>;
      const clean = () => { clearTimeout(timer); signal?.removeEventListener('abort', abort); };
      const enter = () => { clean(); resolve(); };
      const abort = () => {
        const at = this.waiting.indexOf(enter);
        if (at < 0) return;
        this.waiting.splice(at, 1); clean(); reject(busy());
      };
      this.waiting.push(enter);
      timer = setTimeout(abort, waitMilliseconds);
      signal?.addEventListener('abort', abort, { once: true });
    });
    this.active = true;
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      const next = this.waiting.shift();
      if (next) next(); else this.active = false;
    };
    if (signal?.aborted) { release(); throw busy(); }
    return release;
  }
  async run<T>(operation: () => Promise<T>, signal?: AbortSignal): Promise<T> {
    const release = await this.acquire(signal);
    try { return await operation(); } finally { release(); }
  }
}

export const payloadWork = new PayloadWork();

/** Keep admission through response consumption. An abort never releases a
 * permit while the original operation/read is still holding a large payload.
 */
export async function payloadResponse(request: Request,
  operation: (signal: AbortSignal) => Promise<Response>): Promise<Response> {
  const release = await payloadWork.acquire(request.signal);
  const signal = new AbortController();
  let pending = true, stopped = false;
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  let output: ReadableStreamDefaultController<Uint8Array> | undefined;
  const detach = () => { clearTimeout(timer); request.signal.removeEventListener('abort', stop); };
  const stop = () => {
    if (stopped) return;
    stopped = true; signal.abort(); detach();
    output?.error(new ServiceError('PRESERVATION_INTERRUPTED', 503));
    void reader?.cancel().catch(() => {});
    if (!pending) release();
  };
  const timer = setTimeout(stop, 120_000);
  request.signal.addEventListener('abort', stop, { once: true });
  try {
    if (request.signal.aborted) stop();
    if (stopped) throw new ServiceError('PRESERVATION_INTERRUPTED', 503);
    const result = await operation(signal.signal);
    pending = false;
    if (stopped) { await result.body?.cancel(); throw new ServiceError('PRESERVATION_INTERRUPTED', 503); }
    if (!result.body) { stopped = true; detach(); release(); return result; }
    reader = result.body.getReader();
    return new Response(new ReadableStream<Uint8Array>({
      start(controller) { output = controller; },
      async pull(controller) {
        pending = true;
        try {
          const piece = await reader!.read();
          if (stopped) return;
          if (piece.done) { stopped = true; detach(); controller.close(); }
          else controller.enqueue(piece.value);
        } catch (error) {
          if (!stopped) { stopped = true; detach(); controller.error(error); }
          await reader!.cancel().catch(() => {});
        } finally { pending = false; if (stopped) release(); }
      },
      async cancel() {
        stopped = true; signal.abort(); detach();
        await reader!.cancel().catch(() => {});
        if (!pending) release();
      },
    }, { highWaterMark: 0 }), { status: result.status, headers: result.headers });
  } catch (error) {
    pending = false; stopped = true; signal.abort(); detach(); release(); throw error;
  }
}
