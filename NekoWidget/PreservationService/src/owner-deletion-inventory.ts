import { WorkerEntrypoint } from 'cloudflare:workers';
import { timingSafeEqual } from 'node:crypto';
import { configuredS3, type Env } from './index';
import { OwnerDeletionJournal } from './owner-deletion-journal';
import { readBoundedBody } from './bounded-body';
import { ServiceError } from './contracts';
import type { S3RecoveryCopy, RecoveryVersionPage } from './s3-recovery-copy';

export type RecoveryInventoryReader = Pick<S3RecoveryCopy, 'listOwnerVersionsPage'>;
type Scope = { region: string; bucket: string; accountId: string };
const unavailable = () => new ServiceError('OWNER_DELETION_INVENTORY_UNAVAILABLE', 503);
const scope = (env: Env): Scope => ({ region: env.RECOVERY_S3_REGION ?? '',
  bucket: env.RECOVERY_S3_BUCKET ?? '', accountId: env.RECOVERY_S3_ACCOUNT_ID ?? '' });

export async function handleDeletionInventory(request: Request, env: Env,
  reader?: RecoveryInventoryReader): Promise<Response> {
  try {
    if (request.method !== 'POST' || new URL(request.url).pathname !== '/recovery/versions'
      || env.OWNER_DELETION_ENABLED !== 'YES') throw unavailable();
    const expected = env.KEY_WRAPPER_CALLER_SECRET ?? '';
    const actual = request.headers.get('x-neko-preservation-key-token') ?? '';
    if (!/^[A-Za-z0-9_-]{43,128}$/.test(expected) || actual.length !== expected.length
      || !timingSafeEqual(new TextEncoder().encode(actual), new TextEncoder().encode(expected))) throw unavailable();
    const bytes = await readBoundedBody(request.body, 2048, unavailable);
    const input = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (!input || typeof input.ownerId !== 'string'
      || Object.keys(input).some(k => !['ownerId', 'cursor'].includes(k))) throw unavailable();
    if (!await new OwnerDeletionJournal(env.ARCHIVE).request(input.ownerId)) throw unavailable();
    // Existing S3 code checks the canonical owner and owner-bound cursor.
    const page = await (reader ?? configuredS3(env)).listOwnerVersionsPage(input.ownerId, input.cursor);
    return Response.json({ ...scope(env), ...page }, { headers: { 'cache-control': 'no-store' } });
  } catch { return Response.json({ error: { code: 'OWNER_DELETION_INVENTORY_UNAVAILABLE' } }, { status: 503 }); }
}

/** No public route: only a named internal service binding may use this reader. */
export class OwnerDeletionInventory extends WorkerEntrypoint<Env> {
  override fetch(request: Request): Promise<Response> { return handleDeletionInventory(request, this.env); }
}

export function boundDeletionInventory(binding: Fetcher, callerSecret: string, expected: Scope): RecoveryInventoryReader {
  if (!/^[A-Za-z0-9_-]{43,128}$/.test(callerSecret)) throw unavailable();
  return { async listOwnerVersionsPage(ownerId, cursor): Promise<RecoveryVersionPage> {
    const response = await binding.fetch('https://preservation-internal/recovery/versions', {
      method: 'POST', headers: { 'content-type': 'application/json', 'x-neko-preservation-key-token': callerSecret },
      body: JSON.stringify({ ownerId, ...(cursor ? { cursor } : {}) }), redirect: 'manual',
      signal: AbortSignal.timeout(35_000),
    });
    if (!response.ok) throw unavailable();
    const bytes = await readBoundedBody(response.body, 2 * 1024 * 1024, unavailable);
    const result = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (!result || result.region !== expected.region || result.bucket !== expected.bucket
      || result.accountId !== expected.accountId || !Array.isArray(result.versions)
      || !Object.hasOwn(result, 'nextCursor')) throw unavailable();
    return { versions: result.versions, nextCursor: result.nextCursor };
  } };
}
