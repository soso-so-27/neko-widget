import { ServiceError } from './contracts';
import type { PurgeFence } from './owner-purge-fence';
import type { OwnerPurgeIntentLedger } from './owner-purge-intent-ledger';
import { loadOwnerPurgeTimeline, type OwnerPurgeIntentState,
  type OwnerPurgeTimeline } from './purge-intent-replay';
import type { S3PurgeIntentStore, PurgeIntentEvent } from './s3-purge-intent';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const unavailable = () => new ServiceError('OWNER_PURGE_ABORT_UNAVAILABLE', 503);
interface ClaimRow {
  state: string; owner_epoch: number; inventory_generation: number;
  retention_episode: number; retention_revision: number; due_at: number;
  claimed_at: number;
}

function requireAbortableTimeline(timeline: OwnerPurgeTimeline,
  fence: PurgeFence): OwnerPurgeIntentState {
  if (timeline.replay === 'deleted' || timeline.intents.some(item => item.intentId !== fence.fenceId
    && item.stage !== 'aborted')) throw unavailable();
  const own = timeline.intents.find(item => item.intentId === fence.fenceId);
  if (!own || !['prepared', 'aborted'].includes(own.stage)
    || own.ownerEpoch !== fence.ownerEpoch
    || own.inventoryGeneration !== fence.inventoryGeneration
    || own.retentionEpisode !== fence.candidate.episode
    || own.retentionRevision !== fence.candidate.revision
    || own.dueAt !== fence.candidate.dueAt || own.manifestSha256 !== null) throw unavailable();
  return own;
}

/** Reconciles a pre-deletion cancellation with the independent S3 ledger.
 * This stops at a durable `aborted` claim. It deliberately does NOT thaw the
 * owner or alter retention; a later release path must replay S3 again and
 * atomically invalidate notice evidence before enabling access.
 */
export class OwnerPurgeAbort {
  constructor(private readonly db: D1Database,
    private readonly store: Pick<S3PurgeIntentStore,
      'listOwnerVersionsPage' | 'referenceForListedVersion' | 'readExact'>,
    private readonly ledger: Pick<OwnerPurgeIntentLedger, 'append'>,
    private readonly now: () => number) {}

  async claimAndRecordAbort(fence: PurgeFence): Promise<void> {
    if (!fence || !uuid.test(fence.ownerId) || !uuid.test(fence.fenceId)
      || fence.candidate?.ownerId !== fence.ownerId) throw unavailable();
    try {
      const intent = requireAbortableTimeline(
        await loadOwnerPurgeTimeline(this.store, fence.ownerId), fence);
      // A D1 Time Travel restore can lose the local prepared reference while
      // the independently verified S3 event survives. Reconcile the same
      // immutable event before attempting the claim; never invent new bytes.
      await this.ledger.append({ version: 1, ownerId: fence.ownerId,
        intentId: fence.fenceId, stage: 'prepared', ownerEpoch: fence.ownerEpoch,
        inventoryGeneration: fence.inventoryGeneration,
        retentionEpisode: fence.candidate.episode,
        retentionRevision: fence.candidate.revision, dueAt: fence.candidate.dueAt,
        recordedAt: intent.preparedAt, manifestSha256: null });
      const read = () => this.db.prepare(`SELECT state,owner_epoch,inventory_generation,
        retention_episode,retention_revision,due_at,claimed_at
        FROM pa_purge_execution_claims WHERE owner_id=? AND intent_id=?`)
        .bind(fence.ownerId, fence.fenceId).first<ClaimRow>();
      let claim = await read();
      if (!claim) {
        const claimedAt = intent.stage === 'aborted' ? intent.recordedAt : this.now();
        if (!Number.isSafeInteger(claimedAt) || claimedAt < intent.preparedAt) throw unavailable();
        try {
          await this.db.prepare(`INSERT INTO pa_purge_execution_claims(owner_id,intent_id,state,
            owner_epoch,inventory_generation,retention_episode,retention_revision,due_at,
            manifest_sha256,claimed_at) VALUES(?,?,'aborting',?,?,?,?,?,NULL,?)`)
            .bind(fence.ownerId, fence.fenceId, fence.ownerEpoch,
              fence.inventoryGeneration, fence.candidate.episode,
              fence.candidate.revision, fence.candidate.dueAt, claimedAt).run();
        } catch { /* A concurrent claim is resolved by the following read. */ }
        claim = await read();
      }
      if (!claim || !['aborting', 'aborted'].includes(claim.state)
        || claim.owner_epoch !== fence.ownerEpoch
        || claim.inventory_generation !== fence.inventoryGeneration
        || claim.retention_episode !== fence.candidate.episode
        || claim.retention_revision !== fence.candidate.revision
        || claim.due_at !== fence.candidate.dueAt
        || !Number.isSafeInteger(claim.claimed_at)
        || claim.claimed_at < intent.preparedAt
        || (intent.stage === 'aborted' && claim.claimed_at !== intent.recordedAt)) {
        throw unavailable();
      }
      const event: PurgeIntentEvent = { version: 1, ownerId: fence.ownerId,
        intentId: fence.fenceId, stage: 'aborted', ownerEpoch: fence.ownerEpoch,
        inventoryGeneration: fence.inventoryGeneration,
        retentionEpisode: fence.candidate.episode,
        retentionRevision: fence.candidate.revision, dueAt: fence.candidate.dueAt,
        recordedAt: claim.claimed_at, manifestSha256: null };
      await this.ledger.append(event);
      const after = await loadOwnerPurgeTimeline(this.store, fence.ownerId);
      requireAbortableTimeline(after, fence);
      if (after.replay !== 'clear' || after.intents.find(item => item.intentId === fence.fenceId)
        ?.stage !== 'aborted') throw unavailable();
      if (claim.state === 'aborted') return;
      const finishedAt = this.now();
      if (!Number.isSafeInteger(finishedAt) || finishedAt < claim.claimed_at) throw unavailable();
      await this.db.prepare(`UPDATE pa_purge_execution_claims
        SET state='aborted',finished_at=? WHERE owner_id=? AND intent_id=?
        AND state='aborting' AND claimed_at=?`)
        .bind(finishedAt, fence.ownerId, fence.fenceId, claim.claimed_at).run();
      if ((await read())?.state !== 'aborted') throw unavailable();
    } catch { throw unavailable(); }
  }
}
