import { expect, it } from 'vitest';
import { remainingCloudItems } from '../src/owner-cloud-subset';
import type { OwnerCloudInventory } from '../src/owner-cloud-inventory';
import type { PurgeManifest } from '../src/owner-purge-manifest';

const ownerId = '12345678-1234-4123-8123-123456789abc';
const photo = { key: `personal/${ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`,
  version: 'r2-v1', bytes: 123 };
const recovery = { key: `recovery/v1/${ownerId}/photo/${crypto.randomUUID()}`,
  versionId: 's3-v1', deleteMarker: false, bytes: 456 };
const manifest = { ownerId, r2Count: 1, s3Count: 1,
  chunks: [{ kind: 'r2', items: [photo] }, { kind: 's3', items: [recovery] }]
} as unknown as PurgeManifest;
const inventory = (r2Objects: OwnerCloudInventory['r2Objects'],
  s3Versions: OwnerCloudInventory['s3Versions']): OwnerCloudInventory => ({
  ownerId, r2Objects: [...r2Objects], s3Versions: [...s3Versions],
  r2Bytes: r2Objects.reduce((sum, item) => sum + item.bytes, 0),
  s3VersionBytes: s3Versions.reduce((sum, item) =>
    sum + (item.bytes ?? 0), 0),
  s3DeleteMarkers: s3Versions.filter(item => item.deleteMarker).length,
});

it('accepts only unchanged listed objects while a purge shrinks the inventory', () => {
  expect(remainingCloudItems(manifest, inventory([photo], [recovery])))
    .toEqual({ r2: [photo], s3: [recovery] });
  expect(remainingCloudItems(manifest, inventory([], [recovery])))
    .toEqual({ r2: [], s3: [recovery] });
  expect(remainingCloudItems(manifest, inventory([], [])))
    .toEqual({ r2: [], s3: [] });
});

it('rejects an unlisted object or replacement version', () => {
  expect(() => remainingCloudItems(manifest,
    inventory([{ ...photo, version: 'r2-v2' }], [recovery])))
    .toThrowError();
  expect(() => remainingCloudItems(manifest,
    inventory([photo], [{ ...recovery, versionId: 's3-v2' }])))
    .toThrowError();
  expect(() => remainingCloudItems(manifest,
    inventory([photo, { ...photo, key: `${photo.key}-orphan` }], [recovery])))
    .toThrowError();
});
