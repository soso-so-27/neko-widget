import { expect, it } from 'vitest';
import { readRequestJSON } from '../src/request-json';
import { ServiceError } from '../src/contracts';
const encode = (text: string) => new TextEncoder().encode(text);
const request = (body: ReadableStream<Uint8Array> | string, signal?: AbortSignal, contentType = 'application/json') =>
  new Request('https://preservation.test/v1/records/example', { method: 'PUT', headers: { 'content-type': contentType },
    body, ...(signal ? { signal } : {}) });
const stream = (chunks: Uint8Array[]) => new ReadableStream<Uint8Array>({ start(controller) {
  for (const chunk of chunks) controller.enqueue(chunk); controller.close();
} });

it('preserves JSON semantics, split UTF-8/BOM and offset input buffers without detaching their source', async () => {
  const text = '\ufeff{"text":"ねこ🐈\\n窓辺","duplicate":1,"duplicate":2,"nested":{"a":[null,true]}}';
  const encoded = encode(text); const source = new Uint8Array(encoded.length + 6).fill(0xa7);
  source.set(encoded, 3); const original = source.slice();
  const chunks = Array.from({ length: encoded.length }, (_, index) => source.subarray(index + 3, index + 4));
  const input = stream(chunks);
  const parsed = await readRequestJSON(request(input, undefined, 'Application/JSON; charset=utf-8'), encoded.length);
  expect(parsed).toEqual({ text: 'ねこ🐈\n窓辺', duplicate: 2, nested: { a: [null, true] } });
  expect(source.byteLength).toBe(original.byteLength); expect(source).toEqual(original);
  expect(chunks.every(chunk => chunk.byteLength === 1)).toBe(true); expect(input.locked).toBe(false);
});

it.each(['', 'null', '[]', 'true', '12', '"photo"', '{"x":', '{"x":1,}', '{"x":"\\β"}'])(
  'rejects invalid JSON or non-object JSON: %s', async (body) => {
    await expect(readRequestJSON(request(body), 1024)).rejects.toMatchObject({ code: 'INVALID_REQUEST', status: 400 });
  });

it('requires a JSON body and preserves byte-limit and fatal UTF-8 failures', async () => {
  await expect(readRequestJSON(new Request('https://preservation.test'), 1024)).rejects.toMatchObject({ code: 'INVALID_REQUEST' });
  await expect(readRequestJSON(request('{}', undefined, 'text/plain'), 1024)).rejects.toMatchObject({ code: 'INVALID_REQUEST' });
  expect(await readRequestJSON(request('{}'), 2)).toEqual({});
  await expect(readRequestJSON(request('{}'), 1)).rejects.toMatchObject({ code: 'REQUEST_TOO_LARGE', status: 413 });
  for (const invalid of [new Uint8Array([0xff]), new Uint8Array([0xe3, 0x81])]) {
    await expect(readRequestJSON(request(stream([encode('{"x":"'), invalid, encode('"}')])), 1024))
      .rejects.toMatchObject({ code: 'INVALID_REQUEST' });
    await expect(readRequestJSON(request(stream([invalid, encode('{}')])), invalid.length))
      .rejects.toMatchObject({ code: 'REQUEST_TOO_LARGE', status: 413 });
  }
});

it('keeps chunk-limit precedence over size and cancels excessive input', async () => {
  let cancelled = false; let count = 0;
  const input = new ReadableStream<Uint8Array>({ pull(controller) {
    controller.enqueue(++count <= 4096 ? new Uint8Array() : encode('{}'));
  }, cancel() { cancelled = true; } });
  await expect(readRequestJSON(request(input), 1)).rejects.toMatchObject({ code: 'INVALID_REQUEST', status: 400 });
  expect(cancelled).toBe(true); expect(input.locked).toBe(false);
});

it('preserves transport errors before decoding and releases a stalled body on abort', async () => {
  let first = true;
  const failed = new ReadableStream<Uint8Array>({ pull(controller) {
    if (first) { first = false; controller.enqueue(new Uint8Array([0xff])); }
    else controller.error(new ServiceError('UPSTREAM_UNAVAILABLE', 503));
  } });
  await expect(readRequestJSON(request(failed), 1024)).rejects.toMatchObject({ code: 'UPSTREAM_UNAVAILABLE', status: 503 });
  const abort = new AbortController(); let cancelled = false;
  const input = new ReadableStream<Uint8Array>({ cancel() { cancelled = true; return new Promise(() => {}); } });
  const pending = readRequestJSON(request(input, abort.signal), 1024);
  const rejected = expect(pending).rejects.toMatchObject({ code: 'INVALID_REQUEST' });
  abort.abort(); await rejected; expect(cancelled).toBe(true); expect(input.locked).toBe(false);
});
