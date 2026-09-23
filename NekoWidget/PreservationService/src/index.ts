import { ServiceError, sha256, type IdentityVerifier } from './contracts';
import { DurableAuth } from './auth';
import { ArchiveStore, cleanupArchive } from './storage';
import { AppleIdentityVerifier, createAppleClientSecret } from './apple';
import { boundKeyWrapper, boundBillingAuthority, boundPhotoValidator } from './providers';
import { MembershipLinks } from './membership-links';
import { envelopeKeyCustody } from './key-custody';
import { readBoundedBody } from './bounded-body';
import { RetentionLedger } from './retention-ledger';

export interface Env {
  DB: D1Database; ARCHIVE: R2Bucket;
  PRESERVATION_ENABLED?: string; CLEANUP_ENABLED?: string; RETENTION_TRACKING_ENABLED?: string;
  IDENTITY_INDEX_SECRET?: string; APPLE_CREDENTIALS_JSON?: string;
  PRESERVATION_LINK_AUDIENCE?: string;
  OWNER_QUOTA_BYTES?: string; MAXIMUM_RECORDS?: string;
  KEY_WRAPPER?: Fetcher; KEY_WRAPPER_CALLER_SECRET?: string;
  MEMBERSHIP_AUTHORITY?: Fetcher; PHOTO_VALIDATOR?: Fetcher;
  REQUEST_LIMITER?: RateLimit;
}
export interface Services { auth: DurableAuth; archive: ArchiveStore; verifier: IdentityVerifier;
  membership?: MembershipLinks; retention?: RetentionLedger; }
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
  const auth = new DurableAuth({ db: env.DB, keys, identityIndexSecret: env.IDENTITY_INDEX_SECRET, now });
  const verifier = new AppleIdentityVerifier({ enabled: true, clientId: credentials.clientId,
    getClientSecret: () => createAppleClientSecret({ ...credentials, now }), takeChallenge: (input) => auth.takeChallenge(input), now });
  const membership = new MembershipLinks({ db: env.DB, auth, authority: boundBillingAuthority(env.MEMBERSHIP_AUTHORITY),
    audience: env.PRESERVATION_LINK_AUDIENCE, now });
  const archive = new ArchiveStore({ db: env.DB, bucket: env.ARCHIVE, keys, auth, now,
    membership, photos: boundPhotoValidator(env.PHOTO_VALIDATOR),
    quotaBytes: Number(env.OWNER_QUOTA_BYTES), maximumRecords: Number(env.MAXIMUM_RECORDS) });
  const retention = env.RETENTION_TRACKING_ENABLED === 'YES' ? new RetentionLedger(env.DB, now) : undefined;
  return { auth, archive, verifier, membership, ...(retention ? { retention } : {}) };
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      if (env.PRESERVATION_ENABLED !== 'YES') throw new ServiceError('PRESERVATION_DISABLED', 503);
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
    if (env.CLEANUP_ENABLED !== 'YES') return;
    if (!env.DB || !env.ARCHIVE) throw new ServiceError('PRESERVATION_NOT_CONFIGURED', 503);
    // Continue physical deletion even while sign-in or paid saving is disabled.
    await cleanupArchive({ db: env.DB, bucket: env.ARCHIVE, now: () => Date.now() });
    await env.DB.batch([
      env.DB.prepare(`DELETE FROM pa_membership_challenges WHERE challenge_id IN
        (SELECT challenge_id FROM pa_membership_challenges WHERE expires_at<=? LIMIT 100)`).bind(Date.now()),
      env.DB.prepare(`DELETE FROM pa_auth_challenges WHERE challenge_id IN
        (SELECT challenge_id FROM pa_auth_challenges WHERE expires_at<=? LIMIT 100)`).bind(Date.now()),
      env.DB.prepare(`DELETE FROM pa_sessions WHERE session_hash IN
        (SELECT session_hash FROM pa_sessions WHERE expires_at<=? LIMIT 100)`).bind(Date.now()),
    ]);
    // Billing outages pause the clock. This only records status; notification
    // and irreversible deletion remain separately gated and disabled.
    if (env.RETENTION_TRACKING_ENABLED === 'YES') {
      if (!env.MEMBERSHIP_AUTHORITY) throw new ServiceError('RETENTION_UNAVAILABLE', 503);
      await new RetentionLedger(env.DB, () => Date.now())
        .refreshBatch(boundBillingAuthority(env.MEMBERSHIP_AUTHORITY).status);
    }
  },
};
