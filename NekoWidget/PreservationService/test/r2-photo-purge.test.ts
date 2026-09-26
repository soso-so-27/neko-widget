import { expect, it } from 'vitest';
import { requestManifestPhotoDeletion } from '../src/r2-photo-purge';

const ownerId = '12345678-1234-4123-8123-123456789abc';
const key = `personal/${ownerId}/12345678-1234-1234-1234-123456789abc/12345678-1234-4123-8123-123456789abc`;
const item = { key, version: 'v1', bytes: 32 };

it('deletes only a matching owner object and requires a post-delete miss', async () => {
  let exists = true;
  let deletes = 0;
  const bucket = { head: async () => exists ? { key, version: 'v1', size: 32 } : null,
    delete: async () => { deletes++; exists = false; } } as unknown as R2Bucket;
  expect(await requestManifestPhotoDeletion(bucket, ownerId, item)).toBe('deleted');
  expect(await requestManifestPhotoDeletion(bucket, ownerId, item)).toBe('already-absent');
  expect(deletes).toBe(1);
});

it('refuses another owner, a changed version, or a late replacement', async () => {
  let deletes = 0;
  const changed = { head: async () => ({ key, version: 'v2', size: 32 }),
    delete: async () => { deletes++; } } as unknown as R2Bucket;
  await expect(requestManifestPhotoDeletion(changed, ownerId, item)).rejects
    .toMatchObject({ code: 'R2_PHOTO_PURGE_UNAVAILABLE' });
  await expect(requestManifestPhotoDeletion(changed, crypto.randomUUID(), item)).rejects
    .toMatchObject({ code: 'R2_PHOTO_PURGE_UNAVAILABLE' });
  const replaced = { head: async () => ({ key, version: 'v1', size: 32 }),
    delete: async () => { deletes++; } } as unknown as R2Bucket;
  await expect(requestManifestPhotoDeletion(replaced, ownerId, item)).rejects
    .toMatchObject({ code: 'R2_PHOTO_PURGE_UNAVAILABLE' });
  expect(deletes).toBe(1);
});
