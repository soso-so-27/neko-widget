import { expect, it } from 'vitest';
import { listOwnerPhotoPage } from '../src/owner-photo-inventory';

const owner = '00000000-0000-4000-8000-000000000001';
const other = '00000000-0000-4000-8000-000000000099';
const first = `personal/${owner}/00000000-0000-4000-8000-000000000002/00000000-0000-4000-8000-000000000003`;
const second = `personal/${owner}/00000000-0000-4000-8000-000000000004/00000000-0000-4000-8000-000000000005`;
const item = (key: string, version = 'r2-v1', size = 5) => ({ key, version, size });
const mock = (list: (...args: unknown[]) => unknown) => ({ list }) as unknown as R2Bucket;

it('uses R2 truncated/cursor, not the page length, and binds continuation to the owner', async () => {
  const calls: unknown[] = [];
  const bucket = mock(async (options: unknown) => {
    calls.push(options);
    return calls.length === 1
      ? { objects: [item(first)], truncated: true, cursor: 'opaque-1', delimitedPrefixes: [] }
      : { objects: [item(second, 'r2-v2', 7)], truncated: false, delimitedPrefixes: [] };
  });
  const page = await listOwnerPhotoPage(bucket, owner);
  expect(page).toEqual({ objects: [{ key: first, version: 'r2-v1', bytes: 5 }],
    nextCursor: { ownerId: owner, token: 'opaque-1', lastKey: first } });
  expect(await listOwnerPhotoPage(bucket, owner, page.nextCursor!)).toEqual({
    objects: [{ key: second, version: 'r2-v2', bytes: 7 }], nextCursor: null });
  expect(calls).toEqual([
    { prefix: `personal/${owner}/`, limit: 1000 },
    { prefix: `personal/${owner}/`, limit: 1000, cursor: 'opaque-1' },
  ]);
});

it('fails closed on foreign keys, non-progressing pages and malformed cursors', async () => {
  const invalid = [
    { objects: [item(`personal/${other}/00000000-0000-4000-8000-000000000002/00000000-0000-4000-8000-000000000003`)], truncated: false },
    { objects: [item(second), item(first)], truncated: false },
    { objects: [item(first, '', 5)], truncated: false },
    { objects: [item(first, 'v1', -1)], truncated: false },
    { objects: [item(first)], truncated: true },
    { objects: [item(first)], truncated: true, cursor: 'same' },
    { objects: [item(first)], truncated: false, cursor: 'unexpected' },
    { objects: [], truncated: false, delimitedPrefixes: ['personal/'] },
    { objects: [], truncated: false, delimitedPrefixes: {} },
    { objects: [], truncated: false },
  ];
  for (const result of invalid) {
    const bucket = mock(async () => result);
    await expect(listOwnerPhotoPage(bucket, owner, { ownerId: owner, token: 'same', lastKey: null }))
      .rejects.toMatchObject({ code: 'ARCHIVE_INVENTORY_UNAVAILABLE' });
  }
  const bucket = mock(async () => { throw new Error('unexpected'); });
  await expect(listOwnerPhotoPage(bucket, owner)).rejects.toMatchObject({ code: 'ARCHIVE_INVENTORY_UNAVAILABLE' });
  await expect(listOwnerPhotoPage(bucket, 'invalid')).rejects.toMatchObject({ code: 'ARCHIVE_INVENTORY_UNAVAILABLE' });
  await expect(listOwnerPhotoPage(bucket, owner, { ownerId: other, token: 'same', lastKey: null }))
    .rejects.toMatchObject({ code: 'ARCHIVE_INVENTORY_UNAVAILABLE' });
});
