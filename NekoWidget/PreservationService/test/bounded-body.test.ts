import { expect, it } from 'vitest';
import { readBoundedBody } from '../src/bounded-body';
import { ServiceError } from '../src/contracts';
const error = () => new ServiceError('BODY_UNAVAILABLE', 503);
it('assembles bounded streams, preserving byte order and using the exact limit', async () => {
  const body = new ReadableStream<Uint8Array>({ start(controller) {
    controller.enqueue(new Uint8Array([1])); controller.enqueue(new Uint8Array());
    controller.enqueue(new Uint8Array([2, 3])); controller.close();
  } });
  expect(await readBoundedBody(body, 3, error)).toEqual(new Uint8Array([1, 2, 3]));
});
it('rejects too many empty chunks and oversized input and cancels the source', async () => {
  let cancelled = false;
  const empty = new ReadableStream<Uint8Array>({ pull(controller) { controller.enqueue(new Uint8Array()); },
    cancel() { cancelled = true; } });
  await expect(readBoundedBody(empty, 1, error)).rejects.toMatchObject({ code: 'BODY_UNAVAILABLE' });
  expect(cancelled).toBe(true);
  await expect(readBoundedBody(new Response(new Uint8Array([1, 2])).body, 1, error, undefined,
    () => new ServiceError('TOO_LARGE', 413))).rejects.toMatchObject({ code: 'TOO_LARGE', status: 413 });
});
it('abort wakes a stalled read, releases the reader, and does not wait for a hostile cancel callback', async () => {
  let cancelled = false; const abort = new AbortController();
  const body = new ReadableStream<Uint8Array>({ cancel() { cancelled = true; return new Promise(() => {}); } });
  const result = readBoundedBody(body, 1, error, abort.signal);
  const rejected = expect(result).rejects.toMatchObject({ code: 'BODY_UNAVAILABLE' });
  abort.abort(); await rejected; expect(cancelled).toBe(true); expect(body.locked).toBe(false);
  await expect(readBoundedBody(new Response('x').body, 1, error, abort.signal)).rejects.toMatchObject({ code: 'BODY_UNAVAILABLE' });
});
it('keeps a bounded chunk override for native codecs without changing the network default', async () => {
  const chunks = () => new ReadableStream<Uint8Array>({ start(controller) {
    for (let i = 0; i < 4100; i++) controller.enqueue(new Uint8Array([1]));
    controller.close();
  } });
  await expect(readBoundedBody(chunks(), 4100, error)).rejects.toMatchObject({ code: 'BODY_UNAVAILABLE' });
  expect((await readBoundedBody(chunks(), 4100, error, undefined, error, 8192)).length).toBe(4100);
  for (const invalid of [0, -1, 1.5, 16_385, Infinity]) {
    await expect(readBoundedBody(new Response('x').body, 1, error, undefined, error, invalid))
      .rejects.toMatchObject({ code: 'BODY_UNAVAILABLE' });
  }
});
it('a never-ending stalled provider body is rejected by the real wall deadline', async () => {
  const body = new ReadableStream<Uint8Array>();
  await expect(readBoundedBody(body, 1, error)).rejects.toMatchObject({ code: 'BODY_UNAVAILABLE' });
  expect(body.locked).toBe(false);
}, 10_000);
