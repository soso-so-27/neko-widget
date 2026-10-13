import { expect, it } from 'vitest';
import { readPhotoUploadJSON, readRequestJSON } from '../src/request-json';

const request = (body: ReadableStream<Uint8Array>, signal?: AbortSignal) =>
  new Request('https://preservation.test/v1/records/example', { method: 'PUT',
    headers: { 'content-type': 'application/json' }, body, ...(signal ? { signal } : {}) });

it('accepts fragmented photo JSON beyond the control-request chunk limit without changing its content', async () => {
  const photoBase64 = 'A'.repeat(5 * 1024 * 1024);
  const document = { text: 'ねこ🐈', catNames: [] };
  const bytes = new TextEncoder().encode(JSON.stringify({ photoBase64, document }));
  const input = () => {
    let offset = 0;
    return new ReadableStream<Uint8Array>({ pull(controller) {
      if (offset === bytes.length) { controller.close(); return; }
      const end = Math.min(offset + 1024, bytes.length);
      controller.enqueue(bytes.subarray(offset, end)); offset = end;
    } });
  };
  await expect(readRequestJSON(request(input()), bytes.length)).rejects.toMatchObject({ code: 'INVALID_REQUEST' });
  expect(await readPhotoUploadJSON(request(input()), bytes.length)).toEqual({ photoBase64, document });
});

it('accepts a valid upload taking longer than the old five-second deadline in the real runtime', async () => {
  const bytes = new TextEncoder().encode('{"text":"写真","photoBase64":"AAAA"}');
  let position = 0;
  const input = new ReadableStream<Uint8Array>({ async pull(controller) {
    if (position === 3) { controller.close(); return; }
    await new Promise(resolve => setTimeout(resolve, 2000));
    const end = position === 2 ? bytes.length : (position + 1) * 10;
    controller.enqueue(bytes.subarray(position * 10, end)); position++;
  } }, { highWaterMark: 0 });
  expect(await readPhotoUploadJSON(request(input), bytes.length)).toEqual({ text: '写真', photoBase64: 'AAAA' });
}, 10_000);

it('photo upload cancellation settles without waiting for an uncooperative source', async () => {
  const abort = new AbortController(); let cancelled = false;
  const input = new ReadableStream<Uint8Array>({ cancel() { cancelled = true; return new Promise(() => {}); } });
  const pending = readPhotoUploadJSON(request(input, abort.signal), 1024);
  const rejected = expect(pending).rejects.toMatchObject({ code: 'INVALID_REQUEST' });
  abort.abort(); await rejected;
  expect(cancelled).toBe(true); expect(input.locked).toBe(false);
});
