import { describe, expect, it } from 'vitest';
import { S3RecoveryCopy, type RecoveryObject } from '../src/s3-recovery-copy';

const config = { enabled: 'YES', region: 'ap-northeast-1',
  bucket: 'neko-preservation-recovery', expectedAccountId: '111122223333',
  accessKeyId: 'AKIA1234567890EXAMPLE', secretAccessKey: 'synthetic-not-an-aws-secret' };
const key = 'recovery/v1/00000000-0000-4000-8000-000000000001/photo/00000000-0000-4000-8000-000000000002';
const ciphertext = new Uint8Array([11, 22, 33, 44, 55, 66]);
const failure = { code: 'RECOVERY_COPY_UNAVAILABLE', status: 503 };
async function reference(): Promise<RecoveryObject> {
  return { key, bytes: ciphertext.length, versionId: 'exact-v1',
    sha256: [...new Uint8Array(await crypto.subtle.digest('SHA-256', ciphertext))]
      .map(byte => byte.toString(16).padStart(2, '0')).join('') };
}
const response = (body: ReadableStream<Uint8Array>, extraHeaders = {}) =>
  new Response(body, { headers: { 'x-amz-version-id': 'exact-v1', ...extraHeaders } });
const transport = (reply: Response) => new S3RecoveryCopy(config, async () => reply);

describe('exact-size recovery-object reads', () => {
  it('returns verified bytes from sliced and empty chunks without changing the source buffers', async () => {
    const backing = new Uint8Array([99, ...ciphertext, 88]);
    const first = backing.subarray(1, 3); const second = backing.subarray(3, 7);
    const stream = new ReadableStream<Uint8Array>({ start(controller) {
      controller.enqueue(first); controller.enqueue(new Uint8Array());
      controller.enqueue(second); controller.close();
    } });
    const received = await transport(response(stream)).getVerified(await reference());
    expect(received).toEqual(ciphertext);
    expect(received.buffer).not.toBe(backing.buffer);
    expect(backing).toEqual(new Uint8Array([99, ...ciphertext, 88]));
    expect(first.byteLength).toBe(2); expect(second.byteLength).toBe(4);
    expect(stream.locked).toBe(false);
  });

  it('uses the actual bytes and expected reference, not an untrusted content-length header', async () => {
    const reply = response(new Response(ciphertext).body!, { 'content-length': '1' });
    expect(await transport(reply).getVerified(await reference())).toEqual(ciphertext);
  });

  it('rejects early EOF and same-size corruption even when headers claim the correct length', async () => {
    for (const bytes of [ciphertext.subarray(0, 5), new Uint8Array([11, 22, 33, 44, 55, 67])]) {
      const reply = response(new Response(bytes).body!, { 'content-length': String(ciphertext.length) });
      await expect(transport(reply).getVerified(await reference())).rejects.toMatchObject(failure);
    }
  });

  it('rejects surplus bytes immediately and does not wait for cancellation to resolve', async () => {
    let reads = 0; let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({ pull(controller) {
      reads += 1; controller.enqueue(new Uint8Array([...ciphertext, 77]));
    }, cancel() { cancelled = true; return new Promise(() => {}); } }, { highWaterMark: 0 });
    await expect(transport(response(stream)).getVerified(await reference())).rejects.toMatchObject(failure);
    expect(reads).toBe(1); expect(cancelled).toBe(true); expect(stream.locked).toBe(false);
  });

  it('requires EOF after the exact number of bytes, with the existing five-second wall deadline', async () => {
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({ start(controller) {
      controller.enqueue(ciphertext);
    }, cancel() { cancelled = true; return new Promise(() => {}); } });
    const item = await reference(); const start = performance.now();
    await expect(transport(response(stream)).getVerified(item)).rejects.toMatchObject(failure);
    expect(performance.now() - start).toBeGreaterThanOrEqual(4_900);
    expect(cancelled).toBe(true); expect(stream.locked).toBe(false);
  }, 10_000);

  it('counts empty chunks toward the existing 4096-chunk limit', async () => {
    let reads = 0; let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({ pull(controller) {
      reads += 1; controller.enqueue(new Uint8Array());
    }, cancel() { cancelled = true; } }, { highWaterMark: 0 });
    await expect(transport(response(stream)).getVerified(await reference())).rejects.toMatchObject(failure);
    expect(reads).toBe(4097); expect(cancelled).toBe(true); expect(stream.locked).toBe(false);
  });

  it('accepts exactly 4096 chunks including empty ones when EOF and checksum are valid', async () => {
    let reads = 0;
    const stream = new ReadableStream<Uint8Array>({ pull(controller) {
      reads += 1;
      if (reads < 4096) controller.enqueue(new Uint8Array());
      else if (reads === 4096) controller.enqueue(ciphertext);
      else controller.close();
    } }, { highWaterMark: 0 });
    expect(await transport(response(stream)).getVerified(await reference())).toEqual(ciphertext);
    expect(reads).toBe(4097); expect(stream.locked).toBe(false);
  });

  it('maps a failing source to the recovery error without accepting a partial object', async () => {
    let reads = 0;
    const stream = new ReadableStream<Uint8Array>({ pull(controller) {
      if (++reads === 1) controller.enqueue(ciphertext.subarray(0, 2));
      else controller.error(new Error('synthetic transport failure'));
    } });
    await expect(transport(response(stream)).getVerified(await reference())).rejects.toMatchObject(failure);
    expect(stream.locked).toBe(false);
  });

  it('keeps the 32 MiB reference limit and rejects invalid sizes before requesting or allocating', async () => {
    const item = await reference(); let calls = 0;
    const copy = new S3RecoveryCopy(config, async () => { calls += 1; throw new Error('must not fetch'); });
    for (const bytes of [0, -1, 1.5, NaN, Infinity, 32 * 1024 * 1024 + 1]) {
      await expect(copy.getVerified({ ...item, bytes })).rejects.toMatchObject(failure);
    }
    expect(calls).toBe(0);
  });

  it('rejects a different version before reading a matching-looking body', async () => {
    let reads = 0;
    const stream = new ReadableStream<Uint8Array>({ pull(controller) {
      reads += 1; controller.enqueue(ciphertext); controller.close();
    } }, { highWaterMark: 0 });
    await expect(transport(response(stream, { 'x-amz-version-id': 'wrong-v2' }))
      .getVerified(await reference())).rejects.toMatchObject(failure);
    expect(reads).toBe(0);
  });
});
