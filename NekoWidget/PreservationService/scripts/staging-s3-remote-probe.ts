// Temporary private staging entrypoint. Deploy only inside the guarded S3 probe
// window, then restore src/index.ts. No route or workers.dev URL is configured.
import { S3RecoveryCopy } from '../src/s3-recovery-copy';

interface Env {
  PRESERVATION_ENABLED?: string; CLEANUP_ENABLED?: string; RECOVERY_COPY_ENABLED?: string;
  RECOVERY_S3_REGION?: string; RECOVERY_S3_BUCKET?: string; RECOVERY_S3_ACCOUNT_ID?: string;
  RECOVERY_S3_ACCESS_KEY_ID?: string; RECOVERY_S3_SECRET_ACCESS_KEY?: string;
  RECOVERY_S3_SESSION_TOKEN?: string; STAGING_S3_PROBE_TOKEN?: string;
}

const headers = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };
const tokenPattern = /^[A-Za-z0-9_-]{43,128}$/u;
function tokenMatches(actual: string, expected: string): boolean {
  if (!tokenPattern.test(actual) || !tokenPattern.test(expected) || actual.length !== expected.length) return false;
  let difference = 0;
  for (let i = 0; i < actual.length; i++) difference |= actual.charCodeAt(i) ^ expected.charCodeAt(i);
  return difference === 0;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== 'POST' || url.pathname !== '/synthetic-s3-round-trip' || url.search
      || env.PRESERVATION_ENABLED !== 'NO' || env.CLEANUP_ENABLED !== 'NO'
      || env.RECOVERY_COPY_ENABLED !== 'NO'
      || !tokenMatches(request.headers.get('x-neko-staging-s3-probe-token') ?? '',
        env.STAGING_S3_PROBE_TOKEN ?? '')) return new Response(null, { status: 404, headers });

    const ownerId = crypto.randomUUID();
    const recordId = crypto.randomUUID();
    const key = `recovery/v1/${ownerId}/photo/${recordId}`;
    const synthetic = crypto.getRandomValues(new Uint8Array(32));
    let phase = 'put';
    let lastAwsMethod = '';
    let lastAwsStatus = 0;
    let lastAwsCode = '';
    try {
      const diagnosticFetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
        lastAwsMethod = init?.method ?? 'GET';
        const result = await fetch(input, init);
        lastAwsStatus = result.status;
        const errorBytes = Number(result.headers.get('content-length') ?? NaN);
        if (result.status >= 400 && Number.isSafeInteger(errorBytes)
          && errorBytes > 0 && errorBytes <= 8192) {
          const xml = await result.clone().text();
          lastAwsCode = /^<\?xml[^>]*>\s*<Error>\s*<Code>([A-Za-z0-9]+)<\/Code>/u.exec(xml)?.[1] ?? '';
        }
        return result;
      };
      const copy = new S3RecoveryCopy({
        enabled: 'YES', region: env.RECOVERY_S3_REGION, bucket: env.RECOVERY_S3_BUCKET,
        expectedAccountId: env.RECOVERY_S3_ACCOUNT_ID,
        accessKeyId: env.RECOVERY_S3_ACCESS_KEY_ID,
        secretAccessKey: env.RECOVERY_S3_SECRET_ACCESS_KEY,
        sessionToken: env.RECOVERY_S3_SESSION_TOKEN,
      }, diagnosticFetch);
      const committed = await copy.putVersioned(key, synthetic);
      phase = 'get';
      const read = await copy.getVerified(committed);
      if (read.length !== synthetic.length || read.some((byte, index) => byte !== synthetic[index])) {
        throw new Error('ROUND_TRIP_MISMATCH');
      }
      phase = 'list';
      const page = await copy.listOwnerVersionsPage(ownerId);
      if (page.nextCursor || page.versions.length !== 1 || page.versions[0].key !== key
        || page.versions[0].versionId !== committed.versionId || page.versions[0].deleteMarker) {
        throw new Error('VERSION_INVENTORY_MISMATCH');
      }
      return Response.json({ result: 'S3_SYNTHETIC_ROUND_TRIP_PASS', key,
        versionId: committed.versionId }, { headers });
    } catch {
      // Include only a random synthetic key so an interrupted PUT can be located.
      return Response.json({ result: 'S3_SYNTHETIC_ROUND_TRIP_FAIL', phase, key,
        lastAwsMethod, lastAwsStatus, lastAwsCode },
        { status: 503, headers });
    } finally { synthetic.fill(0); }
  },
};
