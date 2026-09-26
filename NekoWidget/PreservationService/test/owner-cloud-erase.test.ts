import { expect, it } from 'vitest';
import { OwnerCloudEraser } from '../src/owner-cloud-erase';
import type { PurgeManifest } from '../src/owner-purge-manifest';
import type { PurgeIntentEvent, S3PurgeIntentStore } from '../src/s3-purge-intent';
import type { S3PurgeManifestStore } from '../src/s3-purge-manifest';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';
import type { S3VersionPurge } from '../src/s3-version-purge';

const ownerId = '12345678-1234-4123-8123-123456789abc';
const intentId = '87654321-4321-4123-8123-123456789abc';
const root = 'a'.repeat(64);
const photo = { key: `personal/${ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}`,
  version: 'r2-v1', bytes: 123 };
const version = { key: `recovery/v1/${ownerId}/photo/${crypto.randomUUID()}`,
  versionId: 's3-v1', deleteMarker: false, bytes: 456 };
const plan = { ownerId, intentId, sha256: root,
  ownerEpoch: 1, inventoryGeneration: 0, r2Count: 1, s3Count: 1,
  chunks: [{ kind: 'r2', items: [photo] }, { kind: 's3', items: [version] }]
} as unknown as PurgeManifest;
const events: PurgeIntentEvent[] = (['prepared', 'erasing'] as const).map(
  (stage, index) => ({ version: 1, ownerId, intentId, stage,
    ownerEpoch: 1, inventoryGeneration: 0, retentionEpisode: 1,
    retentionRevision: 1, dueAt: 1_800_000_000_000,
    recordedAt: 1_800_000_000_000 + index,
    manifestSha256: stage === 'erasing' ? root : null }));

function fixture(status: 'expired' | 'active' = 'expired', orphan = false,
  wrongRevision = false) {
  let r2 = [photo];
  let s3 = [version];
  let deletes = 0;
  if (orphan) r2 = [...r2, { ...photo,
    key: `personal/${ownerId}/${crypto.randomUUID()}/${crypto.randomUUID()}` }];
  const bucket = {
    list: async () => ({ objects: r2.map(item => ({ ...item, size: item.bytes })),
      truncated: false, delimitedPrefixes: [] }),
    head: async (key: string) => {
      const item = r2.find(value => value.key === key);
      return item ? { key, version: item.version, size: item.bytes } : null;
    },
    delete: async (key: string) => { deletes++; r2 = r2.filter(item => item.key !== key); },
  } as unknown as R2Bucket;
  const recovery = { listOwnerVersionsPage: async () => ({ versions: s3,
    nextCursor: null }) } as unknown as S3RecoveryCopy;
  const versionPurge = { requestExactVersionDeletion: async (_owner: string,
    item: typeof version) => { deletes++; s3 = s3.filter(value =>
    value.key !== item.key || value.versionId !== item.versionId); }
  } as unknown as S3VersionPurge;
  const intentStore = {
    listOwnerVersionsPage: async () => ({ versions: events.map(event => ({
      key: `purge/v1/${ownerId}/${intentId}/${event.stage}`,
      versionId: `v-${event.stage}`, deleteMarker: false, bytes: 10 })),
      nextCursor: null }),
    referenceForListedVersion: async (item: { key: string; versionId: string }) =>
      ({ ...item, sha256: 'b'.repeat(64), bytes: 10 }),
    readExact: async (ref: { key: string }) => events.find(event =>
      ref.key.endsWith(`/${event.stage}`))!,
  } as unknown as S3PurgeIntentStore;
  const planStore = { loadPublished: async () => plan
  } as unknown as S3PurgeManifestStore;
  const authority = { billing_account_id: 'billing-test', manifest_sha256: root,
    owner_epoch: 1, inventory_generation: 0, retention_episode: 1,
    retention_revision: wrongRevision ? 2 : 1, due_at: 1_800_000_000_000 };
  const db = { prepare: () => ({ bind: () => ({ first: async () => authority }) })
  } as unknown as D1Database;
  const eraser = new OwnerCloudEraser({ db, bucket, recovery, versionPurge,
    intentStore, planStore, statusForBillingAccount: async () => status,
    enabled: 'YES' });
  return { eraser, deleted: () => deletes };
}

it('deletes only externally planned R2 and exact S3 versions, then proves empty', async () => {
  const f = fixture();
  expect(await f.eraser.step(ownerId, intentId, root))
    .toEqual({ state: 'progress', kind: 'r2' });
  expect(await f.eraser.step(ownerId, intentId, root))
    .toEqual({ state: 'progress', kind: 's3' });
  expect(await f.eraser.step(ownerId, intentId, root))
    .toEqual({ state: 'empty' });
  expect(f.deleted()).toBe(2);
});

it('stops before any delete on renewal or an unplanned cloud object', async () => {
  const active = fixture('active');
  await expect(active.eraser.step(ownerId, intentId, root)).rejects
    .toMatchObject({ code: 'OWNER_CLOUD_ERASE_UNAVAILABLE' });
  expect(active.deleted()).toBe(0);
  const orphan = fixture('expired', true);
  await expect(orphan.eraser.step(ownerId, intentId, root)).rejects
    .toMatchObject({ code: 'OWNER_CLOUD_ERASE_UNAVAILABLE' });
  expect(orphan.deleted()).toBe(0);
  const mismatchedClaim = fixture('expired', false, true);
  await expect(mismatchedClaim.eraser.step(ownerId, intentId, root)).rejects
    .toMatchObject({ code: 'OWNER_CLOUD_ERASE_UNAVAILABLE' });
  expect(mismatchedClaim.deleted()).toBe(0);
});
