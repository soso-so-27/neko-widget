import { expect, it } from 'vitest';
import { compressOwnerSnapshot, MAX_OWNER_SNAPSHOT_BYTES, openOwnerSnapshot } from '../src/owner-snapshot-codec';

const failure = { code: 'OWNER_RECOVERY_UNAVAILABLE', status: 503 };
const json = new TextEncoder().encode(JSON.stringify({ records: Array.from({ length: 200 },
  (_, id) => ({ id, revision: 1, deleted: false })) }));
async function frame(bytes: Uint8Array, declared = bytes.length): Promise<Uint8Array> {
  const gzip = new Uint8Array(await new Response(new Blob([bytes.slice()]).stream()
    .pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
  const result = new Uint8Array(8 + gzip.length);
  result.set([78, 75, 90, 49]);
  new DataView(result.buffer).setUint32(4, declared, false);
  result.set(gzip, 8);
  return result;
}

it('uses the Worker gzip runtime for lossless framed round trips', async () => {
  const compressed = await compressOwnerSnapshot(json);
  expect(compressed.slice(0, 4)).toEqual(new Uint8Array([78, 75, 90, 49]));
  expect(compressed.length).toBeLessThan(json.length / 2);
  expect(await openOwnerSnapshot(compressed)).toEqual(json);
  const offset = new Uint8Array(compressed.length + 9);
  offset.set(compressed, 9);
  expect(await openOwnerSnapshot(offset.subarray(9))).toEqual(json);
});

it('reads legacy JSON unchanged and avoids inflating small or incompressible writes', async () => {
  const small = new TextEncoder().encode('{"version":2}');
  const noise = crypto.getRandomValues(new Uint8Array(8192));
  expect(await openOwnerSnapshot(json)).toBe(json);
  expect(await compressOwnerSnapshot(small)).toBe(small);
  expect(await compressOwnerSnapshot(noise)).toBe(noise);
});

it('rejects empty and over-limit input before compression or parsing', async () => {
  for (const bytes of [new Uint8Array(), new Uint8Array(MAX_OWNER_SNAPSHOT_BYTES + 1)]) {
    await expect(compressOwnerSnapshot(bytes)).rejects.toMatchObject(failure);
    await expect(openOwnerSnapshot(bytes)).rejects.toMatchObject(failure);
  }
});

it('retains the existing maximum plaintext size after lossless expansion', async () => {
  const maximum = new Uint8Array(MAX_OWNER_SNAPSHOT_BYTES).fill(32);
  const compressed = await compressOwnerSnapshot(maximum);
  const opened = await openOwnerSnapshot(compressed);
  expect(opened.length).toBe(maximum.length);
  expect(opened.every(byte => byte === 32)).toBe(true);
});

it('rejects unknown versions, short headers and invalid declared lengths', async () => {
  const good = await frame(json);
  const unknown = good.slice(); unknown[3] = 50;
  for (const bad of [unknown, good.slice(0, 3), good.slice(0, 7), good.slice(0, 8)]) {
    await expect(openOwnerSnapshot(bad)).rejects.toMatchObject(failure);
  }
  for (const size of [0, MAX_OWNER_SNAPSHOT_BYTES + 1, 0xffff_ffff]) {
    const bad = good.slice(); new DataView(bad.buffer).setUint32(4, size, false);
    await expect(openOwnerSnapshot(bad)).rejects.toMatchObject(failure);
  }
});

it('fails closed on truncated or corrupt gzip rather than trying legacy JSON', async () => {
  const good = await frame(json);
  const corrupt = good.slice(); corrupt[8] = 0;
  for (const bad of [good.slice(0, -1), good.slice(0, 15), corrupt]) {
    await expect(openOwnerSnapshot(bad)).rejects.toMatchObject(failure);
  }
});

it('bounds streaming expansion by the declared size and requires an exact match', async () => {
  await expect(openOwnerSnapshot(await frame(new Uint8Array(2 * 1024 * 1024), 64)))
    .rejects.toMatchObject(failure);
  await expect(openOwnerSnapshot(await frame(json, json.length + 1)))
    .rejects.toMatchObject(failure);
});
