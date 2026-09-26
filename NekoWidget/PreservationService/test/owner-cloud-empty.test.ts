import { expect, it } from 'vitest';
import { verifyOwnerCloudEmpty } from '../src/owner-cloud-empty';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';

const ownerId = '12345678-1234-4123-8123-123456789abc';

it('requires two empty R2 and S3 recovery inventories', async () => {
  let r2 = 0;
  let s3 = 0;
  const bucket = { list: async () => { r2++;
    return { objects: [], truncated: false, delimitedPrefixes: [] }; } } as unknown as R2Bucket;
  const recovery = { listOwnerVersionsPage: async () => { s3++;
    return { versions: [], nextCursor: null }; } } as unknown as S3RecoveryCopy;
  await verifyOwnerCloudEmpty(bucket, recovery, ownerId);
  expect([r2, s3]).toEqual([2, 2]);
});

it('rejects a late R2 object and any remaining S3 delete marker', async () => {
  let pass = 0;
  const key = `personal/${ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`;
  const late = { list: async () => ({ objects: ++pass === 1 ? []
    : [{ key, version: 'v1', size: 12 }], truncated: false,
    delimitedPrefixes: [] }) } as unknown as R2Bucket;
  const empty = { listOwnerVersionsPage: async () => ({ versions: [], nextCursor: null })
  } as unknown as S3RecoveryCopy;
  await expect(verifyOwnerCloudEmpty(late, empty, ownerId))
    .rejects.toMatchObject({ code: 'OWNER_CLOUD_NOT_EMPTY' });
  const noR2 = { list: async () => ({ objects: [], truncated: false,
    delimitedPrefixes: [] }) } as unknown as R2Bucket;
  const marker = { listOwnerVersionsPage: async () => ({ versions: [{ key:
    `recovery/v1/${ownerId}/owner/${crypto.randomUUID()}`, versionId: 'v2',
    deleteMarker: true, bytes: null }], nextCursor: null }) } as unknown as S3RecoveryCopy;
  await expect(verifyOwnerCloudEmpty(noR2, marker, ownerId))
    .rejects.toMatchObject({ code: 'OWNER_CLOUD_NOT_EMPTY' });
});
