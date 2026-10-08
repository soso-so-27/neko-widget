import { expect, it } from 'vitest';
import { boundPhotoValidator } from '../src/providers';
import { MAX_PHOTO_BYTES } from '../src/documents';

const accepted = () => Response.json({ valid: true, mediaType: 'image/jpeg', frames: 1 });

it('streams exact independent base64 JSON across block and padding boundaries, including 20 MiB', async () => {
  for (const length of [0, 1, 2, 3, 49151, 49152, 49153, MAX_PHOTO_BYTES]) {
    const photo = new Uint8Array(length);
    for (let i = 0; i < photo.length; i++) photo[i] = (i * 37 + (i >>> 8)) & 255;
    const expected = new TextEncoder().encode(JSON.stringify({ photoBase64: Buffer.from(photo).toString('base64') }));
    const originalHash = await crypto.subtle.digest('SHA-256', photo);
    let chunks = 0;
    const binding = { async fetch(url: string, init: RequestInit) {
      expect(url).toBe('https://preservation-internal/images/validate-jpeg');
      expect(init.method).toBe('POST'); expect(init.redirect).toBe('manual');
      expect(new Headers(init.headers).get('content-type')).toBe('application/json');
      expect(init.signal).toBeInstanceOf(AbortSignal);
      expect(init.body).toBeInstanceOf(ReadableStream);
      const reader = (init.body as ReadableStream<Uint8Array>).getReader(); let at = 0;
      try {
        while (true) {
          const next = await reader.read(); if (next.done) break;
          chunks++; expect(next.value.length).toBeLessThanOrEqual(64 * 1024);
          expect(Buffer.from(next.value).equals(Buffer.from(expected.subarray(at, at + next.value.length)))).toBe(true);
          at += next.value.length;
        }
      } finally { reader.releaseLock(); }
      expect(at).toBe(expected.length);
      return accepted();
    } } as unknown as Fetcher;
    expect(await boundPhotoValidator(binding).validateJPEG(photo)).toBe(true);
    expect(chunks).toBe(length ? Math.ceil(length / 49152) + 2 : 2);
    expect(await crypto.subtle.digest('SHA-256', photo)).toEqual(originalHash);
  }
}, 30_000);

it('does not eagerly read the photo and releases an unread rejected body without mutating caller bytes', async () => {
  const photo = new Uint8Array([1, 2, 3]); let reads = 0;
  const tracked = new Proxy(photo, { get(target, key) {
    if (key === 'subarray') return (...args: Parameters<Uint8Array['subarray']>) => { reads++; return target.subarray(...args); };
    return Reflect.get(target, key, target);
  } });
  let sent: ReadableStream<Uint8Array> | undefined;
  const binding = { async fetch(_url: string, init: RequestInit) {
    sent = init.body as ReadableStream<Uint8Array>;
    await new Promise(resolve => setTimeout(resolve, 0));
    expect(reads).toBe(0);
    return new Response(null, { status: 503 });
  } } as unknown as Fetcher;
  await expect(boundPhotoValidator(binding).validateJPEG(tracked)).rejects.toMatchObject({ code: 'DEPENDENCY_UNAVAILABLE' });
  expect((await sent!.getReader().read()).done).toBe(true);
  expect(photo).toEqual(new Uint8Array([1, 2, 3])); expect(reads).toBe(0);
});

it('retains provider rejection, redirect refusal, bounded response and JPEG-result checks', async () => {
  for (const reply of [() => new Response(null, { status: 302, headers: { location: 'https://other.invalid' } }),
    () => new Response('x'.repeat(4097)), () => new Response('[]'), () => new Response('{')]) {
    const binding = { fetch: async () => reply() } as unknown as Fetcher;
    await expect(boundPhotoValidator(binding).validateJPEG(new Uint8Array([1])))
      .rejects.toMatchObject({ code: 'DEPENDENCY_UNAVAILABLE', status: 503 });
  }
  for (const value of [{ valid: false }, { valid: true, mediaType: 'image/png', frames: 1 },
    { valid: true, mediaType: 'image/jpeg', frames: 2 }]) {
    const binding = { fetch: async () => Response.json(value) } as unknown as Fetcher;
    expect(await boundPhotoValidator(binding).validateJPEG(new Uint8Array([1]))).toBe(false);
  }
});

it('releases the photo after a locked provider returns early or throws', async () => {
  for (const throws of [false, true]) {
    const photo = new Uint8Array([1, 2, 3]);
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    const failure = new Error('provider disconnected');
    const binding = { async fetch(_url: string, init: RequestInit) {
      reader = (init.body as ReadableStream<Uint8Array>).getReader();
      expect(new TextDecoder().decode((await reader.read()).value)).toBe('{"photoBase64":"');
      if (throws) throw failure;
      return new Response(null, { status: 503 });
    } } as unknown as Fetcher;
    const result = boundPhotoValidator(binding).validateJPEG(photo);
    if (throws) await expect(result).rejects.toBe(failure);
    else await expect(result).rejects.toMatchObject({ code: 'DEPENDENCY_UNAVAILABLE' });
    expect((await reader!.read()).done).toBe(true); reader!.releaseLock();
    expect(photo).toEqual(new Uint8Array([1, 2, 3]));
  }
});
