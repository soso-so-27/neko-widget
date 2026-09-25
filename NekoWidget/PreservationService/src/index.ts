import { ServiceError, sha256, type IdentityVerifier } from './contracts';
import { DurableAuth } from './auth';
import { ArchiveStore, cleanupArchive } from './storage';
import { AppleIdentityVerifier, createAppleClientSecret } from './apple';
import { boundKeyWrapper, boundBillingAuthority, boundPhotoValidator } from './providers';
import { MembershipLinks } from './membership-links';
import { envelopeKeyCustody } from './key-custody';
import { readBoundedBody } from './bounded-body';
import { RetentionLedger, type VerifiedMembershipStatus } from './retention-ledger';
import { NoticeSubmissions, validNoticeEventSource } from './notice-submissions';
import { NoticeDispatch, type NoticeMailProvider } from './notice-dispatch';
import { type NoticeEventSource } from './notice-events';
import { processDeliveredNoticeEvent } from './notice-delivery';
import { S3RecoveryCopy } from './s3-recovery-copy';
import { RecordRecoveryCopy } from './record-recovery-copy';
import { OwnerRecoveryCopy } from './owner-recovery-copy';

export interface Env {
  DB: D1Database; ARCHIVE: R2Bucket;
  PRESERVATION_ENABLED?: string; CLEANUP_ENABLED?: string; RETENTION_TRACKING_ENABLED?: string;
  RECOVERY_BACKFILL_ENABLED?: string;
  NOTICE_SEND_ENABLED?: string; NOTICE_EVENTS_ENABLED?: string;
  NOTICE_RECIPIENT_TAG_SECRET?: string; NOTICE_EVENT_QUEUE_NAME?: string;
  NOTICE_ACCOUNT_ID?: string; NOTICE_ZONE_ID?: string; NOTICE_SUBSCRIPTION_ID?: string;
  NOTICE_DOMAIN?: string; NOTICE_SENDER?: string; NOTICE_EMAIL?: NoticeMailProvider;
  IDENTITY_INDEX_SECRET?: string; APPLE_CREDENTIALS_JSON?: string;
  PRESERVATION_LINK_AUDIENCE?: string;
  OWNER_QUOTA_BYTES?: string; MAXIMUM_RECORDS?: string;
  GLOBAL_ACTIVE_STORAGE_LIMIT_BYTES?: string;
  RECOVERY_COPY_ENABLED?: string; RECOVERY_S3_REGION?: string; RECOVERY_S3_BUCKET?: string;
  RECOVERY_S3_ACCOUNT_ID?: string; RECOVERY_S3_ACCESS_KEY_ID?: string;
  RECOVERY_S3_SECRET_ACCESS_KEY?: string; RECOVERY_S3_SESSION_TOKEN?: string;
  KEY_WRAPPER?: Fetcher; KEY_WRAPPER_CALLER_SECRET?: string;
  MEMBERSHIP_AUTHORITY?: Fetcher; PHOTO_VALIDATOR?: Fetcher;
  REQUEST_LIMITER?: RateLimit;
}
export interface Services { auth: DurableAuth; archive: ArchiveStore; verifier: IdentityVerifier;
  membership?: MembershipLinks; retention?: RetentionLedger; ownerRecovery?: OwnerRecoveryCopy; }
interface NoticeServices { auth: DurableAuth; retention: RetentionLedger;
  ownerRecovery: OwnerRecoveryCopy;
  statusForOwner: (ownerId: string) => Promise<VerifiedMembershipStatus>; }
const headers = { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };
const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
const string = (value: unknown) => {
  if (typeof value !== 'string' || !value || value.length > 20_000) throw new ServiceError('INVALID_REQUEST');
  return value;
};
async function body(request: Request, maximum: number): Promise<Record<string, unknown>> {
  if (request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/json' || !request.body) {
    throw new ServiceError('INVALID_REQUEST');
  }
  try {
    const merged = await readBoundedBody(request.body, maximum, () => new ServiceError('INVALID_REQUEST'), request.signal,
      () => new ServiceError('REQUEST_TOO_LARGE', 413));
    const parsed: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(merged));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error();
    return parsed as Record<string, unknown>;
  } catch (error) {
    if (error instanceof ServiceError) throw error;
    throw new ServiceError('INVALID_REQUEST');
  }
}
const bearer = (request: Request) => {
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get('authorization') ?? '');
  if (!match?.[1]) throw new ServiceError('SESSION_INVALID', 401);
  return match[1];
};

