import { Buffer } from 'node:buffer';
import { expect, it } from 'vitest';
import { RecordFrame, recordResponse } from '../src/record-frame';
const document = { formatVersion: 1 as const, text: '写真🐈、日本語と改行\n引用"', capturedAt: null,
  writtenAt: null, updatedAt: null, catNames: ['ねこ'], photoFile: 'photo.jpg' };
const make = (photo: Uint8Array | null, text = document.text) => ({ recordId: '00000000-0000-4000-8000-000000000001',
  revision: 1, document: { ...document, text, photoFile: photo === null ? null : 'photo.jpg' as const }, photo, photoSHA256: null });

it('matches independent base64 encoding across padding and chunk/head alignment without widening metadata', async () => {
  for (const length of [0, 1, 2, 3, 8190, 8191, 8192, 2 * 1024 * 1024 + 1]) {
    const photo = Uint8Array.from({ length }, (_, index) => index % 256);
    for (const suffix of ['', 'a', 'ab', 'abc']) {
      const input = make(photo, document.text + suffix), frame = new RecordFrame(input, true);
      const chunks: Uint8Array[] = []; let bytes = 0;
      while (true) { const chunk = frame.next(); if (!chunk) break;
        expect(chunk.length).toBeGreaterThan(0); expect(chunk.length).toBeLessThanOrEqual(1024 * 1024);
        chunks.push(chunk); bytes += chunk.length;
      }
      expect(bytes).toBe(frame.byteLength);
      expect(frame.next()).toBeNull(); expect(frame.done).toBe(true);
      const output = Buffer.concat(chunks).toString('utf8'); expect(output.endsWith('\n')).toBe(true);
      const parsed = JSON.parse(output);
      expect(parsed).toEqual({ type: 'record', recordId: input.recordId, revision: 1,
        document: input.document, photoSHA256: null, photoBase64: Buffer.from(photo).toString('base64') });
    }
  }
});

it('preserves null-photo JSON and clears pending data on cancellation or failed validation', async () => {
  const abort = new AbortController(); let calls = 0;
  const response = recordResponse(make(null), async () => { calls++; }, abort.signal);
  expect(await response.json()).toMatchObject({ photoBase64: null, document: { photoFile: null } });
  expect(calls).toBe(1);
  const interrupted = recordResponse(make(new Uint8Array(2 * 1024 * 1024)), async () => {
    if (++calls > 2) throw new Error('revoked');
  }, abort.signal);
  const reader = interrupted.body!.getReader();
  expect((await reader.read()).value!.length).toBeLessThanOrEqual(1024 * 1024);
  await expect(reader.read()).rejects.toThrow('revoked');
  const cancelled = recordResponse(make(new Uint8Array(2 * 1024 * 1024)), async () => {}, abort.signal);
  await cancelled.body!.cancel();
  const cleared = new RecordFrame(make(new Uint8Array(2 * 1024 * 1024)));
  expect(cleared.next()).not.toBeNull(); cleared.clear();
  expect(cleared.next()).toBeNull(); expect(cleared.done).toBe(true);
});
