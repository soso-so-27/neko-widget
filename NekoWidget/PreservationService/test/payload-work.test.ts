import { expect, it, vi } from 'vitest';
import { PayloadWork, payloadResponse, payloadWork } from '../src/payload-work';

const tick = () => new Promise(resolve => setTimeout(resolve, 5));
it('admits in FIFO order, bounds waiting, and removes aborted and timed-out waiters', async () => {
  const work = new PayloadWork(); const held = await work.acquire();
  const abort = new AbortController();
  const aborted = work.acquire(abort.signal); const rejected = expect(aborted).rejects.toMatchObject({ code: 'PRESERVATION_BUSY' });
  abort.abort(); await rejected;
  const timeout = work.acquire(undefined, 5);
  await expect(timeout).rejects.toMatchObject({ code: 'PRESERVATION_BUSY' });
  const order: number[] = [];
  const queued = Array.from({ length: 16 }, (_, index) => work.run(async () => { order.push(index); await tick(); }));
  await expect(work.acquire()).rejects.toMatchObject({ code: 'PRESERVATION_BUSY' });
  expect(order).toEqual([]); held(); held();
  await Promise.all(queued); expect(order).toEqual(Array.from({ length: 16 }, (_, index) => index));
  (await work.acquire())();
});

it('holds response admission after headers until consumption or cancellation', async () => {
  const reply = await payloadResponse(new Request('https://test'), async () => new Response('payload'));
  let entered = false;
  const next = payloadWork.run(async () => { entered = true; });
  await tick(); expect(entered).toBe(false);
  expect(await reply.text()).toBe('payload'); await next; expect(entered).toBe(true);
  const cancelled = await payloadResponse(new Request('https://test'), async () => new Response('payload'));
  await cancelled.body!.cancel();
  await expect(payloadWork.run(async () => 42)).resolves.toBe(42);
});

it('does not release an aborted operation until its large read actually settles', async () => {
  const abort = new AbortController(); let settle!: () => void, started!: () => void;
  const began = new Promise<void>(resolve => { started = resolve; });
  const delayed = new Promise<void>(resolve => { settle = resolve; });
  const reply = payloadResponse(new Request('https://test', { signal: abort.signal }), async () => {
    started(); await delayed; return new Response('private');
  });
  const failed = expect(reply).rejects.toMatchObject({ code: 'PRESERVATION_INTERRUPTED' });
  await began; abort.abort();
  let entered = false; const next = payloadWork.run(async () => { entered = true; });
  await tick(); expect(entered).toBe(false);
  settle(); await failed; await next; expect(entered).toBe(true);
});

it('interrupts an unconsumed response at its fixed deadline and admits the next request', async () => {
  vi.useFakeTimers();
  try {
    const reply = await payloadResponse(new Request('https://test'), async () => new Response('private'));
    await vi.advanceTimersByTimeAsync(119_000);
    let entered = false;
    const next = payloadWork.run(async () => { entered = true; });
    await vi.advanceTimersByTimeAsync(999); expect(entered).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    await expect(reply.text()).rejects.toMatchObject({ code: 'PRESERVATION_INTERRUPTED' });
    await next; expect(entered).toBe(true);
  } finally { vi.useRealTimers(); }
});