function configuredS3(env: Env): S3RecoveryCopy {
  return new S3RecoveryCopy({ enabled: env.RECOVERY_COPY_ENABLED ?? '',
    region: env.RECOVERY_S3_REGION ?? '', bucket: env.RECOVERY_S3_BUCKET ?? '',
    expectedAccountId: env.RECOVERY_S3_ACCOUNT_ID ?? '',
    accessKeyId: env.RECOVERY_S3_ACCESS_KEY_ID ?? '',
    secretAccessKey: env.RECOVERY_S3_SECRET_ACCESS_KEY ?? '',
    ...(env.RECOVERY_S3_SESSION_TOKEN ? { sessionToken: env.RECOVERY_S3_SESSION_TOKEN } : {}),
  });
}

// Local tests inject dependencies. The public Worker always checks the gate.
export async function route(request: Request, services: Services): Promise<Response> {
  const url = new URL(request.url);
  if (url.protocol !== 'https:') throw new ServiceError('HTTPS_REQUIRED');
  const path = url.pathname;
  if (path !== '/v1/records' && url.search) throw new ServiceError('INVALID_REQUEST');
  if (request.method === 'POST' && path === '/v1/auth/challenges') {
    if (Object.keys(await body(request, 1024)).length) throw new ServiceError('INVALID_REQUEST');
    return response(await services.auth.issueChallenge());
  }
  if (request.method === 'POST' && path === '/v1/auth/sessions') {
    const input = await body(request, 64 * 1024);
    if (Object.keys(input).some((key) => !['challengeId', 'challengeProof', 'identityToken', 'authorizationCode'].includes(key))) {
      throw new ServiceError('INVALID_REQUEST');
    }
    const verified = await services.verifier.verifyNativeAuthorization({ challengeId: string(input.challengeId),
      challengeProof: string(input.challengeProof), identityToken: string(input.identityToken), authorizationCode: string(input.authorizationCode) });
    return response(await services.auth.establish(verified));
  }
  const token = bearer(request);
  if (request.method === 'GET' && path === '/v1/notice-contact') {
    return response({ version: 1, ...await services.auth.noticeContact(token) });
  }
  if (request.method === 'GET' && path === '/v1/retention') {
    if (!services.membership || !services.retention) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
    const session = await services.auth.requireSession(token);
    const membership = await services.membership.statusForRetention(session.ownerId);
    if (!membership.linked) {
      await services.auth.requireSession(token);
      return response({ version: 1, status: 'unlinked', dueAt: null, paused: false });
    }
    const state = await services.retention.observe(session.ownerId, membership.status);
    const current = await services.auth.requireSession(token);
    if (current.ownerId !== session.ownerId || current.sessionHash !== session.sessionHash) {
      throw new ServiceError('SESSION_INVALID', 401);
    }
    return response({ version: 1, status: state.status,
      dueAt: state.status === 'expired' && state.pausedAt === null ? state.dueAt : null,
      paused: state.pausedAt !== null,
      finalNoticeDeliveredAt: state.finalNoticeDeliveredAt });
  }
  if (request.method === 'GET' && path === '/v1/usage') {
    return response(await services.archive.usage(token));
  }
  if (path === '/v1/membership' || path.startsWith('/v1/membership/')) {
    if (!services.membership) throw new ServiceError('MEMBERSHIP_NOT_CONFIGURED', 503);
    if (request.method === 'GET' && path === '/v1/membership') {
      return response(await services.membership.forSession(token));
    }
    if (request.method === 'POST' && path === '/v1/membership/challenges') {
      const input = await body(request, 1024);
      if (Object.keys(input).join(',') !== 'billingAccountId') throw new ServiceError('INVALID_REQUEST');
      return response(await services.membership.issue(token, input.billingAccountId));
    }
    if (request.method === 'POST' && path === '/v1/membership/link') {
      const input = await body(request, 4096);
      if (Object.keys(input).sort().join(',') !== 'challengeId,proof') throw new ServiceError('INVALID_REQUEST');
      return response(await services.membership.complete(token, input.challengeId, input.proof));
    }
    throw new ServiceError('NOT_FOUND', 404);
  }
  if (request.method === 'DELETE' && path === '/v1/auth/session') {
    await services.auth.revokeSession(token);
    return new Response(null, { status: 204, headers: { 'cache-control': 'no-store' } });
  }
  if (request.method === 'GET' && path === '/v1/records') {
    for (const [key] of url.searchParams) if (!['after', 'limit'].includes(key) || url.searchParams.getAll(key).length !== 1) {
      throw new ServiceError('INVALID_REQUEST');
    }
    const limit = url.searchParams.get('limit') ?? '20';
    if (!/^\d{1,2}$/.test(limit)) throw new ServiceError('INVALID_PAGE_SIZE');
    return response(await services.archive.list(token, url.searchParams.get('after') ?? '', Number(limit)));
  }
  const id = /^\/v1\/records\/([0-9a-f-]+)$/.exec(path)?.[1];
  if (id && request.method === 'GET') return response(await services.archive.read(token, id));
  if (id && request.method === 'PUT') return response(await services.archive.put(token, id, await body(request, 29 * 1024 * 1024)));
  if (id && request.method === 'DELETE') {
    const revision = request.headers.get('if-match');
    if (!revision || !/^\d+$/.test(revision)) throw new ServiceError('INVALID_REVISION');
    return response(await services.archive.remove(token, id, Number(revision)));
  }
  throw new ServiceError('NOT_FOUND', 404);
}

