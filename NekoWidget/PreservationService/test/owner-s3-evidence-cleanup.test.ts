import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import { OwnerS3EvidenceCleanup } from '../src/owner-s3-evidence-cleanup';
import type { PurgeIntentReference, PurgeIntentVersion,
  S3PurgeIntentStore } from '../src/s3-purge-intent';
import type { PurgeManifestCopyVersion, S3PurgeManifestStore } from '../src/s3-purge-manifest';
import type { S3PurgeEvidenceDelete } from '../src/s3-purge-evidence-delete';
import type { S3RecoveryCopy } from '../src/s3-recovery-copy';

const db = (env as unknown as { DB: D1Database }).DB;
const day = 86_400_000;

function fixture(options: { ageDays?: number; floor?: boolean; duplicateCompleted?: boolean;
  loseFinalReply?: boolean } = {}) {
  const ownerId = crypto.randomUUID();
  const intentId = crypto.randomUUID();
  const abortedIntent = crypto.randomUUID();
  const now = Date.now();
  const recordedAt = now - (options.ageDays ?? 32) * day;
  const completedRef: PurgeIntentReference = {
    key: `purge/v1/${ownerId}/${intentId}/completed`, versionId: 'completed-v1',
    sha256: 'a'.repeat(64), bytes: 200,
  };
  const events: PurgeIntentVersion[] = [
    { key: completedRef.key, versionId: completedRef.versionId,
      deleteMarker: false, bytes: 200 },
    { key: `purge/v1/${ownerId}/${intentId}/prepared`,
      versionId: 'prepared-v1', deleteMarker: false, bytes: 200 },
    { key: `purge/v1/${ownerId}/${abortedIntent}/aborted`,
      versionId: 'aborted-v1', deleteMarker: false, bytes: 200 },
    ...(options.duplicateCompleted ? [{ key: completedRef.key, versionId: 'completed-v2',
      deleteMarker: false, bytes: 200 }] : []),
  ];
  const plans: PurgeManifestCopyVersion[] = [
    { key: `purge-plan/v1/${ownerId}/${intentId}/header`,
      versionId: 'header-v1', deleteMarker: false, bytes: 200 },
    { key: `purge-plan/v1/${ownerId}/${abortedIntent}/header`,
      versionId: 'aborted-header-v1', deleteMarker: false, bytes: 200 },
  ];
  const deleted: string[] = [];
  const intentStore = {
    readExact: async (ref: PurgeIntentReference) => {
      if (ref.key !== completedRef.key || ref.versionId !== completedRef.versionId
        || !events.some(item => item.key === ref.key && item.versionId === ref.versionId)) {
        throw new Error('missing completed version');
      }
      return { ownerId, intentId, stage: 'completed', manifestSha256: 'b'.repeat(64),
        recordedAt };
    },
    listOwnerVersionsPage: async () => ({ versions: [...events], nextCursor: null }),
  } as unknown as S3PurgeIntentStore;
  const planStore = { listOwnerEvidenceVersionsPage: async () =>
    ({ versions: [...plans], nextCursor: null }) } as unknown as S3PurgeManifestStore;
  const deleteStore = {
    requestPlanVersionDeletion: async (_owner: string, _intent: string,
      item: PurgeManifestCopyVersion) => {
      deleted.push(`plan:${item.versionId}`);
      plans.splice(plans.findIndex(value => value.versionId === item.versionId), 1);
    },
    requestEventVersionDeletion: async (_owner: string, _intent: string,
      item: PurgeIntentVersion) => {
      deleted.push(`event:${item.versionId}`);
      events.splice(events.findIndex(value => value.versionId === item.versionId), 1);
      if (options.loseFinalReply && item.versionId === completedRef.versionId) {
        throw new Error('response lost after commit');
      }
    },
  } as unknown as S3PurgeEvidenceDelete;
  const bucket = { list: async () => ({ objects: [], truncated: false,
    delimitedPrefixes: [] }) } as unknown as R2Bucket;
  const recovery = { listOwnerVersionsPage: async () =>
    ({ versions: [], nextCursor: null }) } as unknown as S3RecoveryCopy;
  const run = (enabled = 'YES') => new OwnerS3EvidenceCleanup({ db, bucket, recovery,
    intentStore, planStore, deleteStore, now: () => now,
    restoreWindowClosed: async () => options.floor ?? true, enabled })
    .step(ownerId, intentId, completedRef);
  return { run, events, plans, deleted };
}

it('requires the explicit flag, 31 days, and a verified closed restore window', async () => {
  for (const options of [{}, { ageDays: 30 }, { floor: false }]) {
    const f = fixture(options);
    await expect(f.run(options.ageDays === undefined && options.floor === undefined ? 'NO' : 'YES'))
      .rejects.toMatchObject({ code: 'PURGE_EVIDENCE_CLEANUP_UNAVAILABLE' });
    expect(f.deleted).toEqual([]);
  }
});

it('deletes plans first, other events next, and the exact completed version last', async () => {
  const f = fixture();
  expect((await f.run()).state).toBe('progress');
  expect(f.deleted).toEqual(['plan:header-v1', 'plan:aborted-header-v1']);
  expect((await f.run()).state).toBe('progress');
  expect(f.deleted.slice(2)).toEqual(['event:prepared-v1', 'event:aborted-v1']);
  expect(await f.run()).toEqual({ state: 's3-cleared', overdue: false });
  expect(f.deleted.at(-1)).toBe('event:completed-v1');
  expect(await f.run()).toEqual({ state: 's3-cleared', overdue: false });
});

it('fails closed on another version of the completed key', async () => {
  const f = fixture({ duplicateCompleted: true });
  await f.run();
  await expect(f.run()).rejects.toMatchObject({ code: 'PURGE_EVIDENCE_CLEANUP_UNAVAILABLE' });
  expect(f.deleted.every(value => value.startsWith('plan:'))).toBe(true);
});

it('accepts a lost final deletion response only after both prefixes are empty', async () => {
  const f = fixture({ loseFinalReply: true });
  await f.run();
  await f.run();
  await expect(f.run()).rejects.toMatchObject({ code: 'PURGE_EVIDENCE_CLEANUP_UNAVAILABLE' });
  expect(f.events).toEqual([]);
  expect(f.plans).toEqual([]);
  expect(await f.run()).toEqual({ state: 's3-cleared', overdue: false });
});
