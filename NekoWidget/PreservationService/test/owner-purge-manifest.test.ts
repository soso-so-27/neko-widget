import { expect, it } from 'vitest';
import { buildOwnerPurgeManifest } from '../src/owner-purge-manifest';
import type { OwnerCloudInventory } from '../src/owner-cloud-inventory';
import type { PrimaryInventory } from '../src/owner-primary-reconciliation';
import type { PurgeFence } from '../src/owner-purge-fence';

const ownerId = '00000000-0000-4000-8000-000000000001';
const intentId = '00000000-0000-4000-8000-000000000002';
const photoKey = `personal/${ownerId}/00000000-0000-4000-8000-000000000003/00000000-0000-4000-8000-000000000004`;
const recoveryKey = `recovery/v1/${ownerId}/record/00000000-0000-4000-8000-000000000005`;
const fence = { ownerId, fenceId: intentId, ownerEpoch: 2, inventoryGeneration: 4 } as PurgeFence;
const primary: PrimaryInventory = { ownerId, epoch: 2, generation: 4, records: 1,
  photos: 1, photoKeys: [photoKey], recordDigest: 'a'.repeat(64) };
const cloud: OwnerCloudInventory = { ownerId,
  r2Objects: [{ key: photoKey, version: 'r2-a', bytes: 8 }], r2Bytes: 8,
  s3Versions: [
    { key: recoveryKey, versionId: 's3-b', deleteMarker: true, bytes: null },
    { key: recoveryKey, versionId: 's3-a', deleteMarker: false, bytes: 12 },
  ], s3VersionBytes: 12, s3DeleteMarkers: 1 };

it('builds stable owner-bound small chunks including every S3 version and marker', async () => {
  const first = await buildOwnerPurgeManifest(fence, primary, cloud);
  const reverse = await buildOwnerPurgeManifest(fence, primary,
    { ...cloud, s3Versions: [...cloud.s3Versions].reverse() });
  expect(first).toEqual(reverse);
  expect(first).toMatchObject({ ownerId, intentId, ownerEpoch: 2,
    r2Count: 1, s3Count: 2, r2Bytes: 8, s3Bytes: 12,
    sha256: expect.stringMatching(/^[0-9a-f]{64}$/u) });
  expect(first.chunks).toHaveLength(2);
  expect(first.chunks.map(chunk => chunk.kind)).toEqual(['r2', 's3']);
  expect(first.chunks[1]?.items).toEqual([
    { key: recoveryKey, versionId: 's3-a', deleteMarker: false, bytes: 12 },
    { key: recoveryKey, versionId: 's3-b', deleteMarker: true, bytes: null },
  ]);
});

it('rejects a mismatched primary reference, duplicate version, and changed totals', async () => {
  const bad = [
    { ...cloud, r2Objects: [{ ...cloud.r2Objects[0]!, key: photoKey.replace(ownerId, intentId) }] },
    { ...cloud, s3Versions: [cloud.s3Versions[0]!, cloud.s3Versions[0]!] },
    { ...cloud, s3VersionBytes: 11 },
    { ...cloud, r2Objects: [{ ...cloud.r2Objects[0]!, note: 'must never enter a purge plan' }] },
    { ...cloud, s3Versions: [{ ...cloud.s3Versions[0]!, email: 'must never enter a purge plan' },
      cloud.s3Versions[1]!] },
  ];
  for (const input of bad) {
    await expect(buildOwnerPurgeManifest(fence, primary, input))
      .rejects.toMatchObject({ code: 'OWNER_PURGE_MANIFEST_UNAVAILABLE' });
  }
});

it('splits a large version list into bounded chunks', async () => {
  const versions = Array.from({ length: 300 }, (_, index) => ({ key: recoveryKey,
    versionId: `s3-${String(index).padStart(3, '0')}`,
    deleteMarker: false, bytes: 1 }));
  const result = await buildOwnerPurgeManifest(fence, primary,
    { ...cloud, s3Versions: versions, s3VersionBytes: 300, s3DeleteMarkers: 0 });
  expect(result.chunks.map(chunk => chunk.items.length)).toEqual([1, 128, 128, 44]);
  expect(result.chunks.every(chunk => chunk.bytes <= 512 * 1024)).toBe(true);
});
