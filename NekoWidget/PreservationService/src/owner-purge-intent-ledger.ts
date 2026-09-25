import { ServiceError } from './contracts';
import { S3PurgeIntentStore, type PurgeIntentEvent,
  type PurgeIntentReference } from './s3-purge-intent';

const unavailable = () => new ServiceError('OWNER_PURGE_INTENT_UNAVAILABLE', 503);
interface EventRow {
  owner_id: string; intent_id: string; stage: string; owner_epoch: number;
  inventory_generation: number; retention_episode: number; retention_revision: number;
  due_at: number; recorded_at: number; manifest_sha256: string | null;
  s3_object_key: string; s3_version_id: string; s3_sha256: string; s3_bytes: number;
}

function matches(row: EventRow | null, event: PurgeIntentEvent,
  reference: PurgeIntentReference): boolean {
  return row !== null && row.owner_id === event.ownerId && row.intent_id === event.intentId
    && row.stage === event.stage && row.owner_epoch === event.ownerEpoch
    && row.inventory_generation === event.inventoryGeneration
    && row.retention_episode === event.retentionEpisode
    && row.retention_revision === event.retentionRevision && row.due_at === event.dueAt
    && row.recorded_at === event.recordedAt && row.manifest_sha256 === event.manifestSha256
    && row.s3_object_key === reference.key && row.s3_version_id === reference.versionId
    && row.s3_sha256 === reference.sha256 && row.s3_bytes === reference.bytes;
}

/** Stores only a reference after an exact-version S3 write and read-back.
 * A committed D1 row is not itself authority to fence or erase an owner;
 * those operations must independently recheck eligibility and replay S3.
 */
export class OwnerPurgeIntentLedger {
  constructor(private readonly db: D1Database,
    private readonly store: Pick<S3PurgeIntentStore, 'putOnce'>) {}

  async append(event: PurgeIntentEvent): Promise<PurgeIntentReference> {
    const reference = await this.store.putOnce(event);
    if (reference.key !== `purge/v1/${event.ownerId}/${event.intentId}/${event.stage}`
      || !Number.isSafeInteger(reference.bytes) || reference.bytes < 1
      || !/^[0-9a-f]{64}$/u.test(reference.sha256)
      || !reference.versionId || reference.versionId === 'null') throw unavailable();
    try {
      const select = () => this.db.prepare(`SELECT * FROM pa_owner_purge_events
        WHERE owner_id=? AND intent_id=? AND stage=?`)
        .bind(event.ownerId, event.intentId, event.stage).first<EventRow>();
      const existing = await select();
      if (existing) {
        if (!matches(existing, event, reference)) throw unavailable();
        return reference;
      }
      await this.db.prepare(`INSERT INTO pa_owner_purge_events(owner_id,intent_id,stage,
        owner_epoch,inventory_generation,retention_episode,retention_revision,due_at,recorded_at,
        manifest_sha256,s3_object_key,s3_version_id,s3_sha256,s3_bytes)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
        .bind(event.ownerId, event.intentId, event.stage, event.ownerEpoch,
          event.inventoryGeneration, event.retentionEpisode, event.retentionRevision,
          event.dueAt, event.recordedAt, event.manifestSha256, reference.key,
          reference.versionId, reference.sha256, reference.bytes).run();
      const row = await select();
      if (!matches(row, event, reference)) throw unavailable();
      return reference;
    } catch { throw unavailable(); }
  }
}
