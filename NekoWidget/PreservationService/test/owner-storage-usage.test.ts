import { expect, it, vi } from 'vitest';
import { inspectOwnerStorageUsage, summarizeOwnerStorageUsage, type OwnerStorageReferences } from '../src/owner-storage-usage';
import type { OwnerCloudInventory } from '../src/owner-cloud-inventory';
import type { RecoveryObject, RecoveryVersion } from '../src/s3-recovery-copy';

const owner = '00000000-0000-4000-8000-000000000001';
const another = '00000000-0000-4000-8000-000000000002';
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const photo = (n: number) => `personal/${owner}/${id(n)}/${id(n + 10)}`;
const key = (kind: string, n = 100) => `recovery/v1/${owner}/${kind}/${id(n)}`;
const version = (kind: string, versionId: string, bytes: number): RecoveryVersion =>
  ({ key: key(kind), versionId, bytes, deleteMarker: false });
const ref = (kind: string, versionId: string, bytes: number): RecoveryObject =>
  ({ key: key(kind), versionId, bytes, sha256: 'a'.repeat(64) });
const emptyRefs = (): OwnerStorageReferences =>
  ({ ownerId: owner, recordPhotoKeys: [], pendingPhotoKeys: [], recoveryObjects: [] });
function inventory(): OwnerCloudInventory {
  return {
    ownerId: owner,
    r2Objects: [1, 2, 3, 4].map(n => ({ key: photo(n), version: `r2-${n}`, bytes: n * 100 })),
    r2Bytes: 1000,
    s3Versions: [version('photo', 'p1', 100), version('photo', 'p2', 200),
      version('record', 'r1', 30), version('manifest', 'm1', 40),
      version('owner', 'o1', 50), version('owner', 'o2', 60),
      { key: key('photo'), versionId: 'deleted', bytes: null, deleteMarker: true }],
    s3VersionBytes: 480, s3DeleteMarkers: 1,
  };
}

it('accounts for every physical version by purpose without declaring old copies redundant', () => {
  const result = summarizeOwnerStorageUsage(inventory());
  expect(result.r2).toEqual({ objects: 4, bytes: 1000 });
  expect(result.s3).toEqual({ objects: 6, bytes: 480, deleteMarkers: 1, byKind: {
    photo: { objects: 2, bytes: 300, deleteMarkers: 1 },
    record: { objects: 1, bytes: 30, deleteMarkers: 0 },
    manifest: { objects: 1, bytes: 40, deleteMarkers: 0 },
    owner: { objects: 2, bytes: 110, deleteMarkers: 0 },
    unknown: { objects: 0, bytes: 0, deleteMarkers: 0 },
  } });
  expect(result).toMatchObject({ references: null, recoveryVerified: false,
    deletionAuthorized: false, consistency: 'advisory-nonatomic', inventoryCoverage: 'provided-objects-only' });
});

it('partitions R2 record/pending overlap once and retains unresolved copies and missing keys', () => {
  const references = { ...emptyRefs(), recordPhotoKeys: [photo(1), photo(3), photo(5), photo(5)],
    pendingPhotoKeys: [photo(2), photo(3), photo(6)] };
  const before = JSON.stringify(references);
  const result = summarizeOwnerStorageUsage(inventory(), references);
  expect(result.references?.r2).toEqual({ recordOnly: { objects: 1, bytes: 100 },
    pendingOnly: { objects: 1, bytes: 200 }, recordAndPending: { objects: 1, bytes: 300 },
    unmatched: { objects: 1, bytes: 400 }, missingRecordKeys: 1, missingPendingKeys: 1 });
  expect(JSON.stringify(references)).toBe(before);
});

it('uses exact S3 versions, deduplicates shared refs, and exposes missing/deleted/size-mismatched evidence', () => {
  const references = { ...emptyRefs(), recoveryObjects: [ref('photo', 'p2', 200),
    ref('photo', 'p2', 200), ref('record', 'r1', 31), ref('photo', 'deleted', 100),
    ref('owner', 'not-listed', 60)] };
  const result = summarizeOwnerStorageUsage(inventory(), references);
  expect(result.references?.s3).toEqual({ listedReference: { objects: 1, bytes: 200 },
    unmatched: { objects: 4, bytes: 250 }, sizeMismatch: { objects: 1, bytes: 30 },
    notListedReferences: 1, deleteMarkerReferences: 1 });
  // Same key p1 stays unresolved; a p2 reference cannot certify that old version.
  expect(result.references?.scope).toBe('supplied-only');
  expect(result.recoveryVerified).toBe(false);
});

it('keeps unfamiliar in-owner keys in the total instead of silently omitting them', () => {
  const input = inventory();
  input.s3Versions.push(version('future-schema', 'future', 70));
  input.s3VersionBytes += 70;
  const result = summarizeOwnerStorageUsage(input, emptyRefs());
  expect(result.s3.bytes).toBe(550);
  expect(result.s3.byKind.unknown).toEqual({ objects: 1, bytes: 70, deleteMarkers: 0 });
  expect(result.references?.s3.unmatched.bytes).toBe(550);
});

