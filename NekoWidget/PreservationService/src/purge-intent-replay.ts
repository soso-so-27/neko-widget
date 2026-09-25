import { ServiceError } from './contracts';
import { S3PurgeIntentStore, type PurgeIntentEvent,
  type PurgeIntentCursor } from './s3-purge-intent';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const unavailable = () => new ServiceError('PURGE_INTENT_REPLAY_UNAVAILABLE', 503);
const maxVersions = 10_000;

export type OwnerPurgeReplay = 'clear' | 'quarantined' | 'deleted';
export type OwnerPurgeIntentState = {
  intentId: string;
  stage: PurgeIntentEvent['stage'];
  ownerEpoch: number;
  inventoryGeneration: number;
  retentionEpisode: number;
  retentionRevision: number;
  dueAt: number;
  preparedAt: number;
  manifestSha256: string | null;
};
export type OwnerPurgeTimeline = { replay: OwnerPurgeReplay;
  intents: readonly OwnerPurgeIntentState[] };

/** A completed event is a deletion tombstone. An erasing or unmatched
 * prepared event can never re-enable an owner. An abort is valid only before
 * erasing. The caller must still compare this verdict with D1, billing and
 * identity state; `clear` alone never authorizes restore or sign-in.
 */
export function reconcileOwnerPurgeTimeline(ownerId: string,
  events: readonly PurgeIntentEvent[]): OwnerPurgeTimeline {
  if (!uuid.test(ownerId)) throw unavailable();
  const intents = new Map<string, Map<PurgeIntentEvent['stage'], PurgeIntentEvent>>();
  for (const event of events) {
    if (event.ownerId !== ownerId || !uuid.test(event.intentId)) throw unavailable();
    const stages = intents.get(event.intentId) ?? new Map();
    if (stages.has(event.stage)) throw unavailable();
    stages.set(event.stage, event);
    intents.set(event.intentId, stages);
  }
  let result: OwnerPurgeReplay = 'clear';
  const states: OwnerPurgeIntentState[] = [];
  for (const [intentId, stages] of intents) {
    const prepared = stages.get('prepared');
    const aborted = stages.get('aborted');
    const erasing = stages.get('erasing');
    const completed = stages.get('completed');
    if (!prepared || (aborted && (erasing || completed)) || (completed && !erasing)) {
      throw unavailable();
    }
    for (const event of stages.values()) {
      if (event.ownerEpoch !== prepared.ownerEpoch
        || event.inventoryGeneration !== prepared.inventoryGeneration
        || event.retentionEpisode !== prepared.retentionEpisode
        || event.retentionRevision !== prepared.retentionRevision
        || event.dueAt !== prepared.dueAt
        || event.recordedAt < prepared.recordedAt) throw unavailable();
    }
    if (aborted && aborted.recordedAt < prepared.recordedAt) throw unavailable();
    if (erasing && (!erasing.manifestSha256 || erasing.recordedAt < prepared.recordedAt)) {
      throw unavailable();
    }
    if (completed && (completed.manifestSha256 !== erasing?.manifestSha256
      || completed.recordedAt < erasing.recordedAt)) throw unavailable();
    if (completed) result = 'deleted';
    else if (result !== 'deleted' && !aborted) result = 'quarantined';
    const latest = completed ?? erasing ?? aborted ?? prepared;
    states.push({ intentId, stage: latest.stage, ownerEpoch: prepared.ownerEpoch,
      inventoryGeneration: prepared.inventoryGeneration,
      retentionEpisode: prepared.retentionEpisode,
      retentionRevision: prepared.retentionRevision, dueAt: prepared.dueAt,
      preparedAt: prepared.recordedAt,
      manifestSha256: latest.manifestSha256 });
  }
  return { replay: result,
    intents: states.sort((left, right) => left.intentId.localeCompare(right.intentId)) };
}

export function reconcileOwnerPurgeEvents(ownerId: string,
  events: readonly PurgeIntentEvent[]): OwnerPurgeReplay {
  return reconcileOwnerPurgeTimeline(ownerId, events).replay;
}

/** Full S3 version walk, including old versions and delete markers, before a
 * D1-loss recovery decision. Failure is not interpreted as an empty ledger.
 */
export async function loadOwnerPurgeTimeline(store: Pick<S3PurgeIntentStore,
  'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>,
  ownerId: string): Promise<OwnerPurgeTimeline> {
  if (!uuid.test(ownerId)) throw unavailable();
  const events: PurgeIntentEvent[] = [];
  const seenVersions = new Set<string>();
  const seenCursors = new Set<string>();
  let cursor: PurgeIntentCursor | undefined;
  try {
    for (;;) {
      const page = await store.listOwnerVersionsPage(ownerId, cursor);
      if (events.length + page.versions.length > maxVersions) throw unavailable();
      for (const version of page.versions) {
        if (version.deleteMarker || !version.key.startsWith(`purge/v1/${ownerId}/`)) {
          throw unavailable();
        }
        const identity = `${version.key}\0${version.versionId}`;
        if (seenVersions.has(identity)) throw unavailable();
        seenVersions.add(identity);
        const reference = await store.referenceForListedVersion(version);
        events.push(await store.readExact(reference));
      }
      if (!page.nextCursor) return reconcileOwnerPurgeTimeline(ownerId, events);
      const signature = `${page.nextCursor.keyMarker}\0${page.nextCursor.versionIdMarker ?? ''}`;
      if (seenCursors.has(signature)) throw unavailable();
      seenCursors.add(signature);
      cursor = page.nextCursor;
    }
  } catch { throw unavailable(); }
}

export async function loadOwnerPurgeReplay(store: Pick<S3PurgeIntentStore,
  'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>,
  ownerId: string): Promise<OwnerPurgeReplay> {
  return (await loadOwnerPurgeTimeline(store, ownerId)).replay;
}
