import { expect, it } from 'vitest';
import { inventoryOwnerCloudStorage } from '../src/owner-cloud-inventory';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';

const owner = '00000000-0000-4000-8000-000000000001';
const photo = `personal/${owner}/00000000-0000-4000-8000-000000000002/00000000-0000-4000-8000-000000000003`;
const record = `recovery/v1/${owner}/record/00000000-0000-4000-8000-000000000004`;

it('counts physical R2 objects and every S3 version without changing either store', async () => {
  const bucket = { list: async () => ({ objects: [{ key: photo, version: 'r2-1', size: 100 }],
    truncated: false, delimitedPrefixes: [] }) } as unknown as R2Bucket;
  const s3 = { listOwnerVersionsPage: async () => ({ versions: [
    { key: record, versionId: 's3-1', deleteMarker: false, bytes: 110 },
    { key: record, versionId: 's3-2', deleteMarker: false, bytes: 120 },
    { key: record, versionId: 's3-3', deleteMarker: true, bytes: null },
  ], nextCursor: null }) } as unknown as S3RecoveryCopy;
  const result = await inventoryOwnerCloudStorage(bucket, s3, owner);
  expect(result).toMatchObject({ ownerId: owner, r2Bytes: 100,
    s3VersionBytes: 230, s3DeleteMarkers: 1 });
  expect(result.r2Objects).toHaveLength(1);
  expect(result.s3Versions).toHaveLength(3);
});

it('follows both stores through continuation pages and rejects duplicate S3 versions', async () => {
  let r2Calls = 0;
  const bucket = { list: async () => (++r2Calls === 1
    ? { objects: [], truncated: true, cursor: 'r2-next', delimitedPrefixes: [] }
    : { objects: [{ key: photo, version: 'r2-1', size: 100 }],
      truncated: false, delimitedPrefixes: [] }) } as unknown as R2Bucket;
  let s3Calls = 0;
  const s3 = { listOwnerVersionsPage: async () => (++s3Calls === 1
    ? { versions: [{ key: record, versionId: 's3-1', deleteMarker: false, bytes: 110 }],
      nextCursor: { keyMarker: record, versionIdMarker: 's3-1' } }
    : { versions: [{ key: record, versionId: 's3-2', deleteMarker: false, bytes: 120 }],
      nextCursor: null }) } as unknown as S3RecoveryCopy;
  expect((await inventoryOwnerCloudStorage(bucket, s3, owner)).s3VersionBytes).toBe(230);
  expect(r2Calls).toBe(2);
  expect(s3Calls).toBe(2);
  const duplicate = { listOwnerVersionsPage: async () => ({ versions: [
    { key: record, versionId: 's3-1', deleteMarker: false, bytes: 110 },
    { key: record, versionId: 's3-1', deleteMarker: false, bytes: 110 },
  ], nextCursor: null }) } as unknown as S3RecoveryCopy;
  await expect(inventoryOwnerCloudStorage(bucket, duplicate, owner))
    .rejects.toMatchObject({ code: 'OWNER_CLOUD_INVENTORY_UNAVAILABLE' });
});

it('fails closed on a looping S3 cursor or an invalid owner', async () => {
  const bucket = { list: async () => ({ objects: [], truncated: false,
    delimitedPrefixes: [] }) } as unknown as R2Bucket;
  const s3 = { listOwnerVersionsPage: async () => ({ versions: [],
    nextCursor: { keyMarker: record, versionIdMarker: 'same' } }) } as unknown as S3RecoveryCopy;
  await expect(inventoryOwnerCloudStorage(bucket, s3, owner))
    .rejects.toMatchObject({ code: 'OWNER_CLOUD_INVENTORY_UNAVAILABLE' });
  await expect(inventoryOwnerCloudStorage(bucket, s3, 'wrong-owner'))
    .rejects.toMatchObject({ code: 'OWNER_CLOUD_INVENTORY_UNAVAILABLE' });
});
