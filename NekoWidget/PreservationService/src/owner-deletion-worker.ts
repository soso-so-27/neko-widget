import { type Env, configuredS3 } from './index';
import { OwnerDeletionExecutor } from './owner-deletion';
import { OwnerDeletionJournal } from './owner-deletion-journal';
import { S3VersionPurge } from './s3-version-purge';
import { AppleTokenRevoker } from './apple-revocation';
import { createAppleClientSecret } from './apple';
import { envelopeKeyCustody } from './key-custody';
import { boundKeyWrapper } from './providers';
import { ServiceError } from './contracts';

interface DeletionEnv extends Env {
  OWNER_DELETION_EXECUTOR_ENABLED?: string;
  ERASER_S3_ACCESS_KEY_ID?: string;
  ERASER_S3_SECRET_ACCESS_KEY?: string;
}

/** Separate, non-public Worker. The public archive Worker gets no permanent
 * version-delete credentials. Deployment is disabled until a bounded synthetic
 * owner exercise and the specific IAM privilege approval have succeeded.
 */
export default {
  fetch(): Response { return new Response(null, { status: 404 }); },
  async scheduled(_event: ScheduledEvent, env: DeletionEnv): Promise<void> {
    if (env.OWNER_DELETION_EXECUTOR_ENABLED !== 'YES') return;
    if (!env.DB || !env.ARCHIVE || !env.KEY_WRAPPER || !env.KEY_WRAPPER_CALLER_SECRET
      || !env.APPLE_CREDENTIALS_JSON) throw new ServiceError('OWNER_DELETION_NOT_CONFIGURED', 503);
    const now = () => Date.now();
    const credentials = JSON.parse(env.APPLE_CREDENTIALS_JSON) as {
      teamId: string; keyId: string; clientId: string; privateKey: string };
    const revoker = new AppleTokenRevoker({ enabled: true, clientId: credentials.clientId,
      getClientSecret: () => createAppleClientSecret({ ...credentials, now }) });
    const journal = new OwnerDeletionJournal(env.ARCHIVE);
    const executor = new OwnerDeletionExecutor({ enabled: true, db: env.DB,
      bucket: env.ARCHIVE, journal, now, recovery: configuredS3(env),
      keys: envelopeKeyCustody({ enabled: true,
        wrapper: boundKeyWrapper(env.KEY_WRAPPER, env.KEY_WRAPPER_CALLER_SECRET) }),
      revokeRefreshToken: token => revoker.revokeRefreshToken(token),
      versionPurge: new S3VersionPurge({ enabled: 'YES', region: env.RECOVERY_S3_REGION ?? '',
        bucket: env.RECOVERY_S3_BUCKET ?? '', expectedAccountId: env.RECOVERY_S3_ACCOUNT_ID ?? '',
        accessKeyId: env.ERASER_S3_ACCESS_KEY_ID ?? '', secretAccessKey: env.ERASER_S3_SECRET_ACCESS_KEY ?? '' }),
    });
    const started = now();
    let failed = false;
    // Resume the final receipt/index cleanup if the previous invocation died
    // after writing its external completion. A restored nonempty D1 image is
    // rejected for offline reconciliation, never advertised as fully erased.
    const remaining = await env.DB.prepare(`SELECT owner_id FROM pa_owner_deletion_requests
      ORDER BY requested_at LIMIT 10`).all<{ owner_id: string }>();
    for (const row of remaining.results) {
      const request = await journal.request(row.owner_id);
      if (request && await journal.stage(request, 'completed')) {
        try { await executor.step(row.owner_id); } catch { failed = true; }
      }
    }
    for (const request of await journal.pending(10)) {
      try {
        for (let step = 0; step < 48 && now() - started < 25_000; step++) {
          const result = await executor.step(request.ownerId);
          if (result === 'waiting') { failed = true; break; }
          if (result === 'completed') break;
        }
      } catch { failed = true; }
      if (now() - started >= 25_000) break;
    }
    if (failed) throw new ServiceError('OWNER_DELETION_RETRY_REQUIRED', 503);
  },
};