function configuredServices(env: Env): Services {
  if (!env.KEY_WRAPPER || !env.KEY_WRAPPER_CALLER_SECRET || !env.MEMBERSHIP_AUTHORITY
    || !env.PHOTO_VALIDATOR || !env.IDENTITY_INDEX_SECRET
    || !env.APPLE_CREDENTIALS_JSON || !env.PRESERVATION_LINK_AUDIENCE || !env.REQUEST_LIMITER || !env.DB || !env.ARCHIVE) {
    throw new ServiceError('PRESERVATION_NOT_CONFIGURED', 503);
  }
  let credentials: { teamId: string; keyId: string; clientId: string; privateKey: string };
  try { credentials = JSON.parse(env.APPLE_CREDENTIALS_JSON) as typeof credentials; }
  catch { throw new ServiceError('PRESERVATION_NOT_CONFIGURED', 503); }
  const now = () => Date.now();
  const keys = envelopeKeyCustody({ enabled: true,
    wrapper: boundKeyWrapper(env.KEY_WRAPPER, env.KEY_WRAPPER_CALLER_SECRET) });
  let recovery: RecordRecoveryCopy | undefined;
  let ownerRecovery: OwnerRecoveryCopy | undefined;
  try {
    const s3 = configuredS3(env);
    recovery = new RecordRecoveryCopy(keys, s3);
    ownerRecovery = new OwnerRecoveryCopy(keys, s3, env.IDENTITY_INDEX_SECRET);
  } catch {
    // Bad or missing S3 setup must stop mutations, not strand an owner's read/export.
  }
  const auth = new DurableAuth({ db: env.DB, keys, identityIndexSecret: env.IDENTITY_INDEX_SECRET, now,
    ...(ownerRecovery ? { ownerRecovery } : {}), requireOwnerRecovery: true });
  const verifier = new AppleIdentityVerifier({ enabled: true, clientId: credentials.clientId,
    getClientSecret: () => createAppleClientSecret({ ...credentials, now }), takeChallenge: (input) => auth.takeChallenge(input), now });
  const membership = new MembershipLinks({ db: env.DB, auth, authority: boundBillingAuthority(env.MEMBERSHIP_AUTHORITY),
    audience: env.PRESERVATION_LINK_AUDIENCE, now,
    ...(ownerRecovery ? { ownerRecovery } : {}), requireOwnerRecovery: true });
  const archive = new ArchiveStore({ db: env.DB, bucket: env.ARCHIVE, keys, auth, now,
    membership, photos: boundPhotoValidator(env.PHOTO_VALIDATOR),
    quotaBytes: Number(env.OWNER_QUOTA_BYTES), maximumRecords: Number(env.MAXIMUM_RECORDS),
    ...(env.GLOBAL_ACTIVE_STORAGE_LIMIT_BYTES === undefined ? {}
      : { globalActiveBytesLimit: Number(env.GLOBAL_ACTIVE_STORAGE_LIMIT_BYTES) }),
    requireGlobalAdmissionLimit: true,
    ...(recovery ? { recovery } : {}), ...(ownerRecovery ? { ownerRecovery } : {}),
    requireRecovery: true, requireOwnerRecovery: true });
  const retention = env.RETENTION_TRACKING_ENABLED === 'YES' && ownerRecovery
    ? new RetentionLedger(env.DB, now, ownerRecovery) : undefined;
  return { auth, archive, verifier, membership, ...(retention ? { retention } : {}),
    ...(ownerRecovery ? { ownerRecovery } : {}) };
}

