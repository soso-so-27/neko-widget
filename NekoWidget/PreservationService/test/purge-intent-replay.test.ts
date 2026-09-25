import { expect, it } from 'vitest';
import { loadOwnerPurgeReplay, reconcileOwnerPurgeEvents } from '../src/purge-intent-replay';
import type { PurgeIntentEvent, PurgeIntentVersion,
  PurgeIntentVersionPage } from '../src/s3-purge-intent';

const ownerId = '00000000-0000-4000-8000-000000000001';
const intentId = '00000000-0000-4000-8000-000000000002';
const prepared: PurgeIntentEvent = { version: 1, ownerId, intentId, stage: 'prepared',
  ownerEpoch: 2, inventoryGeneration: 8, retentionEpisode: 1, retentionRevision: 4,
  dueAt: 1_800_000_000_000, recordedAt: 1_800_000_001_000, manifestSha256: null };
const erasing: PurgeIntentEvent = { ...prepared, stage: 'erasing',
  recordedAt: prepared.recordedAt + 1, manifestSha256: 'a'.repeat(64) };
const completed: PurgeIntentEvent = { ...erasing, stage: 'completed',
  recordedAt: erasing.recordedAt + 1 };

it('never opens an owner with an unmatched preparation or interrupted erasure', () => {
  expect(reconcileOwnerPurgeEvents(ownerId, [])).toBe('clear');
  expect(reconcileOwnerPurgeEvents(ownerId, [prepared])).toBe('quarantined');
  expect(reconcileOwnerPurgeEvents(ownerId, [prepared, erasing])).toBe('quarantined');
  expect(reconcileOwnerPurgeEvents(ownerId, [completed, prepared, erasing])).toBe('deleted');
  expect(reconcileOwnerPurgeEvents(ownerId, [prepared, { ...prepared, stage: 'aborted',
    recordedAt: prepared.recordedAt + 1 }])).toBe('clear');
});

it('rejects missing or contradictory transitions, changed owner evidence and duplicate versions', () => {
  for (const events of [
    [erasing], [prepared, completed], [prepared, erasing, erasing],
    [prepared, erasing, { ...prepared, stage: 'aborted' }],
    [prepared, { ...erasing, ownerEpoch: 3 }],
    [prepared, { ...erasing, manifestSha256: 'a'.repeat(64) },
      { ...completed, manifestSha256: 'b'.repeat(64) }],
    [prepared, { ...erasing, recordedAt: prepared.recordedAt - 1 }],
    [prepared, { ...erasing, ownerId: '00000000-0000-4000-8000-000000000099' }],
  ]) {
    expect(() => reconcileOwnerPurgeEvents(ownerId, events as PurgeIntentEvent[]))
      .toThrowError();
  }
});

it('reads every exact S3 version and fails closed on markers, repeated cursors and read errors', async () => {
  const key = `purge/v1/${ownerId}/${intentId}/prepared`;
  const item: PurgeIntentVersion = { key, versionId: 'v1', deleteMarker: false, bytes: 10 };
  let pages = 0;
  const store = {
    listOwnerVersionsPage: async (): Promise<PurgeIntentVersionPage> => {
      pages++;
      return { versions: [item], nextCursor: null };
    },
    referenceForListedVersion: async () => ({ key, versionId: 'v1', sha256: 'a'.repeat(64), bytes: 10 }),
    readExact: async () => prepared,
  };
  expect(await loadOwnerPurgeReplay(store, ownerId)).toBe('quarantined');
  expect(pages).toBe(1);
  const marked = { ...store, listOwnerVersionsPage: async () => ({ versions: [
    { ...item, deleteMarker: true, bytes: null }], nextCursor: null }) };
  await expect(loadOwnerPurgeReplay(marked, ownerId))
    .rejects.toMatchObject({ code: 'PURGE_INTENT_REPLAY_UNAVAILABLE' });
  const repeated = { ...store, listOwnerVersionsPage: async () => ({ versions: [item],
    nextCursor: { keyMarker: key, versionIdMarker: 'v1' } }) };
  await expect(loadOwnerPurgeReplay(repeated, ownerId))
    .rejects.toMatchObject({ code: 'PURGE_INTENT_REPLAY_UNAVAILABLE' });
  const broken = { ...store, readExact: async (): Promise<PurgeIntentEvent> => {
    throw Error('S3 read failed');
  } };
  await expect(loadOwnerPurgeReplay(broken, ownerId))
    .rejects.toMatchObject({ code: 'PURGE_INTENT_REPLAY_UNAVAILABLE' });
});
