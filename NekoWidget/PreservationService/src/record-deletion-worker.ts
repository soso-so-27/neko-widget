import { configuredS3, type Env } from './index';
import { envelopeKeyCustody } from './key-custody';
import { boundKeyWrapper } from './providers';
import { RecordRecoveryCopy } from './record-recovery-copy';
import { OwnerRecoveryCopy } from './owner-recovery-copy';
import { OwnerArchiveRecovery } from './owner-archive-recovery';
import { RecordPhysicalDeletion, type RecordDeletionJob } from './record-physical-deletion';
import { S3VersionPurge } from './s3-version-purge';
import { ServiceError, sha256 } from './contracts';

interface RecordErasureEnv extends Env {
  RECORD_PHYSICAL_DELETION_ENABLED?: string;
  RECORD_PHYSICAL_DELETION_REVIEW_OFFSET?: string;
  RECORD_PHYSICAL_DELETION_REVIEW_SCOPE_SHA256?: string;
  ERASER_S3_ACCESS_KEY_ID?: string;
  ERASER_S3_SECRET_ACCESS_KEY?: string;
  ERASER_S3_SESSION_TOKEN?: string;
}
const dayMs = 86_400_000;

// A separate worker gets permanent-version deletion credentials. The app's
// Worker continues to write the queue and has no permanent deletion capability.
export default {
  fetch(): Response { return new Response(null, { status: 404 }); },
  async scheduled(_event: ScheduledEvent, env: RecordErasureEnv): Promise<void> {
    const enabled = env.RECORD_PHYSICAL_DELETION_ENABLED === 'YES';
    const review = env.RECORD_PHYSICAL_DELETION_REVIEW_OFFSET;
    if (!enabled && review === undefined) return;
    const unavailable = () => new ServiceError('RECORD_ERASURE_NOT_CONFIGURED', 503);
    if (review !== undefined && (enabled || env.RECORD_PHYSICAL_DELETION_ENABLED !== 'NO'
      || !/^(?:[0-9]|1[0-2])$/u.test(review)
      || !/^[a-f0-9]{64}$/u.test(env.RECORD_PHYSICAL_DELETION_REVIEW_SCOPE_SHA256 ?? ''))) throw unavailable();
    if (!env.KEY_WRAPPER || !env.KEY_WRAPPER_CALLER_SECRET || !env.IDENTITY_INDEX_SECRET
      || !env.ARCHIVE || !env.DB || (enabled && env.ERASER_S3_ACCESS_KEY_ID === env.RECOVERY_S3_ACCESS_KEY_ID)) {
      throw unavailable();
    }
    const s3 = configuredS3(env);
    const keys = envelopeKeyCustody({ enabled: true,
      wrapper: boundKeyWrapper(env.KEY_WRAPPER, env.KEY_WRAPPER_CALLER_SECRET) });
    const records = new RecordRecoveryCopy(keys, s3);
    const owners = new OwnerRecoveryCopy(keys, s3, env.IDENTITY_INDEX_SECRET);
    const executor = new RecordPhysicalDeletion({ db: env.DB, bucket: env.ARCHIVE, records,
      archive: new OwnerArchiveRecovery(s3, owners, records), inventory: s3, now: Date.now,
      ...(enabled ? { eraser: new S3VersionPurge({ enabled: 'YES', region: env.RECOVERY_S3_REGION ?? '',
        bucket: env.RECOVERY_S3_BUCKET ?? '', expectedAccountId: env.RECOVERY_S3_ACCOUNT_ID ?? '',
        accessKeyId: env.ERASER_S3_ACCESS_KEY_ID ?? '', secretAccessKey: env.ERASER_S3_SECRET_ACCESS_KEY ?? '',
        ...(env.ERASER_S3_SESSION_TOKEN ? { sessionToken: env.ERASER_S3_SESSION_TOKEN } : {}) }) } : {}),
    });
    if (review !== undefined) {
      // Review removes no object and does not claim, retry or close queue rows.
      const ordinal = Number(review);
      const scope = await env.DB.prepare(`SELECT owner_id,record_id,tombstone_revision,requested_at
        FROM pa_record_physical_delete_queue ORDER BY requested_at,owner_id,record_id LIMIT 14`).all<RecordDeletionJob>();
      if (scope.results.length !== 13 || await sha256(JSON.stringify(scope.results.map(item => [
        item.owner_id,item.record_id,item.tombstone_revision,item.requested_at,
      ]))) !== env.RECORD_PHYSICAL_DELETION_REVIEW_SCOPE_SHA256) throw unavailable();
      const result = await executor.review(scope.results[ordinal]!);
      console.info(JSON.stringify({ event: 'preservation_record_erasure_review_v1', ordinal, ...result }));
      return;
    }
    const now = Date.now();
    const job = await env.DB.prepare(`UPDATE pa_record_physical_delete_queue SET next_attempt_at=?
      WHERE rowid=(SELECT rowid FROM pa_record_physical_delete_queue WHERE next_attempt_at<=?
        ORDER BY next_attempt_at,requested_at,owner_id,record_id LIMIT 1)
      RETURNING owner_id,record_id,tombstone_revision,requested_at`)
      .bind(now+15*60_000,now).first<RecordDeletionJob>();
    if (!job) return;
    const age = now-job.requested_at;
    let status: string = 'blocked';
    try { status = await executor.step(job); }
    finally {
      const event = JSON.stringify({ event: 'preservation_record_erasure_v1', status,
        ageSeconds: Math.floor(age/1000), targetExceeded: age>=7*dayMs, deadlineExceeded: age>=30*dayMs });
      if (status === 'blocked' || age>=7*dayMs) console.warn(event); else console.info(event);
    }
  },
};