/** Delivery evidence must remain processable while unrelated photo upload,
 * HTTP rate limiting, or Apple-login configuration is unavailable.
 */
function configuredNoticeServices(env: Env): NoticeServices {
  if (!env.DB || !env.KEY_WRAPPER || !env.KEY_WRAPPER_CALLER_SECRET
      || !env.IDENTITY_INDEX_SECRET || !env.MEMBERSHIP_AUTHORITY) {
    throw new ServiceError('NOTICE_NOT_CONFIGURED', 503);
  }
  const now = () => Date.now();
  const keys = envelopeKeyCustody({ enabled: true,
    wrapper: boundKeyWrapper(env.KEY_WRAPPER, env.KEY_WRAPPER_CALLER_SECRET) });
  const ownerRecovery = new OwnerRecoveryCopy(keys, configuredS3(env), env.IDENTITY_INDEX_SECRET);
  const auth = new DurableAuth({ db: env.DB, keys, identityIndexSecret: env.IDENTITY_INDEX_SECRET, now });
  const authority = boundBillingAuthority(env.MEMBERSHIP_AUTHORITY);
  return { auth, retention: new RetentionLedger(env.DB, now, ownerRecovery), ownerRecovery,
    statusForOwner: async ownerId => {
      const link = await env.DB.prepare(`SELECT l.billing_account_id FROM pa_membership_links l
        JOIN pa_owners o ON o.owner_id=l.owner_id WHERE l.owner_id=? AND o.disabled=0`)
        .bind(ownerId).first<{ billing_account_id: string }>();
      if (!link) return 'unknown';
      try { return await authority.status(link.billing_account_id); }
      catch { return 'unknown'; }
    } };
}

function configuredNoticeSource(env: Env): NoticeEventSource {
  const source = { accountId: env.NOTICE_ACCOUNT_ID ?? '', zoneId: env.NOTICE_ZONE_ID ?? '',
    subscriptionId: env.NOTICE_SUBSCRIPTION_ID ?? '', domain: env.NOTICE_DOMAIN ?? '',
    sender: env.NOTICE_SENDER ?? '' };
  if (!validNoticeEventSource(source)) throw new ServiceError('NOTICE_NOT_CONFIGURED', 503);
  return source;
}

function configuredNoticeSubmissions(env: Env, ownerRecovery: OwnerRecoveryCopy): NoticeSubmissions {
  if (!env.DB || !env.NOTICE_RECIPIENT_TAG_SECRET) throw new ServiceError('NOTICE_NOT_CONFIGURED', 503);
  return new NoticeSubmissions(env.DB, env.NOTICE_RECIPIENT_TAG_SECRET,
    () => Date.now(), ownerRecovery);
}