it('rejects contradictory refs instead of allowing input order to choose the accounting result', () => {
  for (const conflict of [{ ...ref('photo', 'p2', 200), sha256: 'b'.repeat(64) }, ref('photo', 'p2', 201)]) {
    expect(() => summarizeOwnerStorageUsage(inventory(), { ...emptyRefs(),
      recoveryObjects: [ref('photo', 'p2', 200), conflict] })).toThrow('OWNER_STORAGE_USAGE_UNAVAILABLE');
  }
});

it('rejects duplicate physical identities and totals that do not reconcile', () => {
  for (const change of [
    (x: OwnerCloudInventory) => { x.r2Objects.push(x.r2Objects[0]!); x.r2Bytes += 100; },
    (x: OwnerCloudInventory) => { x.s3Versions.push(x.s3Versions[0]!); x.s3VersionBytes += 100; },
    (x: OwnerCloudInventory) => { x.r2Bytes++; },
    (x: OwnerCloudInventory) => { x.s3VersionBytes++; },
    (x: OwnerCloudInventory) => { x.s3DeleteMarkers++; },
  ]) {
    const input = inventory(); change(input);
    expect(() => summarizeOwnerStorageUsage(input)).toThrow('OWNER_STORAGE_USAGE_UNAVAILABLE');
  }
});

it('rejects cross-owner or malformed listed entries without returning partial totals', () => {
  for (const change of [
    (x: OwnerCloudInventory) => { x.ownerId = another; },
    (x: OwnerCloudInventory) => { x.s3Versions[0]!.key = key('photo').replace(owner, another); },
    (x: OwnerCloudInventory) => { x.r2Objects[0]!.key = photo(1).replace(owner, another); },
    (x: OwnerCloudInventory) => { x.s3Versions[0]!.versionId = 'null'; },
    (x: OwnerCloudInventory) => { x.s3Versions[0]!.bytes = NaN; },
    (x: OwnerCloudInventory) => { x.s3Versions[0]!.bytes = -1; },
    (x: OwnerCloudInventory) => { x.s3Versions[0]!.bytes = 0.1; },
    (x: OwnerCloudInventory) => { x.s3Versions[6]!.bytes = 0; },
  ]) {
    const input = inventory(); change(input);
    expect(() => summarizeOwnerStorageUsage(input)).toThrow('OWNER_STORAGE_USAGE_UNAVAILABLE');
  }
});

it('rejects byte overflow even when the caller supplies the rounded total', () => {
  const input = inventory();
  input.s3Versions = [version('photo', 'p1', Number.MAX_SAFE_INTEGER), version('photo', 'p2', 1)];
  input.s3VersionBytes = Number.MAX_SAFE_INTEGER + 1; input.s3DeleteMarkers = 0;
  expect(() => summarizeOwnerStorageUsage(input)).toThrow('OWNER_STORAGE_USAGE_UNAVAILABLE');
});

it('retains totals independently of ordering or missing reference evidence', () => {
  const input = inventory();
  const before = JSON.stringify(input);
  const result = summarizeOwnerStorageUsage(input, emptyRefs());
  expect(JSON.stringify(input)).toBe(before);
  input.r2Objects.reverse(); input.s3Versions.reverse();
  expect(summarizeOwnerStorageUsage(input, emptyRefs())).toEqual(result);
  expect(result.references?.r2.unmatched.bytes).toBe(1000);
  expect(result.references?.s3.unmatched.bytes).toBe(480);
  expect(result.deletionAuthorized).toBe(false);
});

it('collects with LIST only, and rejects wrong-owner evidence before any network access', async () => {
  const list = vi.fn(async () => ({ objects: [], truncated: false, delimitedPrefixes: [] }));
  const listOwnerVersionsPage = vi.fn(async () => ({ versions: [], nextCursor: null }));
  const bucket = { list } as unknown as R2Bucket;
  const s3 = { listOwnerVersionsPage };
  const result = await inspectOwnerStorageUsage(bucket, s3, owner);
  expect(result.r2.bytes).toBe(0); expect(result.s3.bytes).toBe(0);
  expect(list).toHaveBeenCalledTimes(1); expect(listOwnerVersionsPage).toHaveBeenCalledTimes(1);
  for (const references of [{ ...emptyRefs(), ownerId: another },
    { ...emptyRefs(), recordPhotoKeys: [photo(1).replace(owner, another)] },
    { ...emptyRefs(), recoveryObjects: [{ ...ref('photo', 'p1', 100), key: key('photo').replace(owner, another) }] }]) {
    await expect(inspectOwnerStorageUsage(bucket, s3, owner, references))
      .rejects.toMatchObject({ code: 'OWNER_STORAGE_USAGE_UNAVAILABLE' });
  }
  expect(list).toHaveBeenCalledTimes(1); expect(listOwnerVersionsPage).toHaveBeenCalledTimes(1);
});

it('propagates a failed physical collection instead of reporting a zero-cost owner', async () => {
  const bucket = { list: async () => { throw new Error('unavailable'); } } as unknown as R2Bucket;
  const listOwnerVersionsPage = vi.fn();
  await expect(inspectOwnerStorageUsage(bucket, { listOwnerVersionsPage }, owner)).rejects.toThrow();
  expect(listOwnerVersionsPage).not.toHaveBeenCalled();
});