async function reconcileDeliveredNotices(env: Env, services: NoticeServices): Promise<number> {
  if (!env.MEMBERSHIP_AUTHORITY) throw new ServiceError('NOTICE_NOT_CONFIGURED', 503);
  const submissions = configuredNoticeSubmissions(env, services.ownerRecovery);
  const authority = boundBillingAuthority(env.MEMBERSHIP_AUTHORITY);
  let failed = 0;
  const pending = await submissions.nextPendingPromotions();
  for (const item of pending) {
    try {
      await submissions.promoteDelivered(item.messageId,
        candidate => services.auth.verifiedNoticeContactForCandidate(candidate),
        accountId => authority.status(accountId));
    } catch {
      // One corrupt or temporarily unreadable contact must not starve later
      // notices. Leave this row unpromoted and surface failure after the scan.
      failed++;
    }
  }
  return failed;
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      if (env.PRESERVATION_ENABLED !== 'YES') throw new ServiceError('PRESERVATION_DISABLED', 503);
      const policy = await env.DB?.prepare(`SELECT delete_intent_required,owner_snapshot_required
        FROM pa_recovery_write_policy WHERE singleton=1`)
        .first<{ delete_intent_required: number; owner_snapshot_required: number }>();
      if (policy?.delete_intent_required !== 1 || policy.owner_snapshot_required !== 1) {
        throw new ServiceError('RECOVERY_POLICY_INACTIVE', 503);
      }
      const services = configuredServices(env);
      const ip = request.headers.get('CF-Connecting-IP');
      if (!ip) throw new ServiceError('REQUEST_IDENTITY_UNCONFIRMED', 403);
      const permitted = await env.REQUEST_LIMITER!.limit({ key: await sha256(`preservation:${ip}`) });
      if (!permitted.success) throw new ServiceError('RATE_LIMITED', 429);
      return await route(request, services);
    } catch (error) {
      return error instanceof ServiceError ? response({ error: { code: error.code } }, error.status)
        : response({ error: { code: 'PRESERVATION_UNAVAILABLE' } }, 503);
    }
  },
  async scheduled(_event: ScheduledEvent, env: Env): Promise<void> {
    if (env.NOTICE_SEND_ENABLED === 'YES' && (env.CLEANUP_ENABLED !== 'YES'
        || env.RETENTION_TRACKING_ENABLED !== 'YES' || env.NOTICE_EVENTS_ENABLED !== 'YES'
        || env.PRESERVATION_ENABLED !== 'YES')) throw new ServiceError('NOTICE_NOT_CONFIGURED', 503);
    if (!env.DB) {
      if (env.CLEANUP_ENABLED === 'YES' || env.RECOVERY_BACKFILL_ENABLED === 'YES'
        || env.PRESERVATION_ENABLED === 'YES') throw new ServiceError('PRESERVATION_NOT_CONFIGURED', 503);
      return;
    }
    let maintenanceFailures = 0;
    // Once owner snapshots are required, a D1 commit that outlived an S3
    // outage must be retried even if the one-time record backfill is off.
    let ownerRecoveryRequired = false;
    try {
      const policy = await env.DB.prepare(`SELECT owner_snapshot_required FROM pa_recovery_write_policy
        WHERE singleton=1`).first<{ owner_snapshot_required: number }>();
      if (!policy || ![0, 1].includes(policy.owner_snapshot_required)) throw new Error('invalid policy');
      ownerRecoveryRequired = policy.owner_snapshot_required === 1;
    } catch { maintenanceFailures++; }
    if (ownerRecoveryRequired || env.RECOVERY_BACKFILL_ENABLED === 'YES') {
      try {
        const services = configuredServices(env);
        if (!services.ownerRecovery) throw new ServiceError('OWNER_RECOVERY_UNAVAILABLE', 503);
        if (env.RECOVERY_BACKFILL_ENABLED === 'YES') {
          const records = await services.archive.repairRecoveryBatch();
          maintenanceFailures += records.failed;
        }
        const owners = await services.ownerRecovery.repairBatch(env.DB, Date.now());
        maintenanceFailures += owners.failed;
      } catch { maintenanceFailures++; }
    }
    // Backup repair continues when public sign-in and cleanup are off. A
    // transient S3 failure must not leave a D1-only generation indefinitely.
    if (env.CLEANUP_ENABLED !== 'YES') {
      if (maintenanceFailures > 0) throw new ServiceError('PRESERVATION_UNAVAILABLE', 503);
      return;
    }
    // Never thaw a fenced owner from D1 alone. Time Travel can roll back a
    // deletion claim while the independent S3 erasing event still exists.
    // A future release path must replay S3 before re-enabling access.
    if (env.ARCHIVE) {
      try { await cleanupArchive({ db: env.DB, bucket: env.ARCHIVE, now: () => Date.now() }); }
      catch { maintenanceFailures++; }
    } else maintenanceFailures++;
    try {
      await env.DB.batch([
        env.DB.prepare(`DELETE FROM pa_membership_challenges WHERE challenge_id IN
          (SELECT challenge_id FROM pa_membership_challenges WHERE expires_at<=? LIMIT 100)`).bind(Date.now()),
        env.DB.prepare(`DELETE FROM pa_auth_challenges WHERE challenge_id IN
          (SELECT challenge_id FROM pa_auth_challenges WHERE expires_at<=? LIMIT 100)`).bind(Date.now()),
        env.DB.prepare(`DELETE FROM pa_sessions WHERE session_hash IN
          (SELECT session_hash FROM pa_sessions WHERE expires_at<=? LIMIT 100)`).bind(Date.now()),
      ]);
    } catch { maintenanceFailures++; }
    // Billing outages pause the clock. This only records status; notification
    // and irreversible deletion remain separately gated and disabled.
    if (env.RETENTION_TRACKING_ENABLED === 'YES') {
      if (!env.MEMBERSHIP_AUTHORITY) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
      try {
        await configuredNoticeServices(env).retention
          .refreshBatch(boundBillingAuthority(env.MEMBERSHIP_AUTHORITY).status);
      } catch { maintenanceFailures++; }
    }
    if (env.NOTICE_EVENTS_ENABLED === 'YES') {
      if (env.RETENTION_TRACKING_ENABLED !== 'YES') throw new ServiceError('NOTICE_NOT_CONFIGURED', 503);
      const services = configuredNoticeServices(env);
      const reconciliationFailures = await reconcileDeliveredNotices(env, services);
      let dispatchFailures = 0;
      if (env.NOTICE_SEND_ENABLED === 'YES') {
        if (!env.NOTICE_EMAIL) {
          throw new ServiceError('NOTICE_NOT_CONFIGURED', 503);
        }
        const result = await new NoticeDispatch({ ledger: services.retention,
          submissions: configuredNoticeSubmissions(env, services.ownerRecovery),
          source: configuredNoticeSource(env),
          mail: env.NOTICE_EMAIL,
          statusForOwner: services.statusForOwner,
          currentContact: candidate => services.auth.verifiedNoticeContactForCandidate(candidate),
        }).run();
        dispatchFailures = result.failed;
      }
      if (reconciliationFailures + dispatchFailures + maintenanceFailures > 0) {
        throw new ServiceError('NOTICE_SEND_UNAVAILABLE', 503);
      }
    }
    if (maintenanceFailures > 0) throw new ServiceError('PRESERVATION_UNAVAILABLE', 503);
  },
  async queue(batch: MessageBatch<unknown>, env: Env): Promise<void> {
    if (env.NOTICE_EVENTS_ENABLED !== 'YES' || env.RETENTION_TRACKING_ENABLED !== 'YES'
        || !env.NOTICE_EVENT_QUEUE_NAME || batch.queue !== env.NOTICE_EVENT_QUEUE_NAME) {
      batch.retryAll({ delaySeconds: 3600 });
      return;
    }
    let services: NoticeServices;
    let submissions: NoticeSubmissions;
    let source: NoticeEventSource;
    try {
      services = configuredNoticeServices(env);
      submissions = configuredNoticeSubmissions(env, services.ownerRecovery);
      source = configuredNoticeSource(env);
      if (!env.MEMBERSHIP_AUTHORITY) throw new ServiceError('NOTICE_NOT_CONFIGURED', 503);
    } catch {
      batch.retryAll({ delaySeconds: 3600 });
      return;
    }
    const authority = boundBillingAuthority(env.MEMBERSHIP_AUTHORITY!);
    for (const message of batch.messages) {
      try {
        await processDeliveredNoticeEvent(message.body, { source, submissions,
          ledger: services.retention, now: () => Date.now(),
          statusForOwner: services.statusForOwner,
          statusForBillingAccount: accountId => authority.status(accountId),
          currentContact: candidate => services.auth.verifiedNoticeContactForCandidate(candidate),
        });
        message.ack();
      } catch {
        message.retry({ delaySeconds: 300 });
      }
    }
  },
};
